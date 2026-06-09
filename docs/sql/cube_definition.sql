-- =============================================================================
-- Cohort-Aware Email Analytics Cube — view definition
-- =============================================================================
--
-- Purpose:
--   Aggregates lead-level email send events into the analytical grain used by
--   all downstream reports. Built as a view (not a materialized table) so it
--   always reflects current source-of-truth data without manual refresh.
--
-- Grain:
--   (send_date_week × cohort × sender_esp × recipient_class × lead_source × industry)
--
-- Outcomes per cell:
--   sends, human_replies, auto_replies, opportunities, bounces
--   + derived: HRR, Auto-RR, Opp Rate, Emails per Opp
--
-- Source tables (assumed structure — see docs/architecture.md):
--   email_send_events  : one row per email sent (lead-grain)
--   leads              : lead-level metadata (source, industry, cohort flag)
--   sender_accounts    : sender platform metadata
--
-- Design decisions are documented in docs/decision_log.md.
-- This file: just the definition.
-- =============================================================================


CREATE OR REPLACE VIEW analytics.email_analytics_cube AS

WITH

-- ---------------------------------------------------------------------------
-- Step 1: Classify each lead into a cohort
-- ---------------------------------------------------------------------------
-- Cohort classification is structural — leads sourced from intent-signaling
-- vendors are tagged 'intent'; everything else is 'prospecting'. Classification
-- is set at ingestion and never changes for a given lead.
--
-- The list of intent-signaling sources is operationally maintained — placeholder
-- values shown here; replace with your operation's vendor list.
-- ---------------------------------------------------------------------------
leads_classified AS (
    SELECT
        l.lead_id,
        l.lead_source_raw,
        l.industry_raw,
        CASE
            WHEN l.lead_source_raw IN (
                -- Intent-signaling sources (vendors providing leads with funding/buying intent)
                'intent_vendor_a',
                'intent_vendor_b',
                'intent_vendor_c'
            ) THEN 'intent'
            ELSE 'prospecting'
        END AS cohort_type
    FROM leads l
),

-- ---------------------------------------------------------------------------
-- Step 2: Classify recipient emails into platform categories
-- ---------------------------------------------------------------------------
-- Recipient platform meaningfully affects deliverability and response patterns.
-- We classify into 5 mutually exclusive categories using domain patterns.
-- ---------------------------------------------------------------------------
recipients_classified AS (
    SELECT
        e.send_id,
        CASE
            -- Consumer Gmail accounts (highest-volume consumer category)
            WHEN e.recipient_email ILIKE '%@gmail.com'
                THEN 'gmail_personal'

            -- Other consumer providers
            WHEN e.recipient_email ILIKE '%@yahoo.com'
              OR e.recipient_email ILIKE '%@aol.com'
              OR e.recipient_email ILIKE '%@hotmail.com'
              OR e.recipient_email ILIKE '%@outlook.com'
              OR e.recipient_email ILIKE '%@icloud.com'
              OR e.recipient_email ILIKE '%@protonmail.com'
                THEN 'personal'

            -- Business accounts running on Google Workspace infrastructure
            -- (custom domain but MX records point to Google)
            WHEN e.recipient_mx_provider = 'google'
                THEN 'gmail_workspace_business'

            -- Business accounts on Microsoft 365 infrastructure
            WHEN e.recipient_mx_provider = 'microsoft'
                THEN 'ms_m365_business'

            -- All other business / custom-domain accounts
            ELSE 'business'
        END AS recipient_class
    FROM email_send_events e
),

-- ---------------------------------------------------------------------------
-- Step 3: Normalize industry classifications
-- ---------------------------------------------------------------------------
-- Raw industry strings can be noisy. We map them to a controlled vocabulary
-- of high-level verticals so analyses roll up cleanly.
-- ---------------------------------------------------------------------------
industries_normalized AS (
    SELECT
        l.lead_id,
        CASE
            WHEN l.industry_raw IN ('software', 'saas', 'tech', 'information technology')
                THEN 'tech_it'
            WHEN l.industry_raw IN ('manufacturing', 'industrial', 'factories')
                THEN 'manufacturing'
            WHEN l.industry_raw IN ('healthcare', 'medical', 'clinic', 'pharma')
                THEN 'healthcare'
            WHEN l.industry_raw IN ('construction', 'contracting', 'trades_b2c')
                THEN 'b2c_trades'
            WHEN l.industry_raw IN ('consulting', 'legal', 'accounting', 'b2b_services')
                THEN 'b2b_pro_services'
            WHEN l.industry_raw IN ('logistics', 'transport', 'shipping', 'trucking')
                THEN 'transport_logistics'
            -- ... additional mappings as the vocabulary grows
            ELSE 'other'
        END AS industry_clean
    FROM leads l
),

-- ---------------------------------------------------------------------------
-- Step 4: Bucket send dates into ISO weeks for week-over-week analysis
-- ---------------------------------------------------------------------------
dates_bucketed AS (
    SELECT
        e.send_id,
        e.send_date,
        DATE_TRUNC('week', e.send_date)::DATE AS send_week,
        EXTRACT(YEAR FROM e.send_date) AS send_year,
        EXTRACT(WEEK FROM e.send_date) AS send_iso_week
    FROM email_send_events e
),

-- ---------------------------------------------------------------------------
-- Step 5: Filter out warmup and internal-test traffic
-- ---------------------------------------------------------------------------
-- Warmup emails (internal-to-internal reputation maintenance) and test emails
-- to known QA addresses inflate volume without contributing to outcomes. We
-- exclude them from the cube at the source so no downstream metric is polluted.
-- ---------------------------------------------------------------------------
sends_filtered AS (
    SELECT e.*
    FROM email_send_events e
    WHERE e.is_warmup = FALSE
      AND e.is_internal_test = FALSE
      AND e.send_status = 'sent'
),

-- ---------------------------------------------------------------------------
-- Step 6: Join everything together and aggregate to cube grain
-- ---------------------------------------------------------------------------
cube_aggregated AS (
    SELECT
        -- Time dimension
        db.send_week,

        -- Cohort dimension
        lc.cohort_type,

        -- Infrastructure dimensions
        sa.sender_esp,
        rc.recipient_class,

        -- Source dimensions
        lc.lead_source_raw AS lead_source,
        ind.industry_clean AS industry,

        -- Outcome metrics (raw counts)
        COUNT(*) AS sends,
        SUM(CASE WHEN sf.has_human_reply = TRUE
                  AND sf.has_auto_reply = FALSE
                 THEN 1 ELSE 0 END) AS human_replies,
        SUM(CASE WHEN sf.has_auto_reply = TRUE THEN 1 ELSE 0 END) AS auto_replies,
        SUM(CASE WHEN sf.has_opportunity = TRUE THEN 1 ELSE 0 END) AS opportunities,
        SUM(CASE WHEN sf.is_bounced = TRUE THEN 1 ELSE 0 END) AS bounces

    FROM sends_filtered sf
        INNER JOIN leads_classified lc       ON sf.lead_id = lc.lead_id
        INNER JOIN recipients_classified rc  ON sf.send_id = rc.send_id
        INNER JOIN industries_normalized ind ON sf.lead_id = ind.lead_id
        INNER JOIN dates_bucketed db         ON sf.send_id = db.send_id
        INNER JOIN sender_accounts sa        ON sf.sender_account_id = sa.sender_account_id

    GROUP BY
        db.send_week,
        lc.cohort_type,
        sa.sender_esp,
        rc.recipient_class,
        lc.lead_source_raw,
        ind.industry_clean
)

-- ---------------------------------------------------------------------------
-- Final SELECT: add derived metrics
-- ---------------------------------------------------------------------------
-- Derived rates are computed in the view (not downstream) so every consumer
-- of the cube uses the same definitions. Division-by-zero handled with
-- NULLIF to avoid runtime errors.
-- ---------------------------------------------------------------------------
SELECT
    -- Dimensions
    send_week,
    cohort_type,
    sender_esp,
    recipient_class,
    lead_source,
    industry,

    -- Raw outcomes
    sends,
    human_replies,
    auto_replies,
    opportunities,
    bounces,

    -- Derived rates (NULL when no sends in cell — preferred over 0 for analysis)
    ROUND(100.0 * human_replies::NUMERIC / NULLIF(sends, 0), 4) AS hrr_pct,
    ROUND(100.0 * auto_replies::NUMERIC  / NULLIF(sends, 0), 4) AS auto_rr_pct,
    ROUND(100.0 * opportunities::NUMERIC / NULLIF(sends, 0), 6) AS opp_rate_pct,
    ROUND(100.0 * bounces::NUMERIC       / NULLIF(sends, 0), 4) AS bounce_rate_pct,

    -- Emails per Opportunity (inverse of opp rate — primary efficiency metric)
    -- NULL when opportunities = 0 so consumers can filter rather than seeing inf
    CASE
        WHEN opportunities > 0
            THEN ROUND(sends::NUMERIC / opportunities, 0)
        ELSE NULL
    END AS emails_per_opp

FROM cube_aggregated;


-- =============================================================================
-- Index recommendations (for the underlying source tables)
-- =============================================================================
-- The view itself doesn't carry indexes — it's evaluated on read against the
-- source tables. For acceptable query latency on 10M+ row source tables, the
-- following indexes are recommended:
--
--   CREATE INDEX idx_send_events_send_date ON email_send_events (send_date);
--   CREATE INDEX idx_send_events_lead_id   ON email_send_events (lead_id);
--   CREATE INDEX idx_send_events_account   ON email_send_events (sender_account_id);
--   CREATE INDEX idx_leads_source          ON leads (lead_source_raw);
--
-- For weekly report runs covering the full historical window, query times
-- should sit under 30 seconds on a properly indexed Postgres instance.
-- =============================================================================
