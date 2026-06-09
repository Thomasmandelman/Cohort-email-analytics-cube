# Decision Log

This document captures the major design decisions made while building the cube, including alternatives considered and the rationale for each choice. The format follows the spirit of Architecture Decision Records (ADRs) — context, decision, alternatives, rationale, consequences.

Decisions are logged in chronological order of when they were made, not order of importance.

---

## ADR-001: Cohort separation as a first-class dimension

**Status:** Accepted, implemented.

**Context.** Aggregating performance metrics across all lead types produced misleading reads. The portfolio-wide reply rate hid the fact that two structurally distinct lead populations — leads from intent-signaling vendors versus leads from prospecting platforms — were behaving differently along almost every dimension (recipient platform, sender effectiveness, decay patterns, opportunity conversion). Decisions made on aggregated metrics were systematically directionally wrong.

**Decision.** Treat cohort as a top-level, non-collapsible dimension in every analytical output. Every table, every chart, every weekly report shows the two cohorts side-by-side or in separate panels. There is no "portfolio-wide source ranking" — only intent-cohort ranking and prospecting-cohort ranking, always presented separately.

**Alternatives considered.**

- *Single aggregate view with cohort as a filter.* Rejected because users would invariably look at the aggregate by default, falling back into the original mistake.
- *Cohort as a tag for filtering but not a primary dimension.* Rejected for the same reason — analysts would aggregate across the tag and lose the signal.
- *Two separate cubes, one per cohort.* Considered seriously. Rejected because it would duplicate maintenance and prevent any analysis that genuinely needs both cohorts in view (e.g., volume mix shifts over time).

**Rationale.** The empirical gap between cohorts is large enough that no production decision should be made without explicit cohort awareness. Forcing the separation at the data model level (rather than relying on analyst discipline) removes a recurring class of analytical mistakes.

**Consequences.** Every report is slightly longer because metrics appear twice. Some readers initially asked "what's the portfolio number?" — the answer is "there isn't one, here's both." This was a feature, not a bug.

---

## ADR-002: Lead-grain source of truth

**Status:** Accepted, implemented.

**Context.** Earlier iterations of the analytics pipeline aggregated at the campaign level. This made some questions easy (campaign performance over time) and others impossible (which sender platform performs best for a specific industry in a specific cohort). Adding a new dimension meant rewriting the entire pipeline.

**Decision.** The single source-of-truth table operates at lead-grain — one row per email sent, with every relevant dimension attached. All aggregations (campaign-level, weekly, source-level, etc.) are derived via `GROUP BY` from this grain.

**Alternatives considered.**

- *Campaign-grain source of truth.* Faster to query, smaller table, but loses analytical flexibility. Any new dimension required schema changes and backfill.
- *Multiple grain-specific tables (lead, campaign, weekly).* Rejected because keeping them in sync is a maintenance burden and a constant reconciliation problem.

**Rationale.** Storage and query latency are cheap; analyst time and reconciliation bugs are expensive. Lead-grain keeps every aggregation one query away and makes new dimensions additive (a new column) rather than structural (a new table).

**Consequences.** The base table is larger (millions of rows) and queries take longer than they would on a pre-aggregated table. Acceptable trade-off given the analytical flexibility gained. Query latency is managed with appropriate indexes on the most-filtered columns (`send_date`, `cohort_type`, `lead_source`).

---

## ADR-003: Emails per Opportunity as primary efficiency metric

**Status:** Accepted, implemented.

**Context.** Reply Rate (HRR) is widely tracked but doesn't tie cleanly to revenue. Conversations among stakeholders kept defaulting to "this campaign has a 0.4% reply rate" — a number that's hard to interpret as "good" or "bad" without context, and that doesn't translate into cost decisions.

**Decision.** Use Emails per Opportunity as the primary efficiency metric in all executive-facing reports. HRR and Opp Rate are still computed and shown, but the headline metric per cell is "you need X emails to generate one opportunity."

**Alternatives considered.**

- *Opp Rate as primary.* Mathematically equivalent (just the inverse). Rejected because percentages this small ("0.072%") are hard to compare at a glance and don't ladder into cost models cleanly.
- *Cost per Opportunity (in dollars) as primary.* The right end state, but requires cost data we didn't have at the time. Adopted as a future direction once lead-cost anchors are available.

**Rationale.** "1,400 emails per opportunity" is an interpretable number. Multiplying by cost per send gives cost per opportunity directly. Comparing 1,400 to 10,000 across two cohorts is more legible than comparing 0.072% to 0.010%. The unit primes cost thinking.

**Consequences.** All cells with zero opportunities show NULL rather than infinity. The metric is undefined for very-low-volume cells (sample size filters needed before reading). Reports include both rates and ratios so readers comfortable with either framing can use what they prefer.

---

## ADR-004: Per-cell variance for decay thresholds

**Status:** Accepted, implemented.

**Context.** Decay detection was originally configured with a single global threshold: "alert if HRR drops more than 30% from the recent baseline." This produced both false positives (cells with naturally high variance triggering daily) and false negatives (stable cells gradually decaying without ever crossing the threshold).

**Decision.** Compute the natural week-over-week variance σ for each cell (`cohort × sender × source × recipient`) from at least 6 weeks of history. Decay is defined per-cell as a drop below `baseline − 2σ`. The threshold is cell-specific, not global.

**Alternatives considered.**

- *Single global threshold (the original).* Rejected because cells have wildly different variance profiles.
- *Manually tuned thresholds per cell.* Rejected as unscalable — there are too many cells and they change over time.
- *Bayesian updating with priors.* Considered. Rejected for v1 as overengineered for the volume; revisitable if false positive/negative rates remain a problem.

**Rationale.** Statistical defensibility. If a recruiter or stakeholder asks "why did you call this decayed?" the answer is "the drop was outside the cell's normal range" with a number, not a gut feel.

**Consequences.** Cells need at least ~6 weeks of history before decay detection can run on them — newly emerging cells get a grace period. Acceptable trade-off because new cells are usually monitored manually anyway.

---

## ADR-005: HRR excludes auto-replies, tracked separately

**Status:** Accepted, implemented.

**Context.** "Reply rate" was being reported as a single number that included auto-replies (out-of-office, ticket bots, etc.). On weeks with high vacation traffic, the metric would move up purely because more inboxes were generating automated bounces. This made HRR a noisy proxy for actual human engagement.

**Decision.** Human Reply Rate (HRR) strictly excludes auto-replies. Auto-Reply Rate (Auto-RR) is computed and tracked separately as its own metric.

**Alternatives considered.**

- *Single combined reply rate.* The original. Rejected for the reason above.
- *Weight auto-replies at a fraction (e.g., 0.1) of human replies.* Considered. Rejected as inventing a number that's hard to defend — "why 0.1?"

**Rationale.** Cleaner signal in HRR. Auto-RR is itself useful as a sanity-check: if HRR drops but Auto-RR doesn't, the change is genuinely about human engagement; if both move together, something structural changed in the recipient pool (holidays, layoffs).

**Consequences.** Two metrics to track instead of one. Both shown in reports. Trade-off accepted because the analytical clarity is worth the small UI cost.

---

## ADR-006: Reconciliation-first methodology

**Status:** Accepted, enforced.

**Context.** Earlier iterations published reports with numbers that didn't match the operational source of truth. A campaign manager would look at a report saying "5,000 sends" and the operational dashboard would say "5,200." Small discrepancies but enough to erode trust in the entire report.

**Decision.** Before any number is published, the cube must reconcile to operational source-of-truth totals across all dimensions. Specifically: sum of sends per cohort must match operational totals; sum of replies must match; cohort splits must add to total without leakage. Reconciliation is a test suite (`sql/reconciliation.sql`) that runs automatically.

**Alternatives considered.**

- *Best-effort matching with documented discrepancies.* Rejected because discrepancies compound trust loss.
- *Manual spot-checks before each report.* Rejected as unscalable and error-prone.

**Rationale.** Trust in the report is a precondition for trust in any decision derived from it. A few hours spent on reconciliation infrastructure saves weeks of "but is this number right?" conversations downstream.

**Consequences.** Cube generation has a hard prerequisite — reconciliation must pass before reports build. When source data has issues, the cube refuses to publish rather than publishing wrong numbers. This is correct behavior.

---

## ADR-007: View instead of materialized table

**Status:** Accepted, implemented. Revisable if performance becomes a problem.

**Context.** The cube could be implemented as either a SQL view (computed on every query) or a materialized table (precomputed and refreshed periodically).

**Decision.** Implement as a view. Every query against the cube reflects current source data without manual refresh.

**Alternatives considered.**

- *Materialized table refreshed nightly.* Faster queries, but introduces a staleness problem ("the report is from this morning, the dashboard says something else"). Also requires refresh orchestration.
- *Materialized table refreshed on-demand.* Same as above but with manual triggers.

**Rationale.** Source data volume is modest enough that view-time computation is acceptable (sub-30-second queries for the full historical window with proper indexing). The simplicity and freshness benefits outweigh the latency cost.

**Consequences.** If source data ever grows past the point where view queries are too slow, this decision will need revisiting. At that point, the move would be to a materialized table with a refresh contract documented to consumers. Currently not necessary.

---

## ADR-008: Settling window enforced on rate calculations

**Status:** Accepted, implemented.

**Context.** Email replies don't arrive instantly. A send on Monday might receive a reply on Wednesday or even the following week. If the rate calculation includes Monday's sends but Wednesday's replies haven't been processed yet, the rate is artificially low.

**Decision.** Rate calculations exclude the most recent N days of sends (currently 5–7, depending on source pipeline lag). Volume tracking still includes those days; only rates exclude them.

**Alternatives considered.**

- *Use all available data including the recent days.* Rejected because it produces a recurring "the latest week looks terrible" false alarm.
- *Wait until data is fully settled before producing the report.* Rejected because it adds latency to the report cycle.

**Rationale.** A small data exclusion is preferable to publishing systematically biased recent-period numbers.

**Consequences.** Reports show a clear boundary in the time series: "rate analysis through date X; volume through date Y." This is documented in every report so readers know what's settled.

---

## ADR-009: Exclude warmup and internal traffic at source

**Status:** Accepted, implemented.

**Context.** Email infrastructure requires warmup traffic (internal-to-internal sends to maintain sender reputation) and is exposed to internal test traffic (QA sends to known internal addresses). These are operationally necessary but should not contribute to any outcome metric.

**Decision.** Filter warmup and internal traffic at the source-of-truth ingestion layer. The cube never sees these rows.

**Alternatives considered.**

- *Filter downstream in each query.* Rejected because relying on every analyst to remember the filter is fragile.
- *Tag but include.* Rejected because mixed-tagged-and-clean data is easy to misuse.

**Rationale.** Filtering at source means every consumer of the cube sees clean data by default. The cost is a small loss of operational visibility into warmup volume, which is acceptable because that metric is tracked separately in infrastructure dashboards.

**Consequences.** One source of truth for outcome metrics; no risk of accidentally including warmup in performance reports.

---

## Decisions deliberately NOT made (yet)

A few design choices were considered and explicitly deferred. Logging these so the deferred status is clear:

- **Cost-per-Opportunity as primary metric.** Requires lead-cost anchors that aren't yet wired into the data model. Deferred until cost data is available; the cube is structured to support this addition as a non-breaking change.
- **Copy variant tagging as a cube dimension.** Proposed as an extension to support A/B and fractional factorial testing of email content. Requires upstream tagging at the send-generation layer. Deferred pending engineering work.
- **Real-time updates.** Currently the cube reflects source data within minutes of insertion, but doesn't support sub-minute streaming. Deferred unless a use case emerges that needs it.
