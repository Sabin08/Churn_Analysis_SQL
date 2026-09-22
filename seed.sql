-- =============================================================================
-- Telecom Churn Analysis — Seed Data Generator
--
-- RDBMS COMPATIBILITY:
--   * PostgreSQL 16+ (PRIMARY)
--   * Oracle 19c+ (SUPPORTED)
--
-- ORACLE-SPECIFIC NOTES:
--   * setseed(0.42) → DBMS_RANDOM.SEED(42) — comment setseed, use Oracle equivalent
--   * generate_series() → custom function or WITH RECURSIVE (see hints below)
--   * Syntax: INSERTs are identical; CTEs (WITH) are portable
--   * INTERVAL 'n months' → INTERVAL '1' MONTH syntax in Oracle (single quotes)
--
-- Generates ~7.3M rows of realistic, dirty telecom data:
--   ~101K customers (with ~1.2K intentional duplicates)
--   ~130K subscriptions (incl. plan-change history)
--   ~2.8M usage_monthly rows (gaps + duplicates on purpose)
--   ~2.0M invoices (postpaid only)
--   ~2.1M payments (incl. failures, retries, reversals)
--   ~225K support_tickets
--
-- RUNTIME: 5–15 minutes on an 8GB laptop. Run the WHOLE script in ONE session.
-- setseed(0.42) makes the run reproducible — same random seed = same data.
--
-- DELIBERATE DIRT (the point):
--   * NULL + empty-string emails, genders, reason codes
--   * duplicate customers (same person, two customer_ids)
--   * duplicate usage rows; ~3% of usage months missing
--   * term_reason_code inconsistent: 'NONPAY' vs 'NP' vs 'nonpayment' vs '' vs NULL
--   * plan-change terminations that are NOT churn
--   * failed-payment streaks preceding involuntary terminations
--   * seasonal usage (Jul/Dec spikes, Jun–Aug roaming)
--   * usage decline in final 3 months before churn
--   * prepaid usage stops ~60 days BEFORE recorded end_date (silent churn)
-- =============================================================================

SET search_path TO core;

-- PostgreSQL: set random seed for reproducibility
SELECT setseed(0.42);

-- Oracle: for reproducible random data, use this instead:
-- BEGIN
--   DBMS_RANDOM.SEED(42);
-- END;
-- /

-- RE-RUN? Uncomment first to wipe old data:
-- TRUNCATE payments, invoices, usage_monthly, support_tickets,
--          subscriptions, customers, plans RESTART IDENTITY CASCADE;

-- =============================================================================
-- 1. PLANS — 12 static rows. Mix of prepaid/postpaid, two retired plans.
-- =============================================================================
INSERT INTO plans (plan_name, plan_type, monthly_fee, data_allowance_gb, voice_minutes, contract_months, is_active) VALUES
('Lite Prepaid',   'prepaid',  15.00,  5,   200,  0,  TRUE),
('Smart Prepaid',  'prepaid',  25.00,  15,  500,  0,  TRUE),
('Max Prepaid',    'prepaid',  35.00,  40,  NULL, 0,  TRUE),
('Data Prepaid',   'prepaid',  20.00,  25,  100,  0,  TRUE),
('Basic Post',     'postpaid', 40.00,  20,  1000, 12, TRUE),
('Standard Post',  'postpaid', 55.00,  50,  NULL, 12, TRUE),
('Premium Post',   'postpaid', 75.00,  NULL, NULL, 24, TRUE),
('Family Post',    'postpaid', 95.00,  100, NULL, 24, TRUE),
('Business Post',  'postpaid', 120.00, NULL, NULL, 24, TRUE),
('Senior Post',    'postpaid', 30.00,  10,  2000, 0,  TRUE),
('Legacy Talk',    'postpaid', 45.00,  2,   NULL, 0,  FALSE),
('Legacy Surf',    'prepaid',  18.00,  8,   300,  0,  FALSE);

-- =============================================================================
-- 2. CUSTOMERS — 100,000 rows. Materialized CTE ensures each name pick
--    is evaluated once, so email matches the name.
-- =============================================================================
WITH pick AS MATERIALIZED (
    SELECT g,
           (ARRAY['James','Mary','John','Patricia','Robert','Jennifer','Michael','Linda',
                  'David','Elizabeth','William','Susan','Richard','Jessica','Joseph','Sarah',
                  'Thomas','Karen','Carlos','Nancy','Ahmed','Fatima','Wei','Priya',
                  'Raj','Anita','Kevin','Laura','Brian','Emma','Jose','Sofia',
                  'Daniel','Olivia','Matthew','Ava','Anthony','Mia','Mark','Isabella'])[1 + floor(random()*40)::int] AS fn,
           (ARRAY['Smith','Johnson','Williams','Brown','Jones','Garcia','Miller','Davis',
                  'Rodriguez','Martinez','Hernandez','Lopez','Gonzalez','Wilson','Anderson','Thomas',
                  'Taylor','Moore','Jackson','Martin','Lee','Perez','Thompson','White',
                  'Harris','Sanchez','Clark','Ramirez','Lewis','Robinson','Walker','Young',
                  'Allen','King','Wright','Scott','Torres','Nguyen','Hill','Adams'])[1 + floor(random()*40)::int] AS ln
    FROM generate_series(1, 100000) AS g
)
INSERT INTO customers (first_name, last_name, email, date_of_birth, gender, region,
                       acquisition_channel, credit_score, joined_date)
SELECT
    fn,
    ln,
    CASE WHEN random() < 0.05 THEN NULL
         WHEN random() < 0.01 THEN ''
         ELSE lower(fn || '.' || ln || g || '@' ||
              (ARRAY['gmail.com','yahoo.com','outlook.com','mail.com','proton.me'])[1 + floor(random()*5)::int])
    END,
    CASE WHEN random() < 0.12 THEN NULL
         ELSE date '1950-01-01' + floor(random()*20000)::int END,
    CASE WHEN random() < 0.08 THEN NULL
         ELSE (ARRAY['M','F','Male','Female','female','m','','Other'])[1 + floor(random()*8)::int] END,
    (ARRAY['North','North','South','South','South','East','West','West','Central','Metro'])[1 + floor(random()*10)::int],
    CASE WHEN random() < 0.30 THEN NULL
         ELSE (ARRAY['online','retail_store','telesales','partner','referral'])[1 + floor(random()*5)::int] END,
    CASE WHEN random() < 0.15 THEN NULL
         ELSE 300 + floor(random()*551)::int END,
    date '2022-01-01' + floor(random()*1580)::int
FROM pick;

-- =============================================================================
-- 3. DUPLICATE CUSTOMERS — ~1,200 rows: same person, two customer_ids
-- =============================================================================
INSERT INTO customers (first_name, last_name, email, date_of_birth, gender, region,
                       acquisition_channel, credit_score, joined_date)
SELECT first_name, last_name, email, date_of_birth, gender, region,
       acquisition_channel, credit_score,
       LEAST(joined_date + floor(random()*90)::int, date '2026-06-30')
FROM customers
WHERE customer_id % 83 = 0;

-- =============================================================================
-- 4a. SUBSCRIPTIONS — first subscription for every customer
-- =============================================================================
INSERT INTO subscriptions (customer_id, plan_id, start_date, end_date, status,
                           term_reason_code, autopay_enrolled)
SELECT
    c.customer_id,
    pl.plan_id,
    c.joined_date,
    CASE
        WHEN c.customer_id % 100 < 30
            THEN LEAST(c.joined_date + (60 + floor(random()*540))::int, date '2026-05-31')
        WHEN c.customer_id % 100 BETWEEN 30 AND 49
            THEN LEAST(c.joined_date + (90 + floor(random()*1000))::int, date '2026-06-15')
        ELSE NULL
    END,
    CASE
        WHEN c.customer_id % 100 < 50            THEN 'terminated'
        WHEN c.customer_id % 100 IN (50, 51)     THEN 'suspended'
        ELSE 'active'
    END,
    CASE
        WHEN c.customer_id % 100 < 30 THEN
            (ARRAY['PLAN_CHG','plan_chg','UPGRADE','PLAN_CHANGE','',NULL,NULL])[1 + floor(random()*7)::int]
        WHEN c.customer_id % 100 BETWEEN 30 AND 37 THEN
            (ARRAY['NONPAY','NP','nonpayment','COLLECTIONS','UNKNOWN','',NULL,NULL])[1 + floor(random()*8)::int]
        WHEN c.customer_id % 100 BETWEEN 38 AND 49 THEN
            (ARRAY['CUST_REQ','cust_req','MOVED','PRICE','COMPETITOR','UNKNOWN','',NULL,NULL])[1 + floor(random()*9)::int]
        ELSE NULL
    END,
    CASE WHEN pl.plan_type = 'postpaid' THEN random() < 0.65 ELSE random() < 0.15 END
FROM customers c
CROSS JOIN LATERAL (
    SELECT p.plan_id, p.plan_type
    FROM plans p
    WHERE p.plan_id = CASE WHEN (c.customer_id % 10) < 4
                           THEN (ARRAY[1,2,3,4,12])[1 + (c.customer_id % 5)::int]
                           ELSE (ARRAY[5,6,7,8,9,10,11])[1 + (c.customer_id % 7)::int]
                      END
) pl;

-- =============================================================================
-- 4b. SUBSCRIPTIONS — second subscription for plan changers
-- =============================================================================
INSERT INTO subscriptions (customer_id, plan_id, start_date, end_date, status,
                           term_reason_code, autopay_enrolled)
SELECT
    s.customer_id,
    5 + ((s.plan_id + 3) % 7),
    s.end_date + 1,
    CASE WHEN s.customer_id % 7 = 0
         THEN LEAST(s.end_date + 1 + (60 + floor(random()*600))::int, date '2026-06-15')
         ELSE NULL END,
    CASE WHEN s.customer_id % 7 = 0 THEN 'terminated' ELSE 'active' END,
    CASE WHEN s.customer_id % 7 = 0 THEN
        CASE WHEN s.customer_id % 14 = 0
             THEN (ARRAY['NONPAY','NP','',NULL])[1 + floor(random()*4)::int]
             ELSE (ARRAY['CUST_REQ','MOVED','PRICE','',NULL])[1 + floor(random()*5)::int]
        END
    ELSE NULL END,
    random() < 0.6
FROM subscriptions s
WHERE s.customer_id % 100 < 30;

-- =============================================================================
-- 5a. USAGE_MONTHLY — one row per subscription per month (3% gap months)
--     Seasonality: Jul/Dec data spikes, Jun–Aug roaming
--     Pre-churn signal: usage drops to ~35% in final 3 months
--     Silent prepaid churn: usage stops ~60 days before end_date
-- =============================================================================
INSERT INTO usage_monthly (subscription_id, usage_month, data_gb, voice_minutes,
                           sms_count, intl_minutes, roaming_charges)
SELECT
    s.subscription_id,
    m.mon,
    CASE WHEN random() < 0.02 THEN NULL
         ELSE round((
              COALESCE(p.data_allowance_gb, 60) * (0.15 + random()*0.85)
              * CASE WHEN EXTRACT(MONTH FROM m.mon) IN (7, 12) THEN 1.25 ELSE 1.0 END
              * CASE WHEN s.end_date IS NOT NULL
                      AND m.mon > (date_trunc('month', s.end_date) - interval '3 months')::date
                     THEN 0.35 ELSE 1.0 END
              )::numeric, 2)
    END,
    (COALESCE(p.voice_minutes, 1500) * (0.05 + random()*0.75)
       * CASE WHEN s.end_date IS NOT NULL
               AND m.mon > (date_trunc('month', s.end_date) - interval '3 months')::date
              THEN 0.4 ELSE 1.0 END)::int,
    floor(random()*80)::int,
    CASE WHEN random() < 0.15 THEN floor(random()*120)::int ELSE 0 END,
    CASE WHEN EXTRACT(MONTH FROM m.mon) IN (6, 7, 8) AND random() < 0.30
             THEN round((random()*45)::numeric, 2)
         WHEN random() < 0.05 THEN round((random()*20)::numeric, 2)
         ELSE 0 END
FROM subscriptions s
JOIN plans p ON p.plan_id = s.plan_id
CROSS JOIN LATERAL generate_series(
    date_trunc('month', s.start_date::timestamp),
    date_trunc('month', LEAST(
        COALESCE(CASE WHEN p.plan_type = 'prepaid' AND s.end_date IS NOT NULL
                      THEN s.end_date - 60
                      ELSE s.end_date END,
                 date '2026-06-30'),
        date '2026-06-30')::timestamp),
    interval '1 month') AS m0(ts)
CROSS JOIN LATERAL (SELECT m0.ts::date AS mon) m
WHERE random() > 0.03;

-- =============================================================================
-- 5b. DUPLICATE USAGE ROWS — ~0.4% re-ingested
-- =============================================================================
INSERT INTO usage_monthly (subscription_id, usage_month, data_gb, voice_minutes,
                           sms_count, intl_minutes, roaming_charges)
SELECT subscription_id, usage_month, data_gb, voice_minutes,
       sms_count, intl_minutes, roaming_charges
FROM usage_monthly
WHERE random() < 0.004;

-- =============================================================================
-- 6. INVOICES — postpaid only, one per month
-- =============================================================================
INSERT INTO invoices (subscription_id, billing_period, amount_due, issue_date, due_date)
SELECT
    s.subscription_id,
    m0.ts::date,
    round((p.monthly_fee *
           CASE WHEN random() < 0.20 THEN 1 + random()*0.35 ELSE 1 END)::numeric, 2),
    m0.ts::date + 5,
    m0.ts::date + 26
FROM subscriptions s
JOIN plans p ON p.plan_id = s.plan_id
CROSS JOIN LATERAL generate_series(
    date_trunc('month', s.start_date::timestamp),
    date_trunc('month', COALESCE(s.end_date, date '2026-06-30')::timestamp),
    interval '1 month') AS m0(ts)
WHERE p.plan_type = 'postpaid';

-- =============================================================================
-- 7a. PAYMENTS — normal behavior. 90% on time, ~8% late, 2% never pay
-- =============================================================================
WITH base AS MATERIALIZED (
    SELECT i.invoice_id, i.amount_due, i.due_date,
           (s.end_date IS NOT NULL
            AND (s.customer_id % 100 BETWEEN 30 AND 37
                 OR (s.customer_id % 100 < 30 AND s.customer_id % 14 = 0))
            AND i.billing_period > (date_trunc('month', s.end_date) - interval '3 months')::date
           ) AS invol_tail,
           random() AS r1, random() AS r2, random() AS r3
    FROM invoices i
    JOIN subscriptions s USING (subscription_id)
)
INSERT INTO payments (invoice_id, payment_date, amount_paid, method, status)
SELECT
    invoice_id,
    LEAST(CASE WHEN r1 < 0.90 THEN due_date - floor(r2*12)::int
               ELSE due_date + (1 + floor(r2*40))::int END,
          date '2026-07-20'),
    CASE WHEN r3 < 0.015 THEN round((amount_due * (0.3 + 0.5*r2))::numeric, 2)
         ELSE amount_due END,
    (ARRAY['card','card','card','bank_transfer','bank_transfer','wallet','cash','other'])[1 + floor(random()*8)::int],
    'success'
FROM base
WHERE NOT invol_tail
  AND r1 < 0.98;

-- =============================================================================
-- 7b. FAILED ATTEMPTS (~3%) + REVERSALS (~0.3%) on normal invoices
-- =============================================================================
INSERT INTO payments (invoice_id, payment_date, amount_paid, method, status)
SELECT invoice_id, LEAST(due_date + floor(random()*5)::int, date '2026-07-20'),
       amount_due, 'card', 'failed'
FROM invoices WHERE random() < 0.03;

INSERT INTO payments (invoice_id, payment_date, amount_paid, method, status)
SELECT invoice_id, LEAST(due_date + floor(random()*15)::int, date '2026-07-20'),
       amount_due, 'card', 'reversed'
FROM invoices WHERE random() < 0.003;

-- =============================================================================
-- 7c. INVOLUNTARY-CHURN SIGNATURE — failed payments on final 3 invoices
--     of involuntary churners. No success ever follows.
-- =============================================================================
INSERT INTO payments (invoice_id, payment_date, amount_paid, method, status)
SELECT i.invoice_id,
       LEAST(i.due_date + (1 + floor(random()*10))::int, date '2026-07-20'),
       i.amount_due,
       (ARRAY['card','bank_transfer'])[1 + (i.invoice_id % 2)::int],
       'failed'
FROM invoices i
JOIN subscriptions s USING (subscription_id)
WHERE s.end_date IS NOT NULL
  AND (s.customer_id % 100 BETWEEN 30 AND 37
       OR (s.customer_id % 100 < 30 AND s.customer_id % 14 = 0))
  AND i.billing_period > (date_trunc('month', s.end_date) - interval '3 months')::date;

INSERT INTO payments (invoice_id, payment_date, amount_paid, method, status)
SELECT i.invoice_id,
       LEAST(i.due_date + (6 + floor(random()*10))::int, date '2026-07-20'),
       i.amount_due, 'card', 'failed'
FROM invoices i
JOIN subscriptions s USING (subscription_id)
WHERE s.end_date IS NOT NULL
  AND (s.customer_id % 100 BETWEEN 30 AND 37
       OR (s.customer_id % 100 < 30 AND s.customer_id % 14 = 0))
  AND i.billing_period > (date_trunc('month', s.end_date) - interval '3 months')::date
  AND random() < 0.6;

-- =============================================================================
-- 8a. SUPPORT_TICKETS — 0–4 per customer (avg ~2). csat ~70% NULL
-- =============================================================================
INSERT INTO support_tickets (customer_id, opened_at, closed_at, channel, category,
                             priority, resolution_status, csat_score)
SELECT
    c.customer_id,
    op.ts,
    CASE WHEN random() < 0.85 THEN op.ts + random() * interval '14 days' ELSE NULL END,
    (ARRAY['phone','phone','chat','chat','email','store'])[1 + floor(random()*6)::int],
    (ARRAY['billing','billing','network','service','device','other',''])[1 + floor(random()*7)::int],
    (ARRAY['low','medium','medium','high','urgent'])[1 + floor(random()*5)::int],
    (ARRAY['resolved','resolved','resolved','escalated','unresolved','',NULL])[1 + floor(random()*7)::int],
    CASE WHEN random() < 0.30 THEN 1 + floor(random()*5)::int ELSE NULL END
FROM customers c
CROSS JOIN LATERAL generate_series(1, floor(random()*5)::int) AS g(k)
CROSS JOIN LATERAL (
    SELECT c.joined_date::timestamp
           + random() * (timestamp '2026-07-01' - c.joined_date::timestamp) AS ts
) op;

-- =============================================================================
-- 8b. PRE-CHURN TICKET CLUSTER — ~50% of churners raise tickets in 60 days before
-- =============================================================================
INSERT INTO support_tickets (customer_id, opened_at, closed_at, channel, category,
                             priority, resolution_status, csat_score)
SELECT
    s.customer_id,
    op.ts,
    CASE WHEN random() < 0.80 THEN op.ts + random() * interval '10 days' ELSE NULL END,
    (ARRAY['phone','phone','chat','email'])[1 + floor(random()*4)::int],
    (ARRAY['billing','billing','billing','network','service'])[1 + floor(random()*5)::int],
    (ARRAY['medium','high','high','urgent'])[1 + floor(random()*4)::int],
    (ARRAY['resolved','escalated','unresolved','unresolved'])[1 + floor(random()*4)::int],
    CASE WHEN random() < 0.40 THEN 1 + floor(random()*3)::int ELSE NULL END
FROM subscriptions s
CROSS JOIN LATERAL (
    SELECT GREATEST(s.start_date, s.end_date - floor(random()*60)::int)::timestamp
           + random() * interval '12 hours' AS ts
) op
WHERE s.end_date IS NOT NULL
  AND (s.customer_id % 100 BETWEEN 30 AND 49
       OR (s.customer_id % 100 < 30 AND s.customer_id % 7 = 0))
  AND random() < 0.5;

-- =============================================================================
-- 9. STATISTICS
-- =============================================================================
-- PostgreSQL: update table statistics for query planner
-- Oracle: gather statistics using DBMS_STATS
-- Uncomment as needed for your RDBMS

-- PostgreSQL only:
-- ANALYZE customers; ANALYZE plans; ANALYZE subscriptions;
-- ANALYZE usage_monthly; ANALYZE invoices; ANALYZE payments; ANALYZE support_tickets;

-- Oracle only (after seed completes):
-- BEGIN
--   DBMS_STATS.gather_schema_stats('CORE');
-- END;
-- /

-- =============================================================================
-- Data load complete. Run validation queries separately (see README).
-- =============================================================================
