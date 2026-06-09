# Architecture

End-to-end view of the cube: data sources, transformation pipeline, the cube view, and the downstream consumers. Diagrams use ASCII to render reliably in any Markdown viewer.

---

## System overview

```
┌─────────────────────────┐      ┌──────────────────────┐
│  Email sending platform │      │  Lead vendor APIs    │
│  (operational system)   │      │  (intent + prospect) │
└───────────┬─────────────┘      └──────────┬───────────┘
            │                                │
            │ batch sync                     │ batch import
            │ (every N hours)                │ (on lead receipt)
            ▼                                ▼
┌─────────────────────────────────────────────────────────┐
│           Source-of-truth tables (Postgres)             │
│                                                          │
│   ┌──────────────────────┐   ┌──────────────────┐       │
│   │  email_send_events   │   │      leads       │       │
│   │  (one row per send)  │   │  (lead metadata) │       │
│   └──────────┬───────────┘   └────────┬─────────┘       │
│              │                         │                 │
│              └───────────┬─────────────┘                 │
│                          │                               │
│              ┌───────────▼──────────┐                    │
│              │   sender_accounts    │                    │
│              │  (sender platform)   │                    │
│              └──────────────────────┘                    │
└─────────────────────────┬───────────────────────────────┘
                          │
                          │ SELECT-only view
                          ▼
┌─────────────────────────────────────────────────────────┐
│            analytics.email_analytics_cube                │
│       (the cube — computed on every query)              │
│                                                          │
│  Grain:                                                  │
│   (send_week × cohort × sender_esp × recipient_class    │
│    × lead_source × industry)                            │
│                                                          │
│  Outcomes per cell:                                      │
│   sends, human_replies, auto_replies, opps, bounces,    │
│   + derived: HRR, Opp Rate, E/Opp                       │
└─────────┬───────────────────────────────┬───────────────┘
          │                               │
          │                               │
          ▼                               ▼
┌──────────────────────┐       ┌──────────────────────────┐
│  Weekly executive    │       │  Ad-hoc analytical       │
│  report (.docx)      │       │  queries (SQL)           │
│                       │       │                          │
│  Node.js builder     │       │  Direct cube reads for   │
│  generates Word file │       │  exploration & decision  │
│  from cube queries   │       │  support                 │
└──────────────────────┘       └──────────────────────────┘
```

---

## Data flow timing

| Stage | Cadence | Notes |
|---|---|---|
| Email platform → source tables | Every 30–60 minutes | Batch sync. Lag tolerance: ~1 hour |
| Lead vendor → leads table | On vendor delivery | Variable per vendor (daily to weekly) |
| Source tables → cube view | On read | View is computed at query time, never stale |
| Cube → weekly report | Manual / on-demand | Build time: ~5–10 minutes for full 22-day window |
| Cube → ad-hoc SQL | On demand | Sub-30-second response time with indexes |

---

## Source tables

### `email_send_events` — the lead-level event log

| Column | Type | Notes |
|---|---|---|
| `send_id` | `uuid` (PK) | One row per email sent |
| `lead_id` | `uuid` (FK → leads) | Which lead received this |
| `campaign_id` | `uuid` | Which campaign this send belongs to |
| `sender_account_id` | `uuid` (FK → sender_accounts) | Which sender platform sent it |
| `recipient_email` | `text` | Used for recipient class classification |
| `recipient_mx_provider` | `text` | `google`, `microsoft`, `other` — for MX-based classification |
| `send_date` | `date` | Date the email was sent |
| `send_status` | `text` | `sent`, `failed`, `queued` — only `sent` enters cube |
| `has_human_reply` | `boolean` | True if any human reply received |
| `has_auto_reply` | `boolean` | True if auto-reply received (OOO etc.) |
| `has_opportunity` | `boolean` | True if a qualified opportunity was generated |
| `is_bounced` | `boolean` | True if hard or soft bounce |
| `is_warmup` | `boolean` | Excluded from cube |
| `is_internal_test` | `boolean` | Excluded from cube |

Typical scale: 10–20 million rows per quarter for an operation sending 3–5M emails per week.

### `leads` — lead-level metadata

| Column | Type | Notes |
|---|---|---|
| `lead_id` | `uuid` (PK) | |
| `lead_source_raw` | `text` | Raw source name from vendor — basis for cohort classification |
| `industry_raw` | `text` | Raw industry from vendor — normalized into vocabulary in cube |
| `cohort_flag` | `text` | Set at ingestion: `intent` or `prospecting` |
| `created_at` | `timestamp` | When the lead first entered the system |

Typical scale: 1–3 million rows over an operation's history.

### `sender_accounts` — sender platform registry

| Column | Type | Notes |
|---|---|---|
| `sender_account_id` | `uuid` (PK) | |
| `sender_esp` | `text` | Normalized platform name (e.g., `platform_a`, `platform_b`, `platform_c`) |
| `sender_domain` | `text` | The sending domain |
| `is_active` | `boolean` | Inactive accounts excluded from analysis |

Typical scale: low hundreds of rows — one per active sender account.

---

## Cube view

The cube is a SELECT-only view (see `sql/cube_definition.sql` for the full definition). Key properties:

- **Not materialized** — always reflects current source data
- **Indexed access at source** — view performance depends on appropriate indexes on `email_send_events.send_date`, `email_send_events.lead_id`, and `leads.lead_source_raw`
- **Read latency** — under 30 seconds for full historical window queries with proper indexing; sub-second for filtered slices
- **Append-only consumption** — no consumer ever writes back to the cube; all writes go to source tables

---

## Downstream consumers

### Weekly executive report (Node.js + `docx` library)

A Node.js script (`scripts/weekly_report_builder.js`) queries the cube directly and assembles a Word document. The report includes:

- Portfolio snapshot at the top (with cohort split)
- Week-over-week trend tables (cohort-separated)
- Sender ESP performance by cohort
- Source breakdowns within each cohort
- Killer-combination cells (top opportunity-efficient triples)
- Patterns found section (cross-pattern findings + things decaying)
- Decision recommendations with expected impact ranges
- A glossary for non-analyst readers

Total build time: ~5–10 minutes including SQL query execution and document assembly. The output is a fully-formatted `.docx` ready to share with stakeholders.

### Ad-hoc analytical queries

Analysts query the cube directly via SQL for one-off questions. Common patterns are documented in `sql/sample_queries.sql`. The cube's design intentionally supports this — every dimension is selectable, every metric is computed in the view itself so consumers don't reinvent calculations.

---

## What's NOT in this architecture (and why)

### No materialized layer

Considered and rejected (see `docs/decision_log.md` ADR-007). Source data volume is modest enough that view-time computation is acceptable. If data scale doubled, this would need revisiting.

### No streaming / real-time updates

The current cadence (30–60 minute sync) is sufficient for the use case. Reports are weekly; decisions are made on weekly aggregates. Real-time would add infrastructure complexity without analytical benefit.

### No BI tool layer

The output is the executive Word report and direct SQL access. A BI tool (Looker, Tableau, etc.) was considered but rejected for v1 because the weekly executive report is the primary consumption channel and is highly formatted in ways that BI dashboards don't replicate cleanly. Adding a BI layer remains an option for v2 if exploratory needs grow.

### No row-level security

Currently the cube is accessible to all internal analysts. If multi-tenant access becomes a requirement, row-level security (RLS) policies would be added at the source-table level, which would propagate to the view automatically.

---

## Performance characteristics

Measured on a production deployment with ~16M send events spanning 3 weeks of activity:

| Operation | Wall-clock time |
|---|---|
| Cube view query (full window, no filters) | 18–28 seconds |
| Filtered cube query (single cohort, last week) | 1–3 seconds |
| Weekly report build (all queries + doc assembly) | 5–10 minutes |
| Source table append (single send event) | < 50ms |
| Reconciliation test suite | 30–60 seconds |

Performance is acceptable for the current scale and reporting cadence. Bottleneck if scale grows: the cube view scan of `email_send_events`. Mitigations available: materialize on a refresh contract, partition `email_send_events` by month, or migrate to a columnar warehouse.

---

## Portability

The cube is implemented in standard SQL (PostgreSQL dialect) and is intentionally portable. The same definition runs on:

- PostgreSQL / Supabase (current deployment)
- BigQuery (minor syntax adjustments for date functions)
- Snowflake (minor syntax adjustments)
- DuckDB (near-identical syntax — useful for local analysis on parquet exports)

The Node.js report builder uses standard libraries (`docx`, `pg`) with no platform-specific dependencies. Migrating to a different SQL warehouse would require:

1. Re-pointing the connection string in the report builder
2. Minor syntax adjustments in the cube definition (mostly date functions)
3. Re-running the reconciliation test suite to confirm correctness

Total estimated migration time: under one day of engineering work.
