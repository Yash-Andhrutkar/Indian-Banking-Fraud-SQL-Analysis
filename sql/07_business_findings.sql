-- ============================================================================
-- 07_business_findings.sql
-- Business Findings — Recruiter-Facing Outputs
-- ============================================================================
-- Every query here is designed so its result can be converted directly into a
-- one-line finding. Median/percentile views are used wherever the mean would
-- be misleading given the dataset's strongly right-skewed amount distribution
-- (mean ~₹29,907 vs. median ~₹2,036).
-- ============================================================================


-- 1. Annual transaction growth trend
-- Business Question: How has the bank's transaction volume and value grown year over year?
-- SQL Skills: CTE, LAG window function, NULLIF-protected growth-rate calculation
-- Note: the dataset runs 2019-01-01 to 2024-01-01, so 2024 contains only a single day of
-- data — treat its row as a boundary marker, not a comparable full year, when interpreting growth.
WITH yearly AS (
    SELECT
        EXTRACT(YEAR FROM transaction_date)::int AS txn_year,
        COUNT(*)                                 AS transaction_count,
        SUM(transaction_amount)                  AS total_value
    FROM banking_transactions
    GROUP BY EXTRACT(YEAR FROM transaction_date)
)
SELECT
    txn_year,
    transaction_count,
    total_value,
    LAG(total_value) OVER (ORDER BY txn_year) AS prior_year_value,
    ROUND(
        100.0 * (total_value - LAG(total_value) OVER (ORDER BY txn_year))
        / NULLIF(LAG(total_value) OVER (ORDER BY txn_year), 0),
    2) AS yoy_growth_pct
FROM yearly
ORDER BY txn_year;


-- 2. Account type value contribution
-- Business Question: Which account types contribute the most transaction value, and how does
-- their typical (median) transaction size compare to their average?
-- SQL Skills: GROUP BY, PERCENTILE_CONT ordered-set aggregate, nested window-over-aggregate for
-- percent-of-total
SELECT
    account_type,
    COUNT(*)                                                                      AS transaction_count,
    SUM(transaction_amount)                                                       AS total_value,
    ROUND(100.0 * SUM(transaction_amount) / NULLIF(SUM(SUM(transaction_amount)) OVER (), 0), 2) AS pct_of_total_value,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY transaction_amount)::numeric, 2)           AS median_transaction_amount,
    ROUND(AVG(transaction_amount), 2)                                             AS avg_transaction_amount
FROM banking_transactions
GROUP BY account_type
ORDER BY total_value DESC;


-- 3. Channel adoption over time
-- Business Question: How has the mix of transaction channels shifted year over year (e.g., digital
-- channels gaining share versus Branch/ATM)?
-- SQL Skills: GROUP BY on multiple columns, window function for within-year percentage
SELECT
    EXTRACT(YEAR FROM transaction_date)::int AS txn_year,
    channel,
    COUNT(*) AS transaction_count,
    ROUND(
        100.0 * COUNT(*) / NULLIF(SUM(COUNT(*)) OVER (PARTITION BY EXTRACT(YEAR FROM transaction_date)), 0),
    2) AS pct_of_year_transactions
FROM banking_transactions
GROUP BY EXTRACT(YEAR FROM transaction_date), channel
ORDER BY txn_year, pct_of_year_transactions DESC;


-- 4. Geographic concentration (Pareto view)
-- Business Question: How concentrated is transaction value across states — do a small number of
-- states account for a disproportionate share of total value?
-- SQL Skills: CTE, window functions for percent-of-total and running cumulative percentage
WITH state_totals AS (
    SELECT state, SUM(transaction_amount) AS total_value
    FROM banking_transactions
    GROUP BY state
)
SELECT
    state,
    total_value,
    ROUND(100.0 * total_value / NULLIF(SUM(total_value) OVER (), 0), 2) AS pct_of_total_value,
    ROUND(
        100.0 * SUM(total_value) OVER (ORDER BY total_value DESC)
        / NULLIF(SUM(total_value) OVER (), 0),
    2) AS cumulative_pct_of_total_value
FROM state_totals
ORDER BY total_value DESC;


-- 5. Customer concentration
-- Business Question: What share of total transaction value comes from the bank's highest-value
-- customers (top 1%, top 1-5%, top 5-10%) versus everyone else?
-- SQL Skills: CTE, PERCENT_RANK window function, CASE-based mutually exclusive segmentation
WITH customer_totals AS (
    SELECT customer_id, SUM(transaction_amount) AS total_value
    FROM banking_transactions
    GROUP BY customer_id
),
ranked AS (
    SELECT
        customer_id,
        total_value,
        PERCENT_RANK() OVER (ORDER BY total_value DESC) AS pctile_rank
    FROM customer_totals
)
SELECT
    CASE
        WHEN pctile_rank <= 0.01 THEN 'Top 1%'
        WHEN pctile_rank <= 0.05 THEN 'Top 1%-5%'
        WHEN pctile_rank <= 0.10 THEN 'Top 5%-10%'
        ELSE 'Remaining 90%'
    END AS customer_segment,
    COUNT(*)                   AS customer_count,
    SUM(total_value)           AS segment_total_value,
    ROUND(100.0 * SUM(total_value) / NULLIF((SELECT SUM(total_value) FROM customer_totals), 0), 2) AS pct_of_bank_total_value
FROM ranked
GROUP BY 1
ORDER BY MIN(pctile_rank);


-- 6. Fraud rate by channel and by transaction type
-- Business Question: How does fraud rate compare across channels and across transaction types,
-- side by side?
-- SQL Skills: UNION ALL to combine two GROUP BY perspectives into one comparable result set,
-- NULLIF-protected rate
SELECT
    'channel' AS dimension, channel AS dimension_value,
    COUNT(*) AS transaction_count,
    COUNT(*) FILTER (WHERE is_fraud = 1) AS fraud_count,
    ROUND(100.0 * COUNT(*) FILTER (WHERE is_fraud = 1) / NULLIF(COUNT(*), 0), 3) AS fraud_rate_pct
FROM banking_transactions
GROUP BY channel
UNION ALL
SELECT
    'transaction_type', transaction_type,
    COUNT(*),
    COUNT(*) FILTER (WHERE is_fraud = 1),
    ROUND(100.0 * COUNT(*) FILTER (WHERE is_fraud = 1) / NULLIF(COUNT(*), 0), 3)
FROM banking_transactions
GROUP BY transaction_type
ORDER BY dimension, fraud_rate_pct DESC;


-- 7. KYC status vs. fraud rate
-- Business Question: Is there a relationship between a customer's KYC status and the likelihood
-- of a transaction being fraudulent?
-- SQL Skills: GROUP BY, NULLIF-protected rate
SELECT
    kyc_status,
    COUNT(*)                             AS transaction_count,
    COUNT(*) FILTER (WHERE is_fraud = 1) AS fraud_count,
    ROUND(100.0 * COUNT(*) FILTER (WHERE is_fraud = 1) / NULLIF(COUNT(*), 0), 3) AS fraud_rate_pct
FROM banking_transactions
GROUP BY kyc_status
ORDER BY fraud_rate_pct DESC;


-- 8. Credit score quintile vs. fraud rate
-- Business Question: Does fraud rate vary meaningfully across the credit score spectrum?
-- SQL Skills: NTILE window function for dynamic quintile banding, GROUP BY, NULLIF-protected rate
-- Note: credit_score's true scale is not documented by the source, so this uses NTILE to build
-- data-driven quintiles instead of assuming a fixed range (e.g., a 300-900 bureau scale).
WITH scored AS (
    SELECT
        credit_score,
        is_fraud,
        NTILE(5) OVER (ORDER BY credit_score) AS credit_quintile
    FROM banking_transactions
    WHERE credit_score IS NOT NULL
)
SELECT
    credit_quintile,
    MIN(credit_score)                    AS min_score_in_quintile,
    MAX(credit_score)                    AS max_score_in_quintile,
    COUNT(*)                             AS transaction_count,
    COUNT(*) FILTER (WHERE is_fraud = 1) AS fraud_count,
    ROUND(100.0 * COUNT(*) FILTER (WHERE is_fraud = 1) / NULLIF(COUNT(*), 0), 3) AS fraud_rate_pct
FROM scored
GROUP BY credit_quintile
ORDER BY credit_quintile;


-- 9. Transaction-hour fraud pattern
-- Business Question: Which hours of the day carry the highest fraud rate?
-- SQL Skills: GROUP BY, NULLIF-protected rate
SELECT
    transaction_hour,
    COUNT(*)                             AS transaction_count,
    COUNT(*) FILTER (WHERE is_fraud = 1) AS fraud_count,
    ROUND(100.0 * COUNT(*) FILTER (WHERE is_fraud = 1) / NULLIF(COUNT(*), 0), 3) AS fraud_rate_pct
FROM banking_transactions
GROUP BY transaction_hour
ORDER BY transaction_hour;


-- 10. Day-of-week volume and fraud pattern
-- Business Question: Which day of the week sees the highest transaction volume and fraud rate?
-- SQL Skills: JOIN to the derived dim_date dimension table, GROUP BY, conditional aggregation
SELECT
    d.day_name,
    COUNT(*)                                    AS transaction_count,
    COUNT(*) FILTER (WHERE t.is_fraud = 1)      AS fraud_count,
    ROUND(100.0 * COUNT(*) FILTER (WHERE t.is_fraud = 1) / NULLIF(COUNT(*), 0), 3) AS fraud_rate_pct
FROM banking_transactions t
JOIN dim_date d ON d.date_key = t.transaction_date
GROUP BY d.day_name, d.day_of_week
ORDER BY d.day_of_week;


-- ============================================================================
-- Screenshot-worthy for GitHub: #4 (geographic Pareto concentration), #5
-- (customer concentration), #8 (credit score vs. fraud), and #9 (hour-of-day
-- fraud pattern) are the four strongest one-glance findings for a recruiter.
-- ============================================================================
