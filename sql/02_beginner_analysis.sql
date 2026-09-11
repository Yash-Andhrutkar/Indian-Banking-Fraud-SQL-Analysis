-- ============================================================================
-- 02_beginner_analysis.sql
-- Beginner SQL Analysis
-- ============================================================================
-- Foundational SQL demonstrated through genuine banking questions rather than
-- textbook examples. Value-band cutoffs below are the dataset's own profiled
-- percentiles (P25/median/P75/P90/P99), not arbitrary round numbers — labeled
-- as analytical assumptions throughout.
-- ============================================================================


-- 1. Most recent transactions
-- Business Question: What do the 20 most recent transactions in the dataset look like?
-- SQL Skills: SELECT, ORDER BY, LIMIT
SELECT
    transaction_id,
    customer_id,
    transaction_date,
    transaction_time,
    transaction_amount,
    transaction_type,
    channel
FROM banking_transactions
ORDER BY transaction_date DESC, transaction_time DESC
LIMIT 20;


-- 2. Distinct account types
-- Business Question: What account types does the bank offer, based on the transaction data?
-- SQL Skills: DISTINCT
SELECT DISTINCT account_type
FROM banking_transactions
ORDER BY account_type;


-- 3. Distinct merchant categories
-- Business Question: Which merchant categories do customers transact with?
-- SQL Skills: DISTINCT
SELECT DISTINCT merchant_category
FROM banking_transactions
ORDER BY merchant_category;


-- 4. Extreme high-value transactions
-- Business Question: Which individual transactions sit in the extreme top 1% by value and
-- would warrant a manual look?
-- SQL Skills: WHERE, ORDER BY, LIMIT
-- Assumption: ₹5,30,534.67 is the empirically profiled 99th percentile of transaction_amount
-- for this dataset, used here purely as an illustrative "high value" cutoff — not a bank policy figure.
SELECT
    transaction_id,
    customer_id,
    transaction_date,
    transaction_amount,
    channel,
    is_fraud
FROM banking_transactions
WHERE transaction_amount > 530534.67
ORDER BY transaction_amount DESC
LIMIT 25;


-- 5. Value-band classification
-- Business Question: How does each transaction classify into a value band based on the bank's
-- actual amount distribution, rather than a generic round-number scale?
-- SQL Skills: CASE expression
-- Assumption: band cutoffs are the profiled P25 (763.04) / Median (2,035.74) / P75 (8,557.50) /
-- P90 (51,277.45) / P99 (530,534.67) of transaction_amount.
SELECT
    transaction_id,
    transaction_amount,
    CASE
        WHEN transaction_amount < 763.04      THEN 'Micro (below P25)'
        WHEN transaction_amount < 2035.74     THEN 'Small (P25-Median)'
        WHEN transaction_amount < 8557.50     THEN 'Medium (Median-P75)'
        WHEN transaction_amount < 51277.45    THEN 'Large (P75-P90)'
        WHEN transaction_amount < 530534.67   THEN 'Very Large (P90-P99)'
        ELSE 'Extreme (top 1%)'
    END AS value_band
FROM banking_transactions
ORDER BY transaction_amount DESC
LIMIT 50;


-- 6. Bank-wide summary statistics
-- Business Question: What do the bank's overall transaction volumes and values look like at a glance?
-- SQL Skills: basic aggregates (COUNT, SUM, AVG, MIN, MAX)
-- Note: with a mean of ~₹29,907 against a median of ~₹2,036, this distribution is strongly
-- right-skewed — see 07_business_findings.sql for percentile-based views that don't rely on the mean alone.
SELECT
    COUNT(*)                            AS total_transactions,
    SUM(transaction_amount)             AS total_value,
    ROUND(AVG(transaction_amount), 2)   AS avg_transaction_amount,
    MIN(transaction_amount)             AS min_transaction_amount,
    MAX(transaction_amount)             AS max_transaction_amount
FROM banking_transactions;


-- 7. Transactions with a non-standard status
-- Business Question: Which transactions have a status other than the bank's most common outcome?
-- SQL Skills: WHERE, subquery
-- Note: transaction_status category labels (which value means "success" vs "failed", etc.) are not
-- confirmed. This stays dynamic by comparing against the most frequent status rather than
-- hardcoding a label — confirm the actual status values via 01_data_quality.sql if a specific
-- outcome (e.g. "failed") needs to be isolated.
SELECT
    transaction_id,
    customer_id,
    transaction_date,
    transaction_status,
    transaction_amount
FROM banking_transactions
WHERE transaction_status <> (
    SELECT transaction_status
    FROM banking_transactions
    GROUP BY transaction_status
    ORDER BY COUNT(*) DESC
    LIMIT 1
)
ORDER BY transaction_date DESC
LIMIT 25;


-- 8. Fraud count and share of total
-- Business Question: How many transactions are flagged as fraud, and what share of total volume do they represent?
-- SQL Skills: conditional aggregation (FILTER), NULLIF-protected division
SELECT
    COUNT(*) FILTER (WHERE is_fraud = 1) AS fraud_transactions,
    COUNT(*)                             AS total_transactions,
    ROUND(100.0 * COUNT(*) FILTER (WHERE is_fraud = 1) / NULLIF(COUNT(*), 0), 3) AS fraud_pct
FROM banking_transactions;


-- ============================================================================
-- Screenshot-worthy for GitHub: #5 (value-band classification — shows
-- distribution awareness) and #8 (fraud share) are the most recruiter-legible
-- outputs from this file.
-- ============================================================================
