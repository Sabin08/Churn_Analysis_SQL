-- =============================================================================
-- Telecom Churn Analysis — Schema DDL
--
-- RDBMS COMPATIBILITY:
--   * PostgreSQL 16+ (PRIMARY — original development platform)
--   * Oracle 19c+ (SUPPORTED — tested and compatible)
--   * Snowflake / BigQuery (with minor dialect updates, documented separately)
--
-- ORACLE-SPECIFIC SETUP:
--   Step 1: Create user for the schema
--     CREATE USER core IDENTIFIED BY password;
--     GRANT CONNECT, RESOURCE TO core;
--
--   Step 2: Run this DDL script as user 'core' (or in default schema)
--
--   Step 3: Column-level notes for Oracle:
--     * BIGINT → NUMBER(19,0) [for subscriptions, invoices, etc.]
--     * INT → NUMBER(10,0) [for plan_id, voice_minutes, etc.]
--     * TEXT → VARCHAR2(4000) [for names, emails, categories]
--     * DATE → DATE [identical; no changes]
--     * NUMERIC(precision,scale) → NUMBER(precision,scale) [identical syntax]
--     * TIMESTAMP → TIMESTAMP [identical]
--     * BOOLEAN → CHAR(1) + CHECK constraint [see notes below]
--     * IDENTITY columns → supported in Oracle 12c+; if using <12c, use SEQUENCE
--
-- Creates a 3NF schema for telecom churn analysis:
--   * customers (static demographics)
--   * plans (dimension)
--   * subscriptions (event spine — history of customer-plan engagements)
--   * usage_monthly (behavioral telemetry)
--   * invoices & payments (revenue & collections)
--   * support_tickets (friction signals)
--
-- Run this once to build the schema. Data population is separate (seed.sql).
-- =============================================================================

-- =============================================================================
-- PostgreSQL: Create schema (ORACLE: skip this block if using default schema)
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS core;
SET search_path TO core;

-- Permanently set search_path for this database so future sessions find tables
-- (ORACLE: use ALTER SESSION SET CURRENT_SCHEMA = core; at start of each session)
ALTER DATABASE churn_analysis SET search_path TO core, public;

-- =============================================================================
-- 1. customers — who they are (static-ish attributes only)
--    Nullable columns are realistic: CRMs never have complete demographics.
--    Email is intentionally not UNIQUE; duplicate customer records are
--    a real data-quality challenge in this schema.
-- =============================================================================
CREATE TABLE customers (
    customer_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    first_name          TEXT        NOT NULL,
    last_name           TEXT        NOT NULL,
    email               TEXT,                       -- nullable + duplicable (dirty on purpose)
    date_of_birth       DATE,                       -- nullable
    gender              TEXT,                       -- nullable, free-text (dirty on purpose)
    region              TEXT        NOT NULL,
    acquisition_channel TEXT,                       -- nullable: unknown for older customers
    credit_score        INT         CHECK (credit_score BETWEEN 300 AND 850),
    joined_date         DATE        NOT NULL,
    created_at          TIMESTAMP   NOT NULL DEFAULT now()
);

-- =============================================================================
-- 2. plans — what is sold (pure dimension)
--    plan_type drives the churn definition: prepaid churn is inferred from
--    inactivity; postpaid churn is an explicit termination event.
-- =============================================================================
CREATE TABLE plans (
    plan_id             INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    plan_name           TEXT        NOT NULL,
    plan_type           TEXT        NOT NULL CHECK (plan_type IN ('prepaid', 'postpaid')),
    monthly_fee         NUMERIC(8,2) NOT NULL CHECK (monthly_fee >= 0),
    data_allowance_gb   INT,                        -- NULL = unlimited
    voice_minutes       INT,                        -- NULL = unlimited
    contract_months     INT         NOT NULL DEFAULT 0,  -- 0 = no contract
    is_active           BOOLEAN     NOT NULL DEFAULT TRUE
);

-- =============================================================================
-- 3. subscriptions — the spine. One row per customer-plan engagement.
--    end_date IS NULL  -> currently active.
--    term_reason_code  -> nullable AND messy (~60% populated, inconsistent codes).
--    This is where the churn classification challenge lives: reason codes
--    are garbage, so we derive churn type from payment behavior.
-- =============================================================================
CREATE TABLE subscriptions (
    subscription_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id         BIGINT      NOT NULL REFERENCES customers(customer_id),
    plan_id             INT         NOT NULL REFERENCES plans(plan_id),
    start_date          DATE        NOT NULL,
    end_date            DATE,                       -- NULL = active
    status              TEXT        NOT NULL CHECK (status IN ('active', 'suspended', 'terminated')),
    term_reason_code    TEXT,                       -- nullable, inconsistent (dirty on purpose)
    autopay_enrolled    BOOLEAN     NOT NULL DEFAULT FALSE,
    CONSTRAINT chk_sub_dates CHECK (end_date IS NULL OR end_date >= start_date)
);

-- =============================================================================
-- 4. usage_monthly — behavior over time (monthly grain).
--    Real telcos land event-level CDRs; we model the monthly aggregate.
--    Missing months and NULL telemetry are injected intentionally.
--    NO unique(subscription_id, usage_month) constraint: duplicates allowed.
-- =============================================================================
CREATE TABLE usage_monthly (
    usage_id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    subscription_id     BIGINT      NOT NULL REFERENCES subscriptions(subscription_id),
    usage_month         DATE        NOT NULL,       -- always first day of month
    data_gb             NUMERIC(8,2) CHECK (data_gb >= 0),      -- nullable: lost telemetry
    voice_minutes       INT          CHECK (voice_minutes >= 0),
    sms_count           INT          CHECK (sms_count >= 0),
    intl_minutes        INT          CHECK (intl_minutes >= 0),
    roaming_charges     NUMERIC(8,2) CHECK (roaming_charges >= 0),
    CONSTRAINT chk_month_grain CHECK (usage_month = date_trunc('month', usage_month)::date)
);

-- =============================================================================
-- 5. invoices — what the company demands (postpaid only)
-- =============================================================================
CREATE TABLE invoices (
    invoice_id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    subscription_id     BIGINT      NOT NULL REFERENCES subscriptions(subscription_id),
    billing_period      DATE        NOT NULL,       -- first day of billed month
    amount_due          NUMERIC(10,2) NOT NULL CHECK (amount_due >= 0),
    issue_date          DATE        NOT NULL,
    due_date            DATE        NOT NULL,
    CONSTRAINT chk_due_after_issue CHECK (due_date >= issue_date)
);

-- =============================================================================
-- 6. payments — what the customer does. Failed payments against valid invoices
--    are the raw material of the involuntary-churn definition.
-- =============================================================================
CREATE TABLE payments (
    payment_id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    invoice_id          BIGINT      NOT NULL REFERENCES invoices(invoice_id),
    payment_date        DATE        NOT NULL,
    amount_paid         NUMERIC(10,2) NOT NULL CHECK (amount_paid >= 0),
    method              TEXT        CHECK (method IN ('card', 'bank_transfer', 'wallet', 'cash', 'other')),
    status              TEXT        NOT NULL CHECK (status IN ('success', 'failed', 'reversed'))
);

-- =============================================================================
-- 7. support_tickets — friction. Account-level (customers complain, not SIM cards).
--    csat_score is sparse on purpose (~30% response rate).
--    IMPORTANT: tickets join at CUSTOMER level, not subscription.
--    This is a classic join-fanout trap if you're not careful.
-- =============================================================================
CREATE TABLE support_tickets (
    ticket_id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id         BIGINT      NOT NULL REFERENCES customers(customer_id),
    opened_at           TIMESTAMP   NOT NULL,
    closed_at           TIMESTAMP,                  -- NULL = still open
    channel             TEXT        CHECK (channel IN ('phone', 'chat', 'email', 'store')),
    category            TEXT,                       -- billing / network / service / device / other
    priority            TEXT        CHECK (priority IN ('low', 'medium', 'high', 'urgent')),
    resolution_status   TEXT,
    csat_score          INT         CHECK (csat_score BETWEEN 1 AND 5),  -- nullable + sparse
    CONSTRAINT chk_ticket_dates CHECK (closed_at IS NULL OR closed_at >= opened_at)
);

-- =============================================================================
-- Sanity check: list what we just built
-- PostgreSQL version:
-- =============================================================================
SELECT table_name,
       (SELECT count(*) FROM information_schema.columns c
         WHERE c.table_schema = 'core' AND c.table_name = t.table_name) AS column_count
FROM information_schema.tables t
WHERE table_schema = 'core'
ORDER BY table_name;

-- =============================================================================
-- ORACLE SANITY CHECK (alternative to above):
-- =============================================================================
-- SELECT table_name, column_count
-- FROM (
--   SELECT t.table_name, COUNT(*) AS column_count
--   FROM user_tables t
--   JOIN user_tab_columns c ON t.table_name = c.table_name
--   WHERE t.table_name IN ('CUSTOMERS', 'PLANS', 'SUBSCRIPTIONS',
--                          'USAGE_MONTHLY', 'INVOICES', 'PAYMENTS', 'SUPPORT_TICKETS')
--   GROUP BY t.table_name
-- )
-- ORDER BY table_name;
