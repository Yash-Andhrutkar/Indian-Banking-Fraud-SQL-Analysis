-- ============================================================================
-- 00_schema_setup.sql
-- Indian Banking Transaction & Fraud Analytics — Database & Table Setup
-- ============================================================================
-- Purpose: create the database structure exactly as sourced from the Kaggle
-- dataset, load the raw data, and build ONE small derived date dimension
-- table (dim_date) used later purely to demonstrate legitimate JOIN usage.
-- No columns are invented and no raw data is altered anywhere in this file.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- STEP 1: Create the database
-- ----------------------------------------------------------------------------
-- PostgreSQL cannot CREATE DATABASE and then immediately USE it within the
-- same script/transaction, so run this single line on its own first
-- (in psql, or via pgAdmin's "Create > Database..." dialog), then reconnect
-- your session to indian_banking_analysis before running anything below.

-- CREATE DATABASE indian_banking_analysis;


-- ----------------------------------------------------------------------------
-- STEP 2: Create the main transactions table
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS banking_transactions;

CREATE TABLE banking_transactions (
    transaction_id          TEXT PRIMARY KEY,
    customer_id             TEXT NOT NULL,
    transaction_date        DATE,
    transaction_time        TIME,
    account_type            TEXT,
    transaction_type        TEXT,
    transaction_amount      NUMERIC(15,2),
    transaction_direction   TEXT,
    account_balance         NUMERIC(15,2),
    merchant_category       TEXT,
    state                   TEXT,
    credit_score            SMALLINT,
    has_loan                TEXT,
    loan_type               TEXT,
    emi_amount              NUMERIC(15,2),
    transaction_status      TEXT,
    channel                 TEXT,
    kyc_status               TEXT,
    is_fraud                SMALLINT,
    transaction_hour        SMALLINT
);

COMMENT ON TABLE banking_transactions IS
    'Raw Indian banking transaction dataset (Kaggle) — ~550,000 rows, '
    '2019-01-01 to 2024-01-01. Loaded as-is; no columns invented or altered.';

COMMENT ON COLUMN banking_transactions.is_fraud IS
    'Ground-truth fraud label from the source dataset: 1 = fraud, 0 = not fraud.';

COMMENT ON COLUMN banking_transactions.transaction_hour IS
    'Hour of transaction_time as provided in the source data. Cross-checked '
    'for internal consistency against transaction_time in 01_data_quality.sql.';

COMMENT ON COLUMN banking_transactions.credit_score IS
    'Customer credit score at time of transaction. Scale/range is not '
    'documented by the source and is profiled empirically in '
    '01_data_quality.sql rather than assumed (e.g., not assumed to be a '
    'standard 300-900 CIBIL-style scale until confirmed).';

COMMENT ON COLUMN banking_transactions.has_loan IS
    'Loan-holder flag as provided by the source. Exact category text (e.g. '
    'Yes/No) is NOT assumed anywhere downstream — confirm actual values via '
    'the categorical inventory query in 01_data_quality.sql before filtering '
    'on a specific string.';


-- ----------------------------------------------------------------------------
-- STEP 3: Load the data
-- ----------------------------------------------------------------------------
-- Commented example only — update the path and run manually once confirmed.
-- \copy banking_transactions FROM '/path/to/indian_banking_transactions.csv' WITH (FORMAT csv, HEADER true, DELIMITER ',');


-- ----------------------------------------------------------------------------
-- STEP 4: Build dim_date — run this AFTER the data above has been loaded
-- ----------------------------------------------------------------------------
-- This is the one derived dimension table used in this project (see project
-- notes for the rationale). Every column is deterministic calendar
-- arithmetic generated automatically from the loaded data's own date range
-- (MIN(transaction_date) to MAX(transaction_date)) — nothing about
-- customers, branches, or business facts is invented, and no manual
-- population is required.

DROP TABLE IF EXISTS dim_date;

CREATE TABLE dim_date (
    date_key          DATE PRIMARY KEY,
    calendar_year     INT NOT NULL,
    calendar_month    INT NOT NULL,
    month_name        TEXT NOT NULL,
    calendar_quarter  INT NOT NULL,
    day_of_week       INT NOT NULL,   -- 0 = Sunday .. 6 = Saturday (matches EXTRACT(DOW))
    day_name          TEXT NOT NULL,
    is_weekend        BOOLEAN NOT NULL,
    is_month_end      BOOLEAN NOT NULL
);

INSERT INTO dim_date (
    date_key, calendar_year, calendar_month, month_name, calendar_quarter,
    day_of_week, day_name, is_weekend, is_month_end
)
SELECT
    gs::date                                                              AS date_key,
    EXTRACT(YEAR FROM gs)::int                                            AS calendar_year,
    EXTRACT(MONTH FROM gs)::int                                           AS calendar_month,
    TRIM(TO_CHAR(gs, 'Month'))                                            AS month_name,
    EXTRACT(QUARTER FROM gs)::int                                         AS calendar_quarter,
    EXTRACT(DOW FROM gs)::int                                             AS day_of_week,
    TRIM(TO_CHAR(gs, 'Day'))                                              AS day_name,
    EXTRACT(DOW FROM gs) IN (0, 6)                                        AS is_weekend,
    (gs::date = (date_trunc('month', gs) + INTERVAL '1 month - 1 day')::date) AS is_month_end
FROM generate_series(
    (SELECT MIN(transaction_date) FROM banking_transactions),
    (SELECT MAX(transaction_date) FROM banking_transactions),
    INTERVAL '1 day'
) AS gs;

COMMENT ON TABLE dim_date IS
    'Auto-generated calendar dimension spanning MIN to MAX transaction_date '
    'in banking_transactions. Every attribute is deterministic calendar '
    'math — no invented business data — and exists solely to demonstrate '
    'legitimate JOIN usage (weekday/weekend and seasonal analysis) without '
    'fabricating demographics, branches, or other facts absent from the '
    'source dataset.';

-- Screenshot-worthy: none. This file is infrastructure/setup, not an
-- analytical output — nothing here needs to be captured for the portfolio.
