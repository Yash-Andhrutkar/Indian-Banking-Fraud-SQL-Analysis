-- ============================================================================
-- 06_views_indexes.sql
-- Reusable Views & Indexing Strategy
-- ============================================================================
-- NOTE: vw_fraud_risk_flags depends on fraud_risk_params, which is created by
-- 05_fraud_audit_challenge.sql — run that file at least once before this one.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- VIEW 1: vw_customer_transaction_summary
-- ----------------------------------------------------------------------------
-- Business Question: What does each customer's transaction relationship with
-- the bank look like, summarized once for reuse instead of re-aggregating
-- from the raw table in every report?
-- SQL Skills: VIEW encapsulation of a GROUP BY aggregation, conditional
-- aggregation, NULLIF-protected rate
CREATE OR REPLACE VIEW vw_customer_transaction_summary AS
SELECT
    customer_id,
    COUNT(*)                                                                       AS total_transactions,
    SUM(transaction_amount)                                                        AS total_value,
    ROUND(AVG(transaction_amount), 2)                                              AS avg_transaction_amount,
    COUNT(*) FILTER (WHERE is_fraud = 1)                                           AS fraud_transaction_count,
    ROUND(100.0 * COUNT(*) FILTER (WHERE is_fraud = 1) / NULLIF(COUNT(*), 0), 3)   AS fraud_rate_pct,
    MIN(transaction_date + transaction_time)                                      AS first_transaction_ts,
    MAX(transaction_date + transaction_time)                                      AS last_transaction_ts
FROM banking_transactions
GROUP BY customer_id;

COMMENT ON VIEW vw_customer_transaction_summary IS
    'Per-customer rollup reused across intermediate, advanced, and '
    'business-findings analysis so the same aggregation is not rewritten '
    'repeatedly. This is a plain (non-materialized) view: it always reflects '
    'the current contents of banking_transactions.';


-- ----------------------------------------------------------------------------
-- VIEW 2: vw_fraud_risk_flags
-- ----------------------------------------------------------------------------
-- Business Question: Reusable exposure of the rule-based risk score and
-- Low/Medium/High classification developed in 05_fraud_audit_challenge.sql,
-- so downstream reporting doesn't need to re-derive it from scratch.
-- SQL Skills: VIEW encapsulation of a multi-stage CTE with window functions
-- (LAG, RANGE-framed COUNT) used instead of self-joins for efficiency
--
-- This is a standard (non-materialized) VIEW — it recomputes from
-- banking_transactions and fraud_risk_params every time it is queried, so it
-- always reflects the latest data and the latest parameter values. A
-- materialized view was deliberately NOT used: at 550K rows the live
-- computation is inexpensive, and a materialized view would silently go
-- stale if fraud_risk_params or the underlying data changed without a
-- manual REFRESH — a real risk in a portfolio project meant to be re-run
-- with different assumptions.
CREATE OR REPLACE VIEW vw_fraud_risk_flags AS
WITH params AS (
    SELECT * FROM fraud_risk_params
),
sequenced AS (
    SELECT
        t.transaction_id,
        t.customer_id,
        t.transaction_date,
        t.transaction_amount,
        t.transaction_hour,
        t.channel,
        t.is_fraud,
        (t.transaction_date + t.transaction_time) AS transaction_ts,
        LAG(t.transaction_amount) OVER w AS prev_amount,
        LAG(t.transaction_date + t.transaction_time) OVER w AS prev_ts
    FROM banking_transactions t
    WINDOW w AS (PARTITION BY t.customer_id ORDER BY (t.transaction_date + t.transaction_time))
),
velocity AS (
    SELECT
        s.transaction_id,
        COUNT(*) OVER (
            PARTITION BY s.customer_id
            ORDER BY s.transaction_ts
            RANGE BETWEEN INTERVAL '30 minutes' PRECEDING AND CURRENT ROW
        ) AS txns_in_trailing_window
    FROM sequenced s
),
customer_profile AS (
    SELECT
        customer_id,
        COUNT(*) AS customer_txn_count,
        100.0 * COUNT(*) FILTER (WHERE is_fraud = 1) / NULLIF(COUNT(*), 0) AS customer_fraud_rate_pct
    FROM banking_transactions
    GROUP BY customer_id
),
overall AS (
    SELECT 100.0 * COUNT(*) FILTER (WHERE is_fraud = 1) / NULLIF(COUNT(*), 0) AS overall_fraud_rate_pct
    FROM banking_transactions
),
flags AS (
    SELECT
        s.transaction_id,
        s.customer_id,
        s.transaction_date,
        s.transaction_amount,
        s.is_fraud,
        (EXTRACT(DOW FROM s.transaction_date) IN (0, 6)) AS flag_weekend,
        (s.transaction_hour BETWEEN p.late_night_start_hour AND p.late_night_end_hour) AS flag_late_night,
        (s.transaction_amount > p.high_value_threshold) AS flag_high_value,
        (MOD(s.transaction_amount, p.round_sum_modulus) = 0) AS flag_round_sum,
        (s.prev_amount = s.transaction_amount AND s.prev_ts IS NOT NULL
            AND s.transaction_ts - s.prev_ts <= make_interval(mins => p.duplicate_window_minutes)) AS flag_duplicate,
        (s.transaction_amount < p.approval_threshold
            AND s.transaction_amount >= p.approval_threshold * (1 - p.near_threshold_band_pct / 100.0)) AS flag_near_threshold,
        (s.prev_ts IS NOT NULL AND s.transaction_ts - s.prev_ts > make_interval(days => p.dormancy_gap_days)) AS flag_dormant_reactivation,
        (v.txns_in_trailing_window >= p.velocity_min_txn_count) AS flag_high_velocity,
        (s.transaction_amount > p.high_value_threshold
            AND s.transaction_hour BETWEEN p.late_night_start_hour AND p.late_night_end_hour
            AND s.channel <> 'Branch') AS flag_risky_combo,
        (cp.customer_txn_count >= p.min_txn_count_for_profile
            AND cp.customer_fraud_rate_pct >= o.overall_fraud_rate_pct * p.high_fraud_rate_multiplier) AS flag_customer_history,
        p.pts_weekend, p.pts_late_night, p.pts_high_value, p.pts_round_sum, p.pts_duplicate,
        p.pts_near_threshold, p.pts_dormant_reactivation, p.pts_high_velocity, p.pts_risky_combo, p.risk_low_max, p.risk_medium_max
    FROM sequenced s
    CROSS JOIN params p
    JOIN velocity v ON v.transaction_id = s.transaction_id
    JOIN customer_profile cp ON cp.customer_id = s.customer_id
    CROSS JOIN overall o
),
scored AS (
    SELECT
        f.*,
        (
            (flag_weekend::int * pts_weekend) + (flag_late_night::int * pts_late_night) +
            (flag_high_value::int * pts_high_value) + (flag_round_sum::int * pts_round_sum) +
            (flag_duplicate::int * pts_duplicate) + (flag_near_threshold::int * pts_near_threshold) +
            (flag_dormant_reactivation::int * pts_dormant_reactivation) + (flag_high_velocity::int * pts_high_velocity) +
            (flag_risky_combo::int * pts_risky_combo) 
        ) AS risk_score
    FROM flags f
)
SELECT
    transaction_id, customer_id, transaction_date, transaction_amount, is_fraud,
    flag_weekend, flag_late_night, flag_high_value, flag_round_sum, flag_duplicate,
    flag_near_threshold, flag_dormant_reactivation, flag_high_velocity, flag_risky_combo, flag_customer_history,
    risk_score,
    CASE
        WHEN risk_score <= risk_low_max    THEN 'Low'
        WHEN risk_score <= risk_medium_max THEN 'Medium'
        ELSE 'High'
    END AS risk_category
FROM scored;

COMMENT ON VIEW vw_fraud_risk_flags IS
    'Live, non-materialized reproduction of the rule-based risk scoring model '
    'from 05_fraud_audit_challenge.sql. Portfolio screening model — not a '
    'production fraud system. Requires fraud_risk_params to exist.';


-- ----------------------------------------------------------------------------
-- INDEXES
-- ----------------------------------------------------------------------------
-- Indexing philosophy: only add an index where a specific, repeated query
-- pattern in THIS project benefits from it. Every index adds write overhead
-- and storage, so low-value indexes are deliberately skipped (see below).

-- Supports: per-customer lookups and joins used throughout 03/04/05/06/07
-- (customer aggregation, customer-level fraud rate, ranking within customer,
-- the customer_profile join inside vw_fraud_risk_flags).
CREATE INDEX IF NOT EXISTS idx_banking_transactions_customer_id
    ON banking_transactions (customer_id);

-- Supports: every date-range and time-trend query (monthly/annual growth,
-- dim_date joins) — lets Postgres avoid a full scan when filtering or
-- aggregating by transaction_date.
CREATE INDEX IF NOT EXISTS idx_banking_transactions_transaction_date
    ON banking_transactions (transaction_date);

-- Supports: sequence-based fraud logic (duplicate detection, velocity,
-- dormancy/reactivation, customer transaction ordering in 04 and 05) — these
-- all partition by customer_id and order by the transaction timestamp, so a
-- composite index matching that access pattern avoids a separate sort step
-- for large per-customer window functions.
CREATE INDEX IF NOT EXISTS idx_banking_transactions_customer_date
    ON banking_transactions (customer_id, transaction_date, transaction_time);

-- Supports: every fraud-focused query in 03/04/05/07. Fraud is ~0.9% of rows,
-- so a PARTIAL index (only rows where is_fraud = 1) is far smaller and
-- cheaper to maintain than indexing the full column, while still making
-- "find the fraud rows fast" queries efficient.
CREATE INDEX IF NOT EXISTS idx_banking_transactions_is_fraud_true
    ON banking_transactions (customer_id)
    WHERE is_fraud = 1;

-- Deliberately NOT indexed: account_type, channel, kyc_status,
-- transaction_status, state, merchant_category. These are all low-cardinality
-- categorical columns (a handful of distinct values spread across 550K rows),
-- so a b-tree index over any one of them has poor selectivity — the query
-- planner will usually prefer a sequential scan anyway, and the index would
-- just add write overhead and storage with no matching read-time benefit.
-- Indexing every column "because we can" is the opposite of good indexing
-- judgment, so these are intentionally skipped.

-- ============================================================================
-- Screenshot-worthy for GitHub: the CREATE VIEW statements themselves (shows
-- the ability to encapsulate a complex model into a reusable object) and the
-- index list with its accompanying rationale comments (shows indexing
-- judgment, not just syntax).
-- ============================================================================
