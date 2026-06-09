Cohort-Aware Email Analytics Cube
A lead-level analytics infrastructure for B2B cold email operations at scale. Built to replace campaign-level gut-feel with statistically defensible insights at the intersection of sender infrastructure, lead source, recipient context, and revenue outcomes.

The problem
B2B cold email operations sending millions of emails per week typically track campaign-level KPIs (open rate, reply rate, opportunity rate). At scale, these aggregated metrics break down for two reasons:

Aggregation hides structural patterns. A portfolio-wide "0.3% reply rate" reveals nothing about which combinations of (sender × recipient × lead source) actually generate opportunities. The 80/20 of performance is invisible.
Decisions get made on the wrong granularity. A campaign manager kills a "bad lead source" when in reality one specific (source × sender × recipient) triple is dragging the average while another triple from the same source is best-in-class. Killing the source destroys both.

This cube was built to operate at the granularity where decisions live — (send × cohort × sender × recipient × source × industry) — while still rolling up cleanly to executive-grade reports.

Architectural decisions
1. Cohort separation as a first-class dimension
The single most important design choice. Two structurally different lead types — intent-based (vendors selling leads who indicated funding intent) and prospecting (subscription platforms like email databases and scraped lists) — behave so differently that any aggregate metric mixing them distorts every read.
Empirical evidence from production: the two cohorts have mutually exclusive winning patterns. One converts on personal email recipients (consumer-grade Gmail accounts), the other on business email recipients (workspace accounts). A subject line that wins for one cohort can lose for the other. Aggregating loses this signal entirely.
The cube forces every cut to be cohort-aware. There is no "portfolio-wide source ranking" — only intent-cohort source ranking and prospecting-cohort source ranking, separately.
2. Opportunities per email as the primary efficiency metric
Reply Rate (HRR) is widely tracked but doesn't tie cleanly to revenue. Adding Emails per Opportunity (the inverse of Opportunity Rate) gives an interpretable, cost-modeling-friendly metric: "we need to send X emails to generate one real opportunity."
This becomes the unit of analysis for:

Dollar-per-opp calculations (combined with infra spend and lead cost)
Comparing efficiency across cohorts at different scales
Identifying outliers (cells where the ratio is 5–10× better than cohort average)

3. Week-over-week per-cell variance tracking
Every (sender × source × recipient × cohort) cell tracks its own HRR/Opp Rate history. This enables:

Statistically grounded decay detection. Define "normal" range per cell from historical variance; flag deviations at 2σ. Replaces gut-feel thresholds like "drop 30% from baseline" with cell-specific signal/noise discrimination.
Source-level resilience analysis. Distinguish sources whose performance is genuinely degrading from sources whose week-to-week variance is naturally high (noise vs signal).
Power analysis for layered testing. Knowing per-cell variance defines minimum sample sizes for any A/B or fractional factorial test built on top.

4. Lead-grain source of truth, rebuildable in minutes
The cube is a SQL view over a clean lead-level event table. Every send is one row with all dimensions and outcomes attached. This grain decision means:

Any aggregation (cohort, weekly, source, etc.) is one GROUP BY away
Reconciliation against operational systems is straightforward (sum at lead grain = totals)
Adding a new dimension (e.g., copy variant tags) is an additive schema change
Executive reports covering 16M+ sends regenerate in under 10 minutes


Sample analyses unlocked
sql-- Which (sender × recipient × source) triples have the lowest emails-per-opp?
-- Output: top 20 highest-leverage cells, with sample size guardrails

-- Which sources are decaying across rolling 3-week windows?
-- Output: source × weekly HRR with statistical decay flags

-- For each industry vertical, which sender × recipient combination wins by cohort?
-- Output: industry-level routing recommendations, cohort-separated

-- What's the cohort efficiency gap and how is it trending?
-- Output: intent vs prospecting cohort comparison over time
Real production use of the cube has driven decisions including:

Source kill decisions backed by 3-week decay evidence at the source level
Sender-platform migration recommendations with cohort-specific impact estimates
Identification of 5–10× efficient micro-cells that were previously hidden in cohort averages
Reframing of allocation strategy from source-level to source × sender × recipient level


Technical stack
LayerTechnologyDatabasePostgreSQL (deployable on any SQL warehouse — Supabase, BigQuery, DuckDB, Snowflake)Cube definitionSQL view (~200 lines)Report generationNode.js with the docx library, builds executive Word reports directly from cube queriesVerificationSQL reconciliation test suite — cube totals must match source-of-truth tables exactlyIterationBuilt so that weekly reports for 16M+ sends regenerate in minutes against fresh data

Methodology highlights

No auto-reply pollution in HRR. Human reply rate strictly excludes auto-replies (out-of-office, ticket bots). Auto-reply rate is tracked separately so HRR is never inflated.
Settled-data window enforced. Rate calculations only use date ranges where replies have had time to settle in the warehouse (avoids the trap of "Wk N looks bad" when it's just incomplete data).
Reconciliation-first development. Every aggregation in the cube was verified to match the operational source of truth before being included. No analysis on top of unverified totals.
Statistical rigor for decision rules. Power analysis used to derive minimum sample sizes per layer of analysis; decay thresholds derived from observed variance, not chosen arbitrarily.


Repository structure
.
├── README.md                       This file
├── docs/
│   ├── methodology.md              Cohort definitions, metric formulas, design rationale
│   ├── architecture.md             Schema diagrams, data flow
│   └── decision_log.md             Why each major design choice was made
├── sql/
│   ├── cube_definition.sql         The view powering everything
│   ├── reconciliation.sql          Verification test suite
│   └── sample_queries.sql          Canonical analytical patterns
└── scripts/
    └── weekly_report_builder.js    Node.js report generator (sanitized template)

What this repository is — and isn't
It is: An architecture and methodology reference. The SQL design, the cohort definitions, the report-generation approach, and the decision rationale.
It isn't: A runnable demo with real data. Due to confidentiality obligations, no production data, vendor names, operational figures, or company-identifying details are included. The structure and methodology are general enough to apply to any B2B email operation at scale.
Happy to discuss specific implementation details, results, or the architectural decisions in an interview.

Author
Thomas Mandelman — Senior Data Analyst
Built as part of building an analytics layer for a B2B cold email operation running at multi-million sends per week. Architectural decisions documented here are drawn from production experience and the analyses they enabled.
