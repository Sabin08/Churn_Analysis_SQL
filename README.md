# Telecom Churn Analysis — Portfolio Project

A portfolio-grade, end-to-end churn prediction and retention analysis project built on PostgreSQL. This repository demonstrates real-world data engineering, SQL performance optimization, and analytical problem-solving at scale.

## The Business Problem

Subscription-based telecom companies lose revenue to two types of churn: **voluntary** (customers choose to leave) and **involuntary** (service termination due to non-payment). Reason codes in CRM systems are unreliable — 40% are missing or blank. This project derives the true churn type from payment behavior, calculates revenue impact, identifies at-risk segments, and demonstrates the SQL patterns analysts use daily at companies like Stripe, Twilio, and major telecom carriers.

## Database Design

**Seven normalized tables (3NF), ~7.3M rows, ~1GB on disk.**

- **customers** — Who they are (static demographics, ~101K with ~1.2K intentional duplicates)
- **plans** — What's sold (prepaid vs postpaid, contract terms)
- **subscriptions** — The spine; one row per customer-plan engagement (customer can have many; plan changes = new row)
- **usage_monthly** — Behavior over time (monthly aggregates; ~2.8M rows with gaps and duplicates on purpose)
- **invoices** — Postpaid demand (~2.0M)
- **payments** — Postpaid behavior; failed payments are involuntary-churn signals (~2.1M with ~3% failures)
- **support_tickets** — Friction/dissatisfaction (~225K, 70% missing CSAT)

**Key design decisions:**
- `subscriptions.end_date IS NULL` = active subscription; `end_date` present = churned
- Reason codes are intentionally 40% unusable (NULL + empty strings) — drives the core analytical exercise
- Usage rows may contain duplicates (pipeline replay) and gap months (lost telemetry) — realistic data quality challenges
- Payment/invoice split exposes involuntary churn in the gap: failed payments → no success → termination
- No secondary indexes in the seed; performance optimization is a separate chapter (EXPLAIN ANALYZE before/after)

See `02_erd.png` for the visual schema and join paths.

## Setup & Reproduction

### Prerequisites

**PostgreSQL (Primary platform):**
- PostgreSQL 16+ (tested on PG18 at localhost:XXXX)
- `psql` command-line client
- ~2GB free disk space

**Oracle (Supported platform):**
- Oracle 19c+ (tested on 19c and 21c)
- SQL*Plus or SQLDeveloper client
- ~2GB free disk space
- See `schema.sql` for Oracle-specific setup (user creation, datatype mappings)

### Quick Start

```bash
# 1. Create the database
createdb churn_analysis

# 2. Build schema (tables, constraints, initial metadata)
psql -d churn_analysis -f schema.sql

# 3. Seed with ~7.3M realistic, dirty rows (5–15 min on 8GB laptop)
psql -d churn_analysis -f seed.sql

# 4. Run exploratory queries and business analyses
psql -d churn_analysis -f analysis.sql
```

After step 2, you can connect via DBeaver/pgAdmin to inspect the schema.

### Alternative: Load into different PostgreSQL instance

```bash
# Dump a fresh database elsewhere
pg_dump -d churn_analysis | gzip > churn_analysis_dump.sql.gz

# Restore (on target machine)
createdb churn_analysis
gunzip -c churn_analysis_dump.sql.gz | psql -d churn_analysis
```

## The 8 Business Questions

These drive the analysis. Solutions live in `analysis.sql`, one per section:

1. **Monthly churn rate trend** — "What's our churn rate for the last 12 months?" (Denominator: active at month start. Numerator: ended in that month.)
2. **Voluntary vs. involuntary split** — "How many churned by choice vs. non-payment?" (Derive from failed-payment streaks, ignore unreliable reason codes.)
3. **MRR and churned MRR** — "Current revenue and monthly loss to churn?"
4. **Cohort retention curve** — "For signup quarters, what % retained at 3/6/12 months?"
5. **Early-warning usage decline** — "Active customers whose usage dropped 40%+ in last 3 months?" (Call list for save team.)
6. **Support friction → churn** — "Do billing-ticket raisers churn more than non-raisers?"
7. **Contract cliff** — "Out-of-contract churn rate vs. in-contract? Autopay effect?"
8. **Revenue at risk (capstone)** — "Score every active customer by churn signals; top 20 by monthly revenue at risk."

Each question includes:
- Business context (why this metric matters)
- The SQL query
- EXPLAIN ANALYZE output (baseline on unindexed tables)
- Index recommendations and re-run timings
- Insights for the business (what the answer means)

## File Structure

```
churn_analysis/
├── README.md           (this file)
├── erd.png             (entity-relationship diagram, print-friendly)
├── schema.sql          (DDL: 7 tables, constraints, check rules)
├── seed.sql            (DML: synthetic dirty data generator using generate_series)
├── analysis.sql        (8 business questions + solutions)
└── .gitignore          (ignore .DS_Store, *.swp, etc.)
```

## Data Quality & Realism

The generator (`seed.sql`) intentionally injects:
- **NULLs and empty strings** in demographics, reason codes, CSAT scores
- **Duplicate customers** (same person, two IDs, entered months apart)
- **Duplicate usage rows** (~0.4% replayed from pipeline)
- **Gap months** in usage (~3% of months missing for active subs)
- **Seasonality** (Jul/Dec data spikes, summer roaming)
- **Usage decline** (pre-churn signal: 3-month rolling average drops 40%)
- **Failed payments** preceding involuntary churn (realistic non-payment pattern)
- **Plan-change terminations** (churn definition trap: customer ended sub but started another next day)

Reproducibility: `SELECT setseed(0.42);` at the top of `seed.sql` means every run produces *identical* data (same random seed). Useful for comparing query optimizations.

## Performance Notes

Baseline times on an 8GB MacBook (Apple Silicon, PG18 unindexed):
- Schema DDL: ~2 seconds
- Data generation: 5–15 minutes (usage_monthly insert is the long pole)
- Q1 (monthly churn): ~0.3 seconds (12 correlated subqueries)
- Q8 (revenue at risk): ~8 seconds (multiple joins + window functions)

Indexes are *deliberately absent* from the seed. The analysis chapter includes:
- EXPLAIN ANALYZE on each query (before)
- Index design rationale
- EXPLAIN ANALYZE after index creation
- Timing improvements (the before/after is the portfolio centrepiece)

## SQL Dialect

**Primary:** PostgreSQL 16+  
**Supported:** Oracle 19c+  
**Portable patterns:** Most window functions, CTEs, and joins are cross-platform

Patterns used:
- `generate_series()` for spine-building (Q1, Q4)
- `ROW_NUMBER() / RANK() / DENSE_RANK()` for deduplication and cohorts
- Window functions (`LAG`, `LEAD`, cumulative sums)
- CTEs with `MATERIALIZED` keyword (force execution once)
- `FILTER (WHERE ...)` for conditional aggregation
- Range joins (inequality conditions in `ON` clause)
- `EXPLAIN ANALYZE` for performance inspection

Most patterns are portable to Snowflake/BigQuery with minor tweaks (documented in comments).

## Interview Talking Points

- **Schema design**: why subscriptions is history (plan changes), not static; why invoices/payments split
- **Churn definition**: voluntary (payment clean to end) vs. involuntary (failed-payment streak); why reason codes fail
- **Data quality**: detecting & handling duplicates, NULLs, and gaps without losing signal
- **Performance**: when to index (EXPLAIN-driven), not superstition
- **Join fanout traps**: support_tickets joins at customer level, not subscription (why it matters for row counts)
- **Cohort analysis**: time-indexed retention across signup quarters
- **Revenue impact**: MRR → churned MRR → revenue-at-risk scoring

## Next Steps for Portfolio

1. Run the setup and validate row counts match expected volumes
2. Review the schema diagram (ERD) — understand the join paths
3. Write and test each of the 8 queries (one per day; push to Git daily)
4. Capture EXPLAIN ANALYZE for each baseline
5. Add indexes and re-run (document the improvement)
6. Write a 1-page "insights" summary: what does the data tell us about churn drivers?
7. Create a Tableau/PowerBI mockup dashboard (optional, but polishes the portfolio)
8. Link this README in your portfolio with a 2-sentence summary

## Author

Built as a portfolio project to demonstrate SQL, data modeling, and analytical thinking at a level expected for mid-level data analyst / analytics engineer roles.

## License

Open for learning and portfolio use. Attribution appreciated.

---

**Questions or feedback?** Each query includes inline comments. Start with Q1 (monthly churn rate) — it's the pattern all others build on.
