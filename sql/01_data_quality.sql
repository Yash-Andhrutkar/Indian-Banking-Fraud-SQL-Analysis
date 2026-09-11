-- ============================================================================
-- 01_data_quality.sql
-- Data Validation & Profiling
-- ============================================================================
-- Purpose: confirm the dataset matches its documented shape before any
-- analysis is trusted, and surface exactly which categorical values exist
-- in unconfirmed columns (transaction_status, transaction_direction,
-- has_loan, loan_type) so later files never have to guess at label text.
-- ============================================================================


-- 1. Row count
-- Business Question: Does the loaded table match the documented dataset size (~550,000 rows)?
-- SQL Skills: COUNT(*)
SELECT COUNT(*) AS total_row_count
FROM banking_transactions;


-- 2. Unique transaction_id count (primary key sanity check)
-- Business Question: Is every transaction_id truly unique, as the primary key requires?
-- SQL Skills: COUNT DISTINCT
SELECT
    COUNT(*)                       AS total_rows,
    COUNT(DISTINCT transaction_id) AS unique_transaction_ids
FROM banking_transactions;


-- 3. Duplicate transaction_id check (defensive — should return zero rows)
-- Business Question: Are there any duplicate transaction IDs that would break per-transaction integrity?
-- SQL Skills: GROUP BY, HAVING
SELECT
    transaction_id,
    COUNT(*) AS occurrences
FROM banking_transactions
GROUP BY transaction_id
HAVING COUNT(*) > 1;


-- 4. Unique customer count
-- Business Question: Does the customer base match the documented ~79,916 unique customers?
-- SQL Skills: COUNT DISTINCT
SELECT COUNT(DISTINCT customer_id) AS unique_customers
FROM banking_transactions;


-- 5. Null audit across every column
-- Business Question: Which columns have missing data, and how much?
-- SQL Skills: UNION ALL, conditional aggregation (FILTER)
SELECT 'transaction_id'       AS column_name, COUNT(*) FILTER (WHERE transaction_id       IS NULL) AS null_count FROM banking_transactions
UNION ALL
SELECT 'customer_id',                COUNT(*) FILTER (WHERE customer_id                 IS NULL) FROM banking_transactions
UNION ALL
SELECT 'transaction_date',           COUNT(*) FILTER (WHERE transaction_date            IS NULL) FROM banking_transactions
UNION ALL
SELECT 'transaction_time',           COUNT(*) FILTER (WHERE transaction_time            IS NULL) FROM banking_transactions
UNION ALL
SELECT 'account_type',               COUNT(*) FILTER (WHERE account_type                IS NULL) FROM banking_transactions
UNION ALL
SELECT 'transaction_type',           COUNT(*) FILTER (WHERE transaction_type            IS NULL) FROM banking_transactions
UNION ALL
SELECT 'transaction_amount',         COUNT(*) FILTER (WHERE transaction_amount          IS NULL) FROM banking_transactions
UNION ALL
SELECT 'transaction_direction',      COUNT(*) FILTER (WHERE transaction_direction       IS NULL) FROM banking_transactions
UNION ALL
SELECT 'account_balance',            COUNT(*) FILTER (WHERE account_balance             IS NULL) FROM banking_transactions
UNION ALL
SELECT 'merchant_category',          COUNT(*) FILTER (WHERE merchant_category           IS NULL) FROM banking_transactions
UNION ALL
SELECT 'state',                      COUNT(*) FILTER (WHERE state                       IS NULL) FROM banking_transactions
UNION ALL
SELECT 'credit_score',               COUNT(*) FILTER (WHERE credit_score                IS NULL) FROM banking_transactions
UNION ALL
SELECT 'has_loan',                   COUNT(*) FILTER (WHERE has_loan                    IS NULL) FROM banking_transactions
UNION ALL
SELECT 'loan_type',                  COUNT(*) FILTER (WHERE loan_type                   IS NULL) FROM banking_transactions
UNION ALL
SELECT 'emi_amount',                 COUNT(*) FILTER (WHERE emi_amount                  IS NULL) FROM banking_transactions
UNION ALL
SELECT 'transaction_status',         COUNT(*) FILTER (WHERE transaction_status          IS NULL) FROM banking_transactions
UNION ALL
SELECT 'channel',                    COUNT(*) FILTER (WHERE channel                     IS NULL) FROM banking_transactions
UNION ALL
SELECT 'kyc_status',                 COUNT(*) FILTER (WHERE kyc_status                  IS NULL) FROM banking_transactions
UNION ALL
SELECT 'is_fraud',                   COUNT(*) FILTER (WHERE is_fraud                    IS NULL) FROM banking_transactions
UNION ALL
SELECT 'transaction_hour',           COUNT(*) FILTER (WHERE transaction_hour            IS NULL) FROM banking_transactions
ORDER BY null_count DESC;


-- 6. Date range check
-- Business Question: Does the data cover the documented 2019-01-01 to 2024-01-01 window, with no stray out-of-range dates?
-- SQL Skills: MIN, MAX
SELECT
    MIN(transaction_date) AS earliest_transaction_date,
    MAX(transaction_date) AS latest_transaction_date
FROM banking_transactions;


-- 7. Negative or zero transaction amounts
-- Business Question: Are there any transactions with an invalid (zero or negative) amount?
-- SQL Skills: WHERE, aggregate
SELECT COUNT(*) AS non_positive_amount_count
FROM banking_transactions
WHERE transaction_amount <= 0;


-- 8. Negative account balances, segmented by account type
-- Business Question: Do any account types show negative balances that don't make business sense
-- (a Current account can legitimately run negative via overdraft; Savings/Salary/FD generally should not)?
-- SQL Skills: GROUP BY, conditional aggregation
SELECT
    account_type,
    COUNT(*) FILTER (WHERE account_balance < 0) AS negative_balance_count,
    MIN(account_balance)                        AS min_balance_seen
FROM banking_transactions
GROUP BY account_type
ORDER BY negative_balance_count DESC;


-- 9. Credit score profile (range check without assuming a fixed scale)
-- Business Question: What is the actual observed range of credit_score, and are there any clearly
-- out-of-bounds values (e.g., negative, or above a generous upper bound of 900)?
-- SQL Skills: MIN, MAX, conditional aggregation
-- Note: the true scale/range of this column is not documented by the source, so this profiles it
-- empirically rather than assuming a standard bureau scale.
SELECT
    MIN(credit_score) AS min_credit_score,
    MAX(credit_score) AS max_credit_score,
    COUNT(*) FILTER (WHERE credit_score < 0 OR credit_score > 900) AS out_of_plausible_range_count
FROM banking_transactions;


-- 10. transaction_hour vs transaction_time consistency
-- Business Question: Does the stored transaction_hour column always match the hour embedded in transaction_time?
-- SQL Skills: EXTRACT, WHERE, type casting
SELECT COUNT(*) AS mismatched_hour_rows
FROM banking_transactions
WHERE transaction_hour IS NOT NULL
  AND transaction_time IS NOT NULL
  AND transaction_hour <> EXTRACT(HOUR FROM transaction_time)::smallint;


-- 11. Categorical value inventory
-- Business Question: What are the actual distinct values (and their frequencies) in every
-- categorical column — including the ones this project has NOT been given a confirmed value
-- list for (transaction_status, transaction_direction, has_loan, loan_type)?
-- SQL Skills: UNION ALL across multiple GROUP BY perspectives
-- IMPORTANT: confirm the values returned here before ever hardcoding a specific category string
-- in 02-07. Any value not already confirmed in the project brief (account_type, channel,
-- kyc_status = 'Verified') should be treated as unverified until seen in this output.
SELECT 'account_type' AS column_name, account_type AS value, COUNT(*) AS row_count FROM banking_transactions GROUP BY account_type
UNION ALL
SELECT 'transaction_type', transaction_type, COUNT(*) FROM banking_transactions GROUP BY transaction_type
UNION ALL
SELECT 'transaction_direction', transaction_direction, COUNT(*) FROM banking_transactions GROUP BY transaction_direction
UNION ALL
SELECT 'channel', channel, COUNT(*) FROM banking_transactions GROUP BY channel
UNION ALL
SELECT 'kyc_status', kyc_status, COUNT(*) FROM banking_transactions GROUP BY kyc_status
UNION ALL
SELECT 'transaction_status', transaction_status, COUNT(*) FROM banking_transactions GROUP BY transaction_status
UNION ALL
SELECT 'merchant_category', merchant_category, COUNT(*) FROM banking_transactions GROUP BY merchant_category
UNION ALL
SELECT 'loan_type', loan_type, COUNT(*) FROM banking_transactions GROUP BY loan_type
UNION ALL
SELECT 'has_loan', has_loan, COUNT(*) FROM banking_transactions GROUP BY has_loan
UNION ALL
SELECT 'state', state, COUNT(*) FROM banking_transactions GROUP BY state
ORDER BY column_name, row_count DESC;


-- 12. Fraud distribution
-- Business Question: How many transactions are flagged as fraud, and does the count/percentage match the documented 4,873?
-- SQL Skills: conditional aggregation, NULLIF-protected percentage
SELECT
    COUNT(*) FILTER (WHERE is_fraud = 1) AS fraud_transactions,
    COUNT(*)                             AS total_transactions,
    ROUND(100.0 * COUNT(*) FILTER (WHERE is_fraud = 1) / NULLIF(COUNT(*), 0), 3) AS fraud_pct
FROM banking_transactions;


-- 13. Transaction status distribution
-- Business Question: What share of transactions falls into each transaction_status value?
-- SQL Skills: GROUP BY, NULLIF-protected percentage
SELECT
    transaction_status,
    COUNT(*) AS transaction_count,
    ROUND(100.0 * COUNT(*) / NULLIF(SUM(COUNT(*)) OVER (), 0), 2) AS pct_of_total
FROM banking_transactions
GROUP BY transaction_status
ORDER BY transaction_count DESC;


-- 14. KYC status distribution
-- Business Question: What share of transactions comes from customers in each KYC status?
-- SQL Skills: GROUP BY, NULLIF-protected percentage
SELECT
    kyc_status,
    COUNT(*) AS transaction_count,
    ROUND(100.0 * COUNT(*) / NULLIF(SUM(COUNT(*)) OVER (), 0), 2) AS pct_of_total
FROM banking_transactions
GROUP BY kyc_status
ORDER BY transaction_count DESC;


-- 15. Loan-field internal consistency
-- Business Question: Are loan_type and emi_amount populated consistently with each other,
-- regardless of exactly how has_loan is spelled in this dataset?
-- SQL Skills: conditional aggregation
SELECT
    COUNT(*) FILTER (WHERE loan_type IS NOT NULL AND emi_amount IS NULL)                     AS loan_type_without_emi,
    COUNT(*) FILTER (WHERE loan_type IS NULL     AND emi_amount IS NOT NULL)                 AS emi_without_loan_type,
    COUNT(*) FILTER (WHERE has_loan IS NOT NULL AND loan_type IS NULL AND emi_amount IS NULL) AS has_loan_value_without_loan_details
FROM banking_transactions;


-- ============================================================================
-- Screenshot-worthy for GitHub: #1/#4 (row & customer counts matching the
-- documented dataset size), #5 (null audit), #6 (date range), #11 (categorical
-- inventory — shows rigor in not assuming unverified categories), and #12
-- (fraud distribution). These are the clearest "this analyst validates before
-- analyzing" evidence for a recruiter.
-- ============================================================================
