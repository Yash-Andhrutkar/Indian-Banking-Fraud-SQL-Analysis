-- ============================================================================
-- 04_advanced_analysis.sql
-- Advanced SQL Analysis — Window Functions & CTEs
-- ============================================================================
-- CTEs, ROW_NUMBER, RANK/DENSE_RANK, LAG, running totals, rolling metrics,
-- and segmentation. Wherever a query needs true chronological transaction
-- order for a single customer, it derives transaction_ts = transaction_date
-- + transaction_time, consistent with the rest of the project.
-- ============================================================================


-- 1. Each customer's first and most recent transaction
-- Business Question: What is each customer's first and most recent transaction, in exact
-- chronological order?
-- SQL Skills: CTE, ROW_NUMBER window function (ascending and descending)
WITH ranked AS (
    SELECT
        customer_id,
        transaction_id,
        (transaction_date + transaction_time) AS transaction_ts,
        transaction_amount,
        ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY (transaction_date + transaction_time) ASC)  AS seq_asc,
        ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY (transaction_date + transaction_time) DESC) AS seq_desc
    FROM banking_transactions
)
SELECT
    customer_id,
    CASE WHEN seq_asc = 1 THEN 'First' ELSE 'Most Recent' END AS transaction_position,
    transaction_id,
    transaction_ts,
    transaction_amount
FROM ranked
WHERE seq_asc = 1 OR seq_desc = 1
ORDER BY customer_id, transaction_ts
LIMIT 50;


-- 2. State ranking by total value (RANK vs DENSE_RANK)
-- Business Question: How do states rank against each other by total transaction value, including
-- how ties would be handled two different ways?
-- SQL Skills: CTE, RANK, DENSE_RANK window functions
WITH state_totals AS (
    SELECT
        state,
        SUM(transaction_amount) AS total_value
    FROM banking_transactions
    GROUP BY state
)
SELECT
    state,
    total_value,
    RANK()       OVER (ORDER BY total_value DESC) AS value_rank,
    DENSE_RANK() OVER (ORDER BY total_value DESC) AS value_dense_rank
FROM state_totals
ORDER BY value_rank;


-- 3. Month-over-month growth rate
-- Business Question: What is the month-over-month percentage growth in total transaction value?
-- SQL Skills: CTE, LAG window function, NULLIF-protected growth-rate calculation
WITH monthly_totals AS (
    SELECT
        date_trunc('month', transaction_date)::date AS txn_month,
        SUM(transaction_amount)                     AS total_value
    FROM banking_transactions
    GROUP BY date_trunc('month', transaction_date)
)
SELECT
    txn_month,
    total_value,
    LAG(total_value) OVER (ORDER BY txn_month) AS prior_month_value,
    ROUND(
        100.0 * (total_value - LAG(total_value) OVER (ORDER BY txn_month))
        / NULLIF(LAG(total_value) OVER (ORDER BY txn_month), 0),
    2) AS mom_growth_pct
FROM monthly_totals
ORDER BY txn_month;


-- 4. Cumulative transaction value over time
-- Business Question: What does the bank's cumulative transaction value look like over time?
-- SQL Skills: window function running total (SUM OVER with ORDER BY)
WITH daily_totals AS (
    SELECT
        transaction_date,
        SUM(transaction_amount) AS daily_value
    FROM banking_transactions
    GROUP BY transaction_date
)
SELECT
    transaction_date,
    daily_value,
    SUM(daily_value) OVER (ORDER BY transaction_date) AS cumulative_value
FROM daily_totals
ORDER BY transaction_date;


-- 5. Rolling 7-day average of daily transaction volume
-- Business Question: What is the 7-day rolling average of daily transaction volume, smoothing
-- day-to-day noise?
-- SQL Skills: window function with an explicit ROWS BETWEEN frame (rolling average)
WITH daily_counts AS (
    SELECT
        transaction_date,
        COUNT(*) AS daily_transaction_count
    FROM banking_transactions
    GROUP BY transaction_date
)
SELECT
    transaction_date,
    daily_transaction_count,
    ROUND(
        AVG(daily_transaction_count) OVER (
            ORDER BY transaction_date
            ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
        ),
    2) AS rolling_7day_avg_count
FROM daily_counts
ORDER BY transaction_date;


-- 6. Customer value segmentation
-- Business Question: How can customers be segmented into value tiers based on total spend?
-- SQL Skills: CTE, NTILE window function for quartile-based segmentation
WITH customer_totals AS (
    SELECT
        customer_id,
        SUM(transaction_amount) AS total_spend
    FROM banking_transactions
    GROUP BY customer_id
),
segmented AS (
    SELECT
        customer_id,
        total_spend,
        NTILE(4) OVER (ORDER BY total_spend DESC) AS spend_quartile
    FROM customer_totals
)
SELECT
    CASE spend_quartile
        WHEN 1 THEN 'Tier 1 - Top Spenders'
        WHEN 2 THEN 'Tier 2 - High Spenders'
        WHEN 3 THEN 'Tier 3 - Moderate Spenders'
        WHEN 4 THEN 'Tier 4 - Low Spenders'
    END AS customer_segment,
    COUNT(*)                          AS customer_count,
    ROUND(SUM(total_spend), 2)        AS segment_total_value,
    ROUND(AVG(total_spend), 2)        AS avg_customer_value
FROM segmented
GROUP BY spend_quartile
ORDER BY spend_quartile;


-- 7. Merchant category fraud rate vs. bank-wide average
-- Business Question: Which merchant categories have a fraud rate meaningfully above the
-- bank-wide average?
-- SQL Skills: CTE, cross join comparison against an overall benchmark, NULLIF-protected rate
WITH category_fraud AS (
    SELECT
        merchant_category,
        COUNT(*)                             AS transaction_count,
        COUNT(*) FILTER (WHERE is_fraud = 1) AS fraud_count,
        ROUND(100.0 * COUNT(*) FILTER (WHERE is_fraud = 1) / NULLIF(COUNT(*), 0), 3) AS fraud_rate_pct
    FROM banking_transactions
    GROUP BY merchant_category
),
overall AS (
    SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE is_fraud = 1) / NULLIF(COUNT(*), 0), 3) AS overall_fraud_rate_pct
    FROM banking_transactions
)
SELECT
    cf.merchant_category,
    cf.transaction_count,
    cf.fraud_count,
    cf.fraud_rate_pct,
    o.overall_fraud_rate_pct,
    ROUND(cf.fraud_rate_pct - o.overall_fraud_rate_pct, 3) AS pct_points_vs_overall
FROM category_fraud cf
CROSS JOIN overall o
ORDER BY cf.fraud_rate_pct DESC;


-- 8. Top customers by value within each state
-- Business Question: Who are the top 3 highest-value customers within each state?
-- SQL Skills: CTE, ROW_NUMBER with PARTITION BY
WITH customer_state_totals AS (
    SELECT
        state,
        customer_id,
        SUM(transaction_amount) AS total_value
    FROM banking_transactions
    GROUP BY state, customer_id
),
ranked AS (
    SELECT
        state,
        customer_id,
        total_value,
        ROW_NUMBER() OVER (PARTITION BY state ORDER BY total_value DESC) AS rank_in_state
    FROM customer_state_totals
)
SELECT state, customer_id, total_value, rank_in_state
FROM ranked
WHERE rank_in_state <= 3
ORDER BY state, rank_in_state;


-- ============================================================================
-- Screenshot-worthy for GitHub: #3 (month-over-month growth with LAG) and #6
-- (NTILE customer segmentation) are the strongest technical-interview-style
-- outputs in this file.
-- ============================================================================
