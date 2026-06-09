-- =============================================================================
-- Sample Analytical Queries on the Email Analytics Cube
-- =============================================================================
--
-- Each query is preceded by:
--   - The business question it answers
--   - The decision it informs in production
--   - Notes on interpretation pitfalls (if any)
--
-- All queries operate on the view defined in cube_definition.sql.
-- =============================================================================


-- =============================================================================
-- Query 1: Cohort efficiency gap (the foundational analysis)
-- =============================================================================
-- 
-- Question: How different are intent and prospecting cohorts at the portfolio
--           level, and is the gap stable over time?
--
-- Decision: Validates (or invalidates) the strategic case for allocating more
--           volume to intent sources. If gap is large and stable → push intent.
--           If gap is closing → re-evaluate.
--
-- Pitfall:  Never present this aggregated — always cohort-separated. A single
--           "portfolio average" mixing cohorts is meaningless.
-- =============================================================================

SELECT
    cohort_type,
    SUM(sends)                                    AS total_sends,
    SUM(human_replies)                            AS total_replies,
    SUM(opportunities)                            AS total_opps,
    ROUND(100.0 * SUM(human_replies)::NUMERIC 
                / NULLIF(SUM(sends), 0), 3)       AS hrr_pct,
    ROUND(100.0 * SUM(opportunities)::NUMERIC 
                / NULLIF(SUM(sends), 0), 4)       AS opp_rate_pct,
    CASE WHEN SUM(opportunities) > 0
         THEN ROUND(SUM(sends)::NUMERIC 
                  / SUM(opportunities), 0)
    END                                           AS emails_per_opp
FROM analytics.email_analytics_cube
WHERE send_week BETWEEN DATE '2025-01-01' AND DATE '2025-12-31'
GROUP BY cohort_type
ORDER BY emails_per_opp ASC;


-- =============================================================================
-- Query 2: Top opportunity-efficient cells
-- =============================================================================
--
-- Question: Which specific (cohort × sender × recipient × source) cells are 
--           generating opportunities most efficiently?
--
-- Decision: Identify cells with capacity headroom for targeted scaling.
--           E.g., a cell with 80K sends and 200 opps (400 emails/opp) and
--           plenty of available volume in that source is the next allocation
--           target.
--
-- Pitfall:  Filter by minimum sample size to avoid lucky outliers — a cell
--           with 1K sends and 5 opps looks great (200 emails/opp) but is
--           statistical noise.
-- =============================================================================

SELECT
    cohort_type,
    sender_esp,
    recipient_class,
    lead_source,
    SUM(sends)         AS sends,
    SUM(opportunities) AS opps,
    ROUND(SUM(sends)::NUMERIC / NULLIF(SUM(opportunities), 0), 0) 
                       AS emails_per_opp,
    ROUND(100.0 * SUM(opportunities)::NUMERIC 
                / NULLIF(SUM(sends), 0), 4) 
                       AS opp_rate_pct
FROM analytics.email_analytics_cube
WHERE send_week >= DATE '2025-01-01'
GROUP BY cohort_type, sender_esp, recipient_class, lead_source
HAVING SUM(sends) >= 50000        -- minimum sample size filter
   AND SUM(opportunities) >= 10   -- minimum events filter
ORDER BY emails_per_opp ASC
LIMIT 20;


-- =============================================================================
-- Query 3: Source decay over rolling weeks
-- =============================================================================
--
-- Question: Which lead sources are showing week-over-week degradation in HRR?
--
-- Decision: Sources with sustained downward trends are candidates for kill 
--           or refresh actions. The 3-week window smooths weekly noise.
--
-- Pitfall:  A single bad week is noise — require at least 2 consecutive weeks
--           of decline to flag, and check sample size in the current week.
-- =============================================================================

WITH weekly_source_perf AS (
    SELECT
        lead_source,
        cohort_type,
        send_week,
        SUM(sends) AS sends,
        SUM(human_replies) AS replies,
        ROUND(100.0 * SUM(human_replies)::NUMERIC 
                    / NULLIF(SUM(sends), 0), 4) AS hrr_pct
    FROM analytics.email_analytics_cube
    WHERE send_week >= CURRENT_DATE - INTERVAL '8 weeks'
    GROUP BY lead_source, cohort_type, send_week
    HAVING SUM(sends) >= 5000
)
SELECT
    lead_source,
    cohort_type,
    send_week,
    sends,
    hrr_pct,
    LAG(hrr_pct, 1) OVER (
        PARTITION BY lead_source, cohort_type 
        ORDER BY send_week
    ) AS prev_week_hrr,
    ROUND(
        100.0 * (hrr_pct - LAG(hrr_pct, 1) OVER (
            PARTITION BY lead_source, cohort_type 
            ORDER BY send_week
        )) / NULLIF(LAG(hrr_pct, 1) OVER (
            PARTITION BY lead_source, cohort_type 
            ORDER BY send_week
        ), 0), 1
    ) AS wow_change_pct
FROM weekly_source_perf
ORDER BY lead_source, cohort_type, send_week;


-- =============================================================================
-- Query 4: Sender ESP hierarchy by cohort
-- =============================================================================
--
-- Question: For each cohort, which sender platform generates the best HRR
--           and Opp Rate?
--
-- Decision: Infrastructure routing — should this cohort migrate from one
--           sender platform to another?
-- =============================================================================

SELECT
    cohort_type,
    sender_esp,
    SUM(sends) AS sends,
    ROUND(100.0 * SUM(human_replies)::NUMERIC 
                / NULLIF(SUM(sends), 0), 3) AS hrr_pct,
    ROUND(100.0 * SUM(opportunities)::NUMERIC 
                / NULLIF(SUM(sends), 0), 4) AS opp_rate_pct,
    CASE WHEN SUM(opportunities) > 0 
         THEN ROUND(SUM(sends)::NUMERIC 
                  / SUM(opportunities), 0)
    END AS emails_per_opp,
    RANK() OVER (
        PARTITION BY cohort_type 
        ORDER BY SUM(opportunities)::NUMERIC 
              / NULLIF(SUM(sends), 0) DESC
    ) AS rank_in_cohort
FROM analytics.email_analytics_cube
WHERE send_week >= CURRENT_DATE - INTERVAL '4 weeks'
GROUP BY cohort_type, sender_esp
ORDER BY cohort_type, rank_in_cohort;


-- =============================================================================
-- Query 5: Recipient class behavior — proving the cohort separation premise
-- =============================================================================
--
-- Question: Do intent and prospecting cohorts perform differently across
--           recipient platforms? (Validates the methodology's core claim 
--           that cohorts are not interchangeable.)
--
-- Decision: If recipient class winners are mutually exclusive across cohorts,
--           the cohort-separation design is justified empirically.
-- =============================================================================

SELECT
    recipient_class,
    SUM(CASE WHEN cohort_type = 'intent' THEN sends ELSE 0 END) 
                                                       AS intent_sends,
    ROUND(100.0 * SUM(CASE WHEN cohort_type = 'intent' THEN human_replies 
                           ELSE 0 END)::NUMERIC 
                / NULLIF(SUM(CASE WHEN cohort_type = 'intent' THEN sends 
                                  ELSE 0 END), 0), 3) 
                                                       AS intent_hrr_pct,
    SUM(CASE WHEN cohort_type = 'prospecting' THEN sends ELSE 0 END) 
                                                       AS prospecting_sends,
    ROUND(100.0 * SUM(CASE WHEN cohort_type = 'prospecting' THEN human_replies 
                           ELSE 0 END)::NUMERIC 
                / NULLIF(SUM(CASE WHEN cohort_type = 'prospecting' THEN sends 
                                  ELSE 0 END), 0), 3) 
                                                       AS prospecting_hrr_pct
FROM analytics.email_analytics_cube
WHERE send_week >= CURRENT_DATE - INTERVAL '4 weeks'
GROUP BY recipient_class
ORDER BY recipient_class;


-- =============================================================================
-- Query 6: Industry × sender winners
-- =============================================================================
--
-- Question: For each industry vertical, which sender platform performs best?
--           Run cohort-separated since intent/prospecting industry mixes differ.
--
-- Decision: Industry-level routing rules — by default route Industry X to 
--           Sender Y for Cohort Z.
-- =============================================================================

SELECT
    cohort_type,
    industry,
    sender_esp,
    SUM(sends) AS sends,
    ROUND(100.0 * SUM(human_replies)::NUMERIC 
                / NULLIF(SUM(sends), 0), 3) AS hrr_pct,
    -- Rank within each (cohort, industry) by HRR
    RANK() OVER (
        PARTITION BY cohort_type, industry 
        ORDER BY SUM(human_replies)::NUMERIC 
              / NULLIF(SUM(sends), 0) DESC
    ) AS sender_rank
FROM analytics.email_analytics_cube
WHERE send_week >= CURRENT_DATE - INTERVAL '4 weeks'
GROUP BY cohort_type, industry, sender_esp
HAVING SUM(sends) >= 5000
ORDER BY cohort_type, industry, sender_rank;


-- =============================================================================
-- Query 7: Per-cell variance for statistical decay thresholds
-- =============================================================================
--
-- Question: What's the natural week-over-week variance for each cell? Used
--           to set decay thresholds at (baseline - 2*sigma) per cell rather 
--           than using a single global threshold.
--
-- Decision: Defines the alerting rule per cell. Cells with low sigma get
--           tight thresholds; cells with high sigma require larger drops 
--           before triggering an alert.
-- =============================================================================

WITH weekly_cell_perf AS (
    SELECT
        cohort_type,
        sender_esp,
        recipient_class,
        lead_source,
        send_week,
        ROUND(100.0 * SUM(human_replies)::NUMERIC 
                    / NULLIF(SUM(sends), 0), 4) AS weekly_hrr
    FROM analytics.email_analytics_cube
    WHERE send_week >= CURRENT_DATE - INTERVAL '12 weeks'
    GROUP BY cohort_type, sender_esp, recipient_class, lead_source, send_week
    HAVING SUM(sends) >= 5000
)
SELECT
    cohort_type,
    sender_esp,
    recipient_class,
    lead_source,
    COUNT(*) AS weeks_with_data,
    ROUND(AVG(weekly_hrr)::NUMERIC, 3) AS mean_hrr,
    ROUND(STDDEV(weekly_hrr)::NUMERIC, 4) AS sigma_hrr,
    ROUND((AVG(weekly_hrr) - 2 * STDDEV(weekly_hrr))::NUMERIC, 3) 
        AS decay_threshold_lower,
    ROUND((AVG(weekly_hrr) + 2 * STDDEV(weekly_hrr))::NUMERIC, 3) 
        AS spike_threshold_upper
FROM weekly_cell_perf
GROUP BY cohort_type, sender_esp, recipient_class, lead_source
HAVING COUNT(*) >= 6   -- need enough weeks for sigma to be meaningful
ORDER BY cohort_type, sigma_hrr DESC;


-- =============================================================================
-- Query 8: Power analysis baseline by cohort
-- =============================================================================
--
-- Question: What's the baseline HRR for each cohort × sender, used as input
--           to power analysis for any A/B or fractional factorial test?
--
-- Decision: Informs minimum sample size requirements. For a 20% MDE on a 
--           0.5% baseline, you need ~16K sends per arm at 80% power and 5% 
--           alpha. The power calculation itself happens in the report 
--           generator using these baselines.
-- =============================================================================

SELECT
    cohort_type,
    sender_esp,
    SUM(sends) AS total_sends_8_weeks,
    SUM(human_replies) AS total_replies,
    ROUND(100.0 * SUM(human_replies)::NUMERIC 
                / NULLIF(SUM(sends), 0), 4) AS baseline_hrr_pct,
    -- Approximate standard error of the rate
    ROUND(100.0 * SQRT(
        (SUM(human_replies)::NUMERIC / NULLIF(SUM(sends), 0))
        * (1 - SUM(human_replies)::NUMERIC / NULLIF(SUM(sends), 0))
        / NULLIF(SUM(sends), 0)
    )::NUMERIC, 5) AS std_error_of_rate
FROM analytics.email_analytics_cube
WHERE send_week >= CURRENT_DATE - INTERVAL '8 weeks'
GROUP BY cohort_type, sender_esp
ORDER BY cohort_type, baseline_hrr_pct DESC;
