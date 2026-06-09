-- =============================================================================
-- Reconciliation Test Suite for the Email Analytics Cube
-- =============================================================================
--
-- Purpose:
--   Verify that the cube reconciles against source-of-truth tables before any
--   downstream report is generated. Failing reconciliation means the cube is
--   broken and outputs are NOT trustworthy.
--
-- Convention:
--   Every check below returns:
--     - ZERO rows when the test passes
--     - N rows describing the discrepancy when the test fails
--
--   This lets the test suite be wrapped in a CI/CD-style runner that fails
--   loudly when any check produces output.
--
-- Execution:
--   Run all checks before generating weekly reports. If any check fails,
--   investigate and fix the underlying data issue before publishing numbers.
--
-- Checks included:
--   1. Total sends reconcile to operational source
--   2. Cohort splits add to total (no leakage)
--   3. Every send has a classified cohort
--   4. Every send has a classified recipient class
--   5. No duplicate send_ids in cube
--   6. Date coverage has no gaps
--   7. Warmup and internal traffic correctly excluded
--   8. Rate sanity bounds (no impossible values)
--   9. Industry classification completeness
--  10. Source-vendor mapping is exhaustive (no unmapped sources)
-- =============================================================================


-- =============================================================================
-- Check 1: Total sends reconcile to operational source
-- =============================================================================
--
-- Validates: The sum of sends in the cube equals the count of valid send
--            events in the source table. A discrepancy means the cube is
--            either dropping or duplicating rows.
--
-- Expected: 0 rows. Any output indicates a reconciliation failure.
-- =============================================================================

WITH cube_total AS (
    SELECT SUM(sends) AS cube_sends
    FROM analytics.email_analytics_cube
),
source_total AS (
    SELECT COUNT(*) AS source_sends
    FROM email_send_events
    WHERE is_warmup = FALSE
      AND is_internal_test = FALSE
      AND send_status = 'sent'
)
SELECT
    'CHECK 1: Total sends mismatch' AS check_name,
    c.cube_sends,
    s.source_sends,
    (s.source_sends - c.cube_sends) AS difference
FROM cube_total c, source_total s
WHERE c.cube_sends != s.source_sends;


-- =============================================================================
-- Check 2: Cohort splits add to total (no leakage)
-- =============================================================================
--
-- Validates: Intent sends + Prospecting sends = Total sends.
--            If a lead's cohort_type ends up NULL or some unexpected value,
--            sends leak out of the per-cohort totals while still appearing
--            in the grand total.
--
-- Expected: 0 rows. Any output indicates cohort classification leakage.
-- =============================================================================

WITH cohort_breakdown AS (
    SELECT
        SUM(CASE WHEN cohort_type = 'intent' THEN sends ELSE 0 END) AS intent_sends,
        SUM(CASE WHEN cohort_type = 'prospecting' THEN sends ELSE 0 END) AS prospecting_sends,
        SUM(sends) AS total_sends
    FROM analytics.email_analytics_cube
)
SELECT
    'CHECK 2: Cohort split leakage' AS check_name,
    intent_sends,
    prospecting_sends,
    (intent_sends + prospecting_sends) AS sum_of_cohorts,
    total_sends,
    (total_sends - (intent_sends + prospecting_sends)) AS leaked_sends
FROM cohort_breakdown
WHERE (intent_sends + prospecting_sends) != total_sends;


-- =============================================================================
-- Check 3: Every send has a classified cohort
-- =============================================================================
--
-- Validates: No lead enters the cube with a NULL or unexpected cohort_type
--            value. The cohort classification CASE statement should cover
--            every possible lead source.
--
-- Expected: 0 rows. Any output indicates the cohort classification logic
--           is missing a case.
-- =============================================================================

SELECT
    'CHECK 3: Unclassified cohort' AS check_name,
    lead_source,
    COUNT(*) AS unclassified_rows,
    SUM(sends) AS unclassified_sends
FROM analytics.email_analytics_cube
WHERE cohort_type IS NULL
   OR cohort_type NOT IN ('intent', 'prospecting')
GROUP BY lead_source
ORDER BY unclassified_sends DESC;


-- =============================================================================
-- Check 4: Every send has a classified recipient class
-- =============================================================================
--
-- Validates: Recipient classification logic covered every email in the
--            source table. NULL or unexpected recipient_class indicates
--            the classification logic missed a pattern.
--
-- Expected: 0 rows.
-- =============================================================================

SELECT
    'CHECK 4: Unclassified recipient class' AS check_name,
    recipient_class,
    COUNT(*) AS rows_affected,
    SUM(sends) AS sends_affected
FROM analytics.email_analytics_cube
WHERE recipient_class IS NULL
   OR recipient_class NOT IN (
        'gmail_personal', 
        'gmail_workspace_business', 
        'ms_m365_business', 
        'business', 
        'personal'
   )
GROUP BY recipient_class;


-- =============================================================================
-- Check 5: No duplicate send_ids in source
-- =============================================================================
--
-- Validates: The source-of-truth table is properly deduped. If any send_id
--            appears more than once, downstream aggregations will double-count.
--
-- Expected: 0 rows.
-- =============================================================================

SELECT
    'CHECK 5: Duplicate send_ids' AS check_name,
    send_id,
    COUNT(*) AS duplicate_count
FROM email_send_events
WHERE is_warmup = FALSE
  AND is_internal_test = FALSE
GROUP BY send_id
HAVING COUNT(*) > 1;


-- =============================================================================
-- Check 6: Date coverage has no unexpected gaps
-- =============================================================================
--
-- Validates: For the analysis window, every expected day should have at
--            least some send activity. A day with zero sends in the cube
--            but non-zero sends in the operational system indicates a
--            sync failure.
--
-- Expected: 0 rows. Output shows dates present in source but missing in cube.
-- =============================================================================

WITH source_dates AS (
    SELECT DISTINCT send_date AS d
    FROM email_send_events
    WHERE is_warmup = FALSE
      AND is_internal_test = FALSE
      AND send_status = 'sent'
      AND send_date >= CURRENT_DATE - INTERVAL '30 days'
),
cube_dates AS (
    SELECT DISTINCT send_week AS w
    FROM analytics.email_analytics_cube
    WHERE send_week >= CURRENT_DATE - INTERVAL '30 days'
)
SELECT
    'CHECK 6: Missing dates' AS check_name,
    s.d AS missing_date
FROM source_dates s
LEFT JOIN cube_dates c
    ON DATE_TRUNC('week', s.d)::DATE = c.w
WHERE c.w IS NULL;


-- =============================================================================
-- Check 7: Warmup and internal traffic correctly excluded
-- =============================================================================
--
-- Validates: The cube should never include warmup or internal test events.
--            If the cube total includes these, the filter logic in the view
--            is broken.
--
-- Expected: 0 rows.
-- =============================================================================

WITH cube_sample AS (
    -- This works by checking that cube_total ≤ filtered source total
    SELECT SUM(sends) AS cube_sends
    FROM analytics.email_analytics_cube
),
warmup_inclusion_test AS (
    SELECT COUNT(*) AS warmup_in_source
    FROM email_send_events
    WHERE (is_warmup = TRUE OR is_internal_test = TRUE)
      AND send_status = 'sent'
),
full_source AS (
    SELECT COUNT(*) AS all_sent
    FROM email_send_events
    WHERE send_status = 'sent'
)
SELECT
    'CHECK 7: Warmup/internal leaking into cube' AS check_name,
    cs.cube_sends,
    fs.all_sent,
    wit.warmup_in_source,
    (fs.all_sent - wit.warmup_in_source) AS expected_cube_sends
FROM cube_sample cs, full_source fs, warmup_inclusion_test wit
WHERE cs.cube_sends > (fs.all_sent - wit.warmup_in_source);


-- =============================================================================
-- Check 8: Rate sanity bounds
-- =============================================================================
--
-- Validates: Computed rates fall within physically possible ranges.
--            HRR > 100% or negative rates indicate computation bugs.
--
-- Expected: 0 rows. Any output indicates a math error in the view.
-- =============================================================================

SELECT
    'CHECK 8: Rate out of bounds' AS check_name,
    cohort_type,
    sender_esp,
    lead_source,
    sends,
    human_replies,
    hrr_pct,
    opp_rate_pct
FROM analytics.email_analytics_cube
WHERE hrr_pct < 0
   OR hrr_pct > 100
   OR opp_rate_pct < 0
   OR opp_rate_pct > 100
   OR (human_replies > sends)
   OR (opportunities > sends);


-- =============================================================================
-- Check 9: Industry classification completeness
-- =============================================================================
--
-- Validates: A reasonable fraction of leads should be classified into known
--            industries rather than 'other'. If too many fall into 'other',
--            the industry normalization vocabulary needs to be expanded.
--
-- Expected: 0 rows when 'other' is < 30% of total. Threshold is operational
--           — tune based on your data quality target.
-- =============================================================================

WITH industry_breakdown AS (
    SELECT
        SUM(CASE WHEN industry = 'other' THEN sends ELSE 0 END) AS other_sends,
        SUM(sends) AS total_sends
    FROM analytics.email_analytics_cube
)
SELECT
    'CHECK 9: Too many leads in industry "other"' AS check_name,
    other_sends,
    total_sends,
    ROUND(100.0 * other_sends::NUMERIC / total_sends, 1) AS other_pct
FROM industry_breakdown
WHERE (other_sends::NUMERIC / NULLIF(total_sends, 0)) > 0.30;


-- =============================================================================
-- Check 10: Source-vendor mapping is exhaustive
-- =============================================================================
--
-- Validates: Every distinct lead_source_raw value in the leads table is
--            either intentionally mapped to a cohort, or appears in an
--            allowed exception list. Unrecognized sources may indicate a
--            new vendor being onboarded without updating the mapping.
--
-- Expected: 0 rows. Output shows source names appearing in data that aren't
--           in the mapping logic.
-- =============================================================================

WITH distinct_sources AS (
    SELECT DISTINCT lead_source_raw 
    FROM leads
    WHERE created_at >= CURRENT_DATE - INTERVAL '90 days'
),
mapped_sources AS (
    -- This list should be kept in sync with the cohort classification CASE
    -- in cube_definition.sql. Any source name not in this list is unmapped.
    SELECT unnest(ARRAY[
        'intent_vendor_a',
        'intent_vendor_b',
        'intent_vendor_c',
        'prospecting_platform_a',
        'prospecting_platform_b',
        'prospecting_platform_c'
        -- ... extend as new sources come online
    ]) AS source_name
)
SELECT
    'CHECK 10: Unmapped lead source' AS check_name,
    ds.lead_source_raw
FROM distinct_sources ds
LEFT JOIN mapped_sources ms
    ON ds.lead_source_raw = ms.source_name
WHERE ms.source_name IS NULL;


-- =============================================================================
-- Run all checks
-- =============================================================================
--
-- To run all checks in one pass, wrap them in a UNION ALL with a consistent
-- output schema, or run them sequentially in a script and exit non-zero if
-- any check returns rows. In production this should be wired to fail the
-- report build pipeline.
-- =============================================================================
