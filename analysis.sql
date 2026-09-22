-- =====================================================================
-- Telecom Churn Analysis - Enterprise Analytical Queries
-- =====================================================================

-- 1. Monthly Churn Rate Trend (Jul 2025 - Jun 2026)
-- Calculates churn rate per month: subscriptions churned / subscriptions active at month start.
-- Reveals seasonal patterns and retention trends over a 12-month rolling window.
WITH months AS (
    SELECT generate_series(
        '2025-07-01'::date,
        '2026-06-01'::date,
        '1 month'::interval
    )::date AS month_start
),
monthly_metrics AS (
    SELECT
        m.month_start,
        (
            SELECT COUNT(*)
            FROM subscriptions s
            WHERE s.start_date < m.month_start
              AND (s.end_date >= m.month_start OR s.end_date IS NULL)
        ) AS active_at_start,
        (
            SELECT COUNT(*)
            FROM subscriptions s
            WHERE s.end_date >= m.month_start
              AND s.end_date < (m.month_start + INTERVAL '1 month')
        ) AS churned
    FROM months m
)
SELECT
    month_start,
    active_at_start,
    churned,
    round(
        churned * 100.0 / NULLIF(active_at_start, 0),
        2
    ) AS churn_rate_pct
FROM monthly_metrics
ORDER BY month_start ASC;
