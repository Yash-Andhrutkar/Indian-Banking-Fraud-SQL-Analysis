-- ============================================================================
-- 03_intermediate_analysis.sql
-- Intermediate SQL Analysis
-- ============================================================================
-- GROUP BY, HAVING, subqueries, and conditional aggregation applied to
-- genuine customer, geography, account-type, and channel questions.
-- ============================================================================


-- 1. Monthly transaction volume & value trend
-- Business Question: How has transaction volume and value trended month over month?
-- SQL Skills: GROUP BY, date truncation, aggregate functions
SELECT
    date_trunc('month', transaction_date)::date AS txn_month,
    COUNT(*)                                    AS transaction_count,
    SUM(transaction_amount)                     AS total_value,
    ROUND(AVG(transaction_amount), 2)           AS avg_value
FROM banking_transactions
GROUP BY date_trunc('month', transaction_date)
ORDER BY txn_month;


-- 2. Transaction count & value by account type
-- Business Question: Which account types drive the most transaction volume and value?
-- SQL Skills: GROUP BY, aggregate functions
SELECT
    account_type,
    COUNT(*)                          AS transaction_count,
    SUM(transaction_amount)           AS total_value,
    ROUND(AVG(transaction_amount), 2) AS avg_value
FROM banking_transactions
GROUP BY account_type
ORDER BY total_value DESC;


-- 3. State-wise value ranking (meaningful-volume states only)
-- Business Question: Which states generate the highest transaction value, among states with a
-- meaningful volume of activity?
-- SQL Skills: GROUP BY, HAVING, ORDER BY
SELECT
    state,
    COUNT(*)                AS transaction_count,
    SUM(transaction_amount) AS total_value
FROM banking_transactions
GROUP BY state
HAVING COUNT(*) >= 100   -- Assumption: exclude states with negligible volume from a value ranking
ORDER BY total_value DESC;


-- 4. Channel adoption: volume share and average ticket size
-- Business Question: How is transaction volume distributed across channels, and what's the
-- average ticket size per channel?
-- SQL Skills: GROUP BY combined with a window function for percentage-of-total
SELECT
    channel,
    COUNT(*)                                                                AS transaction_count,
    ROUND(100.0 * COUNT(*) / NULLIF(SUM(COUNT(*)) OVER (), 0), 2)           AS pct_of_total_transactions,
    ROUND(AVG(transaction_amount), 2)                                       AS avg_transaction_amount
FROM banking_transactions
GROUP BY channel
ORDER BY transaction_count DESC;


-- 5. Customers with a fraud history (statistically meaningful sample only)
-- Business Question: Which customers have a meaningful transaction history (10+ transactions)
-- AND at least one transaction flagged as fraud?
-- SQL Skills: GROUP BY, HAVING, conditional aggregation
-- Note: the 10-transaction minimum guards against drawing conclusions from customers with only
-- one or two observed transactions — the same minimum-sample convention used throughout this
-- project wherever a customer's fraud rate is judged (see 05_fraud_audit_challenge.sql).
SELECT
    customer_id,
    COUNT(*)                             AS total_transactions,
    COUNT(*) FILTER (WHERE is_fraud = 1) AS fraud_transactions
FROM banking_transactions
GROUP BY customer_id
HAVING COUNT(*) >= 10 AND COUNT(*) FILTER (WHERE is_fraud = 1) > 0
ORDER BY fraud_transactions DESC, total_transactions DESC;


-- 6. Customer-level transaction profile
-- Business Question: What does a customer-level transaction profile look like (volume, value,
-- average ticket)?
-- SQL Skills: GROUP BY, aggregate functions
SELECT
    customer_id,
    COUNT(*)                          AS total_transactions,
    SUM(transaction_amount)           AS total_spend,
    ROUND(AVG(transaction_amount), 2) AS avg_transaction_amount
FROM banking_transactions
GROUP BY customer_id
ORDER BY total_spend DESC
LIMIT 25;


-- 7. Transaction direction split within each account type
-- Business Question: How does transaction volume split by direction within each account type?
-- SQL Skills: GROUP BY on multiple columns, conditional aggregation
-- Note: transaction_direction category labels are not confirmed. This groups on the actual
-- stored values dynamically rather than assuming specific text such as 'Credit'/'Debit'.
SELECT
    account_type,
    transaction_direction,
    COUNT(*)                AS transaction_count,
    SUM(transaction_amount) AS total_value
FROM banking_transactions
GROUP BY account_type, transaction_direction
ORDER BY account_type, total_value DESC;


-- 8. Above-average transactions by merchant category
-- Business Question: Among transactions larger than the bank-wide average, which merchant
-- categories appear most often?
-- SQL Skills: subquery in WHERE clause, GROUP BY
SELECT
    merchant_category,
    COUNT(*)                          AS above_avg_transaction_count,
    ROUND(AVG(transaction_amount), 2) AS avg_amount_in_category
FROM banking_transactions
WHERE transaction_amount > (SELECT AVG(transaction_amount) FROM banking_transactions)
GROUP BY merchant_category
ORDER BY above_avg_transaction_count DESC;


-- ============================================================================
-- Screenshot-worthy for GitHub: #1 (monthly trend) and #4 (channel adoption)
-- are the most immediately chart-able outputs from this file.
-- ============================================================================
