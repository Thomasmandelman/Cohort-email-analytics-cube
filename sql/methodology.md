# Methodology

This document explains the analytical foundations of the cube — how cohorts are defined, how metrics are computed, and why each design choice was made. The goal is to make every number in any output traceable to a specific definition, so reports can be defended under scrutiny.

---

## Core unit of analysis: the send event

Every row in the source-of-truth table is a single email send. One lead receiving three emails in a sequence is three rows, not one. This decision matters because:

- **Reply attribution stays clean.** A reply ties to a specific send, not a "lead".
- **Sequence position can be analyzed.** Step 1 vs step 2 vs step 3 performance is recoverable.
- **Aggregation is one `GROUP BY` away.** Lead-level, campaign-level, week-level rollups all derive from the same grain.
- **Reconciliation is straightforward.** Totals at lead grain must sum to operational totals; any discrepancy surfaces immediately.

---

## Cohorts: the most important dimension

Every lead is classified into exactly one of two cohorts at ingestion. This classification is structural and never changes for a given lead.

### Intent cohort

Leads sourced from vendors who provide signals that the prospect has indicated interest in the product category (or an adjacent one). Volume share is typically small (~10–20% of total sends) but performance is structurally higher.

### Prospecting cohort

Leads sourced from standard B2B prospecting platforms (subscription databases, scraped public sources). Volume share dominates (~80–90% of sends). Performance is materially lower per send.

### Why cohort separation is non-negotiable

The two cohorts have **mutually exclusive winning patterns** along multiple dimensions:

| Dimension | Intent cohort behavior | Prospecting cohort behavior |
|---|---|---|
| Best recipient class | Personal email (consumer accounts) | Business email (workspace accounts) |
| Best sender platform | Premium domain platforms | Same or different — context-dependent |
| Decay characteristics | Volatile, batch-driven | Gradual, list-saturation-driven |
| Opportunity rate | 5–10× the prospecting cohort | Baseline |
| Required emails per opp | ~1–2k | ~9–12k |

Mixing them in any aggregate metric **destroys the analytical signal**. A subject line or sender combination that wins for one cohort can lose for the other. The cube enforces this: there is no portfolio-wide source ranking — only intent-cohort source ranking and prospecting-cohort source ranking, presented separately in every output.

---

## Recipient classification

Each recipient email is classified into one of five categories at ingestion:

- **`gmail_personal`** — `@gmail.com` consumer accounts
- **`gmail_workspace_business`** — Google Workspace business accounts (custom domains using Google's mail infrastructure)
- **`ms_m365_business`** — Microsoft 365 business accounts
- **`business`** — Custom-domain business accounts on neither Google nor Microsoft infrastructure
- **`personal`** — Non-Gmail free consumer providers (iCloud, AOL, Yahoo, ProtonMail, etc.)

This classification matters because **the recipient platform meaningfully affects deliverability and response patterns** — workspace business accounts behave differently from consumer accounts regardless of who the recipient is as a person.

The `personal` vs `gmail_personal` split specifically exists because Gmail's consumer infrastructure has different deliverability characteristics than other consumer providers — important enough to track separately.

---

## Metrics

### Human Reply Rate (HRR)

```
HRR = human_replies ÷ sends
```

**Critical definition: HRR strictly excludes auto-replies.** Out-of-office responses, ticket-bot acknowledgments, and similar automated responses are counted in a separate `Auto-RR` metric. This prevents HRR inflation when a send hits an office on vacation.

### Auto-Reply Rate (Auto-RR)

```
Auto-RR = auto_replies ÷ sends
```

Tracked separately. Used as a sanity check — if HRR moves but Auto-RR doesn't, the change is genuinely in human engagement. If both move together, something structural changed in the recipient pool (e.g., a holiday).

### Opportunity Rate (Opp Rate)

```
Opp Rate = qualified_opportunities ÷ sends
```

The conversion-to-real-conversation rate. Much smaller than HRR (typically 5–15% of HRR) but the metric that ties to revenue.

### Emails per Opportunity (E/Opp)

```
E/Opp = sends ÷ opportunities
```

The inverse of Opp Rate. Used as the **primary efficiency metric** in reports because:

- It's interpretable at a glance ("we need 1,500 emails to generate one opp" lands better than "0.067% opp rate")
- It's the right unit for cost modeling — multiply by cost per send and you get cost per opp
- The scale (hundreds to tens of thousands) is easier to compare than tiny percentages
- Differences become more visible (a cell at 384 vs cohort average 1,400 reads as 3.6× more efficient — obvious)

### Bounce Rate

```
Bounce Rate = bounces ÷ sends
```

Tracked for infrastructure health. High bounce rates flag deliverability degradation, list quality issues, or sender reputation problems. Not a primary outcome metric but an essential operational signal.

---

## Rate calculation window

Rates are computed only over date ranges where replies have had time to settle in the warehouse. The general rule: a send dated **`T`** can only contribute to rate calculations if replies for that send have had at least 5–7 days to arrive and be processed.

In practice this means the most recent 3–7 days of sends are **excluded from rate calculations** even if they're present in the source data, because the denominators are incomplete. They show up in volume tracking ("how many sends went out") but not in rate analysis ("what % replied").

This rule prevents the trap of "Week N looks terrible" when actually Week N just hasn't finished settling.

---

## Per-cell variance tracking

Every `(cohort × sender × source × recipient_class)` cell with sufficient volume tracks its own historical performance week-over-week. This unlocks two things:

### Decay detection

Instead of using a single global threshold ("drop 30% from baseline"), the cube computes the natural variance σ of each cell. Decay is then defined as a drop below `baseline − 2σ` — statistically defensible per-cell.

This distinguishes:
- **Stable cells** with low variance, where a 20% drop is real signal
- **Volatile cells** with high variance, where a 30% drop is normal noise

A single global threshold misfires on both — it would flag false alarms on volatile cells and miss real decay on stable ones.

### Power analysis for testing

Knowing baseline HRR and per-cell variance defines the minimum sample size needed to detect a given effect with statistical power. This becomes the foundation for any A/B test or fractional factorial design built on top of the cube — gates can be set with mathematical backing rather than gut-feel sample size choices.

---

## Reconciliation

Every aggregation in the cube is verified against source-of-truth totals before being trusted. Specifically:

- Sum of sends across all cells = total sends in the operational system
- Sum of human replies across all cells = total human replies
- Sum of opportunities across all cells = total opportunities
- Cohort splits add to total (no leakage)
- Date ranges align across all dimensions

This is enforced in `sql/reconciliation.sql` as a test suite. If any check fails, the cube is considered broken and outputs are not generated until reconciliation passes.

---

## What the cube deliberately doesn't do

Some design choices are about what's *excluded*, not just what's included:

- **No campaign-level aggregation as a primary view.** Campaigns mix cohorts, sources, and time periods. The cube operates at lead grain and rolls up by structural dimensions, not by operational containers.
- **No "warmup" sends in rate denominators.** Warmup emails (internal-to-internal sends to maintain sender reputation) are excluded from all rate calculations — they would inflate volumes without contributing to outcomes.
- **No internal/test emails.** Sends to internal addresses, QA addresses, or known test domains are filtered out at ingestion.
- **No partial weeks at the edges.** Analysis windows always align to full ISO weeks for week-over-week comparability.

These exclusions are documented because they affect every downstream metric and need to be defensible.

---

## Summary

The cube's analytical value comes from three core choices:

1. **Lead-grain source of truth.** Every aggregation is one query away; reconciliation is straightforward; new dimensions are additive changes.
2. **Cohort as a first-class dimension.** Mixing structurally different lead types is the single most common analytical mistake in this domain. The cube prevents it by design.
3. **Reconciliation-first methodology.** Numbers that don't match source-of-truth are not published. Every metric in every output is verifiable end-to-end.
