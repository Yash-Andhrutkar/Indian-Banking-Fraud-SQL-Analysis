-- ============================================================================
-- 05_fraud_audit_challenge.sql
-- Advanced Banking Audit & Fraud Screening Analytics
-- ============================================================================
-- ****************************************************************************
-- DISCLAIMER — READ BEFORE INTERPRETING ANYTHING BELOW
--
-- Everything in this file is a PORTFOLIO, RULE-BASED SCREENING MODEL built to
-- demonstrate SQL fraud/audit analytics technique on a Kaggle synthetic
-- dataset. It is NOT a production fraud detection system, has not been
-- validated by any risk, compliance, or audit function, and none of the
-- thresholds below represent actual policy at any real bank. Every threshold
-- and rule weight is an explicit, editable analytical assumption, centralized
-- in fraud_risk_params below — change them freely to explore sensitivity.
-- ****************************************************************************
-- ============================================================================


-- ----------------------------------------------------------------------------
-- SECTION 0: Centralized, editable risk parameters
-- ----------------------------------------------------------------------------
-- Business Question: Where does every threshold and rule weight used in this
-- file live, so the whole model can be re-run with different assumptions by
-- editing one place instead of hunting through ten queries?
-- SQL Skills: parameter table pattern (single source of truth), referenced
-- everywhere below as a "params" CTE over this table.

DROP TABLE IF EXISTS fraud_risk_params;

CREATE TABLE fraud_risk_params AS
SELECT
    530534.67::numeric AS high_value_threshold,       -- Assumption: profiled P99 of transaction_amount — illustrative "high value" cutoff
    100000.00::numeric AS approval_threshold,         -- Assumption: illustrative approval/reporting threshold — NOT a real bank policy figure
    5.0::numeric       AS near_threshold_band_pct,    -- Assumption: "just below approval" = within 5% under approval_threshold
    0::smallint        AS late_night_start_hour,      -- Assumption: late-night window start (24-hour clock)
    4::smallint        AS late_night_end_hour,        -- Assumption: late-night window end, inclusive
    10000::numeric     AS round_sum_modulus,          -- Assumption: amounts evenly divisible by this are "suspiciously round"
    10::int            AS duplicate_window_minutes,   -- Assumption: same customer + same amount within this many minutes = possible duplicate
    30::int            AS velocity_window_minutes,    -- Assumption: rolling window width used for the velocity check (kept in sync manually with the literal interval used in window frames below)
    3::int             AS velocity_min_txn_count,     -- Assumption: this many transactions inside the window = high velocity
    653::int           AS dormancy_gap_days,          -- Assumption: ~6 months of inactivity before a transaction counts as "reactivation"
    10::int            AS min_txn_count_for_profile,  -- Minimum per-customer transaction count before profiling their fraud rate (avoids small-sample distortion)
    3.0::numeric       AS high_fraud_rate_multiplier, -- Assumption: a customer's fraud rate at 3x+ the bank-wide average is flagged as unusual
    1::int AS pts_weekend,
    2::int AS pts_late_night,
    3::int AS pts_high_value,
    1::int AS pts_round_sum,
    2::int AS pts_duplicate,
    2::int AS pts_near_threshold,
    2::int AS pts_dormant_reactivation,
    3::int AS pts_high_velocity,
    3::int AS pts_risky_combo,
    3::int AS risk_low_max,      -- risk_score 0-3  => Low
    7::int AS risk_medium_max;   -- risk_score 4-7  => Medium; 8+ => High

COMMENT ON TABLE fraud_risk_params IS
    'Single source of truth for every threshold and rule weight used in this '
    'file and in vw_fraud_risk_flags (06_views_indexes.sql). Portfolio '
    'assumption values only — not validated policy.';


-- ----------------------------------------------------------------------------
-- SECTION 1: Individual audit controls
-- ----------------------------------------------------------------------------

-- 1. Weekend transactions
-- Business Question: Which transactions occurred on a weekend?
-- SQL Skills: EXTRACT(DOW), WHERE
-- No configurable threshold is needed for this rule — weekend is a fixed calendar fact.
SELECT
    transaction_id, customer_id, transaction_date, transaction_amount,
    EXTRACT(DOW FROM transaction_date) AS day_of_week
FROM banking_transactions
WHERE EXTRACT(DOW FROM transaction_date) IN (0, 6)   -- 0 = Sunday, 6 = Saturday
ORDER BY transaction_date DESC
LIMIT 100;


-- 2. Late-night transactions
-- Business Question: Which transactions occurred during a configurable late-night window?
-- SQL Skills: params CTE, CROSS JOIN, WHERE BETWEEN
WITH params AS (SELECT * FROM fraud_risk_params)
SELECT
    t.transaction_id, t.customer_id, t.transaction_date, t.transaction_time, t.transaction_amount, t.transaction_hour
FROM banking_transactions t
CROSS JOIN params p
WHERE t.transaction_hour BETWEEN p.late_night_start_hour AND p.late_night_end_hour
ORDER BY t.transaction_date DESC
LIMIT 100;


-- 3. High-value transactions
-- Business Question: Which transactions exceed the configurable high-value threshold?
-- SQL Skills: params CTE, CROSS JOIN, WHERE
WITH params AS (SELECT * FROM fraud_risk_params)
SELECT
    t.transaction_id, t.customer_id, t.transaction_date, t.transaction_amount, t.channel
FROM banking_transactions t
CROSS JOIN params p
WHERE t.transaction_amount > p.high_value_threshold
ORDER BY t.transaction_amount DESC;


-- 4. Suspicious round-sum transactions
-- Business Question: Which transactions are suspiciously round amounts (exact multiples of a
-- configurable modulus), a pattern sometimes associated with manually structured transfers?
-- SQL Skills: params CTE, MOD()
WITH params AS (SELECT * FROM fraud_risk_params)
SELECT
    t.transaction_id, t.customer_id, t.transaction_date, t.transaction_amount
FROM banking_transactions t
CROSS JOIN params p
WHERE MOD(t.transaction_amount, p.round_sum_modulus) = 0
ORDER BY t.transaction_amount DESC
LIMIT 100;


-- 5. Potential duplicate transactions
-- Business Question: Which transactions look like potential duplicates — the same customer,
-- same amount, submitted again within a short window?
-- SQL Skills: window function LAG (efficient alternative to a self-join) for prior-transaction
-- comparison, transaction_ts derived consistently as transaction_date + transaction_time
WITH params AS (SELECT * FROM fraud_risk_params),
sequenced AS (
    SELECT
        t.transaction_id,
        t.customer_id,
        t.transaction_amount,
        (t.transaction_date + t.transaction_time) AS transaction_ts,
        LAG(t.transaction_amount) OVER w AS prev_amount,
        LAG(t.transaction_date + t.transaction_time) OVER w AS prev_ts
    FROM banking_transactions t
    WINDOW w AS (PARTITION BY t.customer_id ORDER BY (t.transaction_date + t.transaction_time))
)
SELECT
    s.transaction_id, s.customer_id, s.transaction_ts, s.transaction_amount, s.prev_ts,
    ROUND(EXTRACT(EPOCH FROM (s.transaction_ts - s.prev_ts)) / 60.0, 1) AS minutes_since_prev_same_amount
FROM sequenced s
CROSS JOIN params p
WHERE s.prev_amount = s.transaction_amount
  AND s.prev_ts IS NOT NULL
  AND s.transaction_ts - s.prev_ts <= make_interval(mins => p.duplicate_window_minutes)
ORDER BY s.customer_id, s.transaction_ts;


-- 6. Transactions just below the approval threshold (structuring pattern)
-- Business Question: Which transactions sit just under the configurable approval threshold — a
-- pattern consistent with deliberately staying below a review trigger?
-- SQL Skills: params CTE, WHERE range condition
WITH params AS (SELECT * FROM fraud_risk_params)
SELECT
    t.transaction_id, t.customer_id, t.transaction_date, t.transaction_amount,
    ROUND(p.approval_threshold - t.transaction_amount, 2) AS amount_below_threshold
FROM banking_transactions t
CROSS JOIN params p
WHERE t.transaction_amount < p.approval_threshold
  AND t.transaction_amount >= p.approval_threshold * (1 - p.near_threshold_band_pct / 100.0)
ORDER BY t.transaction_amount DESC;


-- 7. Dormant-customer reactivation
-- Business Question: Which transactions represent a customer suddenly transacting again after a
-- long period of inactivity?
-- SQL Skills: window function LAG for gap detection (efficient alternative to a self-join)
WITH params AS (SELECT * FROM fraud_risk_params),
sequenced AS (
    SELECT
        t.transaction_id,
        t.customer_id,
        t.transaction_amount,
        (t.transaction_date + t.transaction_time) AS transaction_ts,
        LAG(t.transaction_date + t.transaction_time) OVER w AS prev_ts
    FROM banking_transactions t
    WINDOW w AS (PARTITION BY t.customer_id ORDER BY (t.transaction_date + t.transaction_time))
)
SELECT
    s.transaction_id, s.customer_id,
    s.prev_ts AS previous_transaction_ts,
    s.transaction_ts AS reactivation_ts,
    ROUND(EXTRACT(EPOCH FROM (s.transaction_ts - s.prev_ts)) / 86400.0, 1) AS dormant_days,
    s.transaction_amount
FROM sequenced s
CROSS JOIN params p
WHERE s.prev_ts IS NOT NULL
  AND s.transaction_ts - s.prev_ts > make_interval(days => p.dormancy_gap_days)
ORDER BY dormant_days DESC;


-- 8. High transaction velocity
-- Business Question: Which customers show unusually high transaction velocity — several
-- transactions within a short rolling time window?
-- SQL Skills: window function COUNT with a RANGE time-based frame (efficient alternative to a
-- self-join for time-window counting)
-- Note: the window width (30 minutes) mirrors fraud_risk_params.velocity_window_minutes.
-- PostgreSQL window frame bounds must be a simple, non-correlated expression, so the width is
-- kept literal here and in vw_fraud_risk_flags — update both together if the assumption changes.
WITH sequenced AS (
    SELECT
        t.transaction_id,
        t.customer_id,
        t.transaction_amount,
        (t.transaction_date + t.transaction_time) AS transaction_ts
    FROM banking_transactions t
),
velocity AS (
    SELECT
        s.transaction_id, s.customer_id, s.transaction_ts, s.transaction_amount,
        COUNT(*) OVER (
            PARTITION BY s.customer_id
            ORDER BY s.transaction_ts
            RANGE BETWEEN INTERVAL '30 minutes' PRECEDING AND CURRENT ROW
        ) AS txns_in_trailing_30min
    FROM sequenced s
)
SELECT
    v.transaction_id, v.customer_id, v.transaction_ts, v.transaction_amount, v.txns_in_trailing_30min
FROM velocity v
CROSS JOIN (SELECT velocity_min_txn_count FROM fraud_risk_params) p
WHERE v.txns_in_trailing_30min >= p.velocity_min_txn_count
ORDER BY v.customer_id, v.transaction_ts;


-- 9. High-risk combination: high value + late night + non-branch channel
-- Business Question: Which transactions combine multiple independently risky conditions at once
-- (large amount, late hour, and a remote/unattended channel), rather than tripping just one signal?
-- SQL Skills: params CTE, compound WHERE condition
-- Assumption: 'Branch' is the only channel with in-person human oversight among the confirmed
-- channel values (Mobile_App, Web, ATM, POS_Terminal, Branch, API); every other channel is
-- treated as "remote/unattended" for this rule.
WITH params AS (SELECT * FROM fraud_risk_params)
SELECT
    t.transaction_id, t.customer_id, t.transaction_date, t.transaction_hour, t.transaction_amount, t.channel
FROM banking_transactions t
CROSS JOIN params p
WHERE t.transaction_amount > p.high_value_threshold
  AND t.transaction_hour BETWEEN p.late_night_start_hour AND p.late_night_end_hour
  AND t.channel <> 'Branch'
ORDER BY t.transaction_amount DESC;


-- 10. Customers with unusually high fraud incidence
-- Business Question: Which customers, among those with a statistically meaningful transaction
-- count, show a fraud rate far above the bank-wide average?
-- SQL Skills: CTE, cross join against a benchmark, minimum-sample-size guard, NULLIF-protected rate
WITH params AS (SELECT * FROM fraud_risk_params),
overall AS (
    SELECT 100.0 * COUNT(*) FILTER (WHERE is_fraud = 1) / NULLIF(COUNT(*), 0) AS overall_fraud_rate_pct
    FROM banking_transactions
),
customer_fraud AS (
    SELECT
        customer_id,
        COUNT(*)                             AS total_transactions,
        COUNT(*) FILTER (WHERE is_fraud = 1) AS fraud_transactions,
        100.0 * COUNT(*) FILTER (WHERE is_fraud = 1) / NULLIF(COUNT(*), 0) AS customer_fraud_rate_pct
    FROM banking_transactions
    GROUP BY customer_id
)
SELECT
    cf.customer_id,
    cf.total_transactions,
    cf.fraud_transactions,
    ROUND(cf.customer_fraud_rate_pct, 3) AS customer_fraud_rate_pct,
    ROUND(o.overall_fraud_rate_pct, 3)   AS overall_fraud_rate_pct
FROM customer_fraud cf
CROSS JOIN overall o
CROSS JOIN params p
WHERE cf.total_transactions >= p.min_txn_count_for_profile   -- minimum sample size guard
  AND cf.customer_fraud_rate_pct >= o.overall_fraud_rate_pct * p.high_fraud_rate_multiplier
ORDER BY cf.customer_fraud_rate_pct DESC;


-- ----------------------------------------------------------------------------
-- SECTION 2: Combined rule-based risk score
-- ----------------------------------------------------------------------------
-- Business Question: If the transaction-behavior audit signals above are combined into a
-- per-transaction risk score, which transactions surface as Low / Medium / High risk?
-- Historical fraud incidence is excluded from scoring to prevent target leakage.
-- SQL Skills: multi-stage CTEs, named WINDOW clause, window functions (LAG, RANGE-framed COUNT)
-- used instead of self-joins for efficiency on 550K rows, conditional scoring, CASE classification,
-- materialized into a real table so the evaluation queries below don't repeat this computation.

DROP TABLE IF EXISTS fraud_risk_scored;

CREATE TABLE fraud_risk_scored AS
WITH params AS (
    SELECT * FROM fraud_risk_params
),
sequenced AS (
    -- One ordered pass per customer using the true transaction timestamp
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
    -- Efficient trailing-window transaction count per customer (window function, no self-join)
    SELECT
        s.transaction_id,
        COUNT(*) OVER (
            PARTITION BY s.customer_id
            ORDER BY s.transaction_ts
            RANGE BETWEEN INTERVAL '30 minutes' PRECEDING AND CURRENT ROW
        ) AS txns_in_trailing_window
    FROM sequenced s
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

        (s.prev_amount = s.transaction_amount
            AND s.prev_ts IS NOT NULL
            AND s.transaction_ts - s.prev_ts <= make_interval(mins => p.duplicate_window_minutes)) AS flag_duplicate,

        (s.transaction_amount < p.approval_threshold
            AND s.transaction_amount >= p.approval_threshold * (1 - p.near_threshold_band_pct / 100.0)) AS flag_near_threshold,

        (s.prev_ts IS NOT NULL
            AND s.transaction_ts - s.prev_ts > make_interval(days => p.dormancy_gap_days)) AS flag_dormant_reactivation,

        (v.txns_in_trailing_window >= p.velocity_min_txn_count) AS flag_high_velocity,

        (s.transaction_amount > p.high_value_threshold
            AND s.transaction_hour BETWEEN p.late_night_start_hour AND p.late_night_end_hour
            AND s.channel <> 'Branch') AS flag_risky_combo,

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
    flag_near_threshold, flag_dormant_reactivation, flag_high_velocity, flag_risky_combo,risk_score,
    CASE
        WHEN risk_score <= risk_low_max    THEN 'Low'
        WHEN risk_score <= risk_medium_max THEN 'Medium'
        ELSE 'High'
    END AS risk_category
FROM scored;

COMMENT ON TABLE fraud_risk_scored IS
    'Per-transaction rule-based risk score and Low/Medium/High classification, '
    'computed once here for reuse by the evaluation queries below. Portfolio '
    'screening model — see disclaimer at the top of this file.';


-- Risk category distribution
-- Business Question: How many transactions fall into each risk category, and what share of
-- total transaction value do they represent?
-- SQL Skills: aggregate summary over the derived risk model, window function for percent-of-total
SELECT
    risk_category,
    COUNT(*)                                                      AS transaction_count,
    ROUND(100.0 * COUNT(*) / NULLIF(SUM(COUNT(*)) OVER (), 0), 2) AS pct_of_transactions,
    SUM(transaction_amount)                                       AS total_value_in_category
FROM fraud_risk_scored
GROUP BY risk_category
ORDER BY CASE risk_category WHEN 'High' THEN 1 WHEN 'Medium' THEN 2 ELSE 3 END;


-- ----------------------------------------------------------------------------
-- SECTION 3: Evaluation against actual fraud labels
-- ----------------------------------------------------------------------------

-- Confusion matrix and core metrics (operating point: risk_category = 'High')
-- Business Question: How well does the combined risk score line up with the actual is_fraud
-- label, if "flagged for review" means risk_category = 'High'?
-- SQL Skills: conditional aggregation, confusion-matrix construction, precision/recall with
-- NULLIF-protected division
WITH confusion AS (
    SELECT
        COUNT(*) FILTER (WHERE risk_category = 'High' AND is_fraud = 1) AS true_positives,
        COUNT(*) FILTER (WHERE risk_category = 'High' AND is_fraud = 0) AS false_positives,
        COUNT(*) FILTER (WHERE risk_category <> 'High' AND is_fraud = 1) AS false_negatives,
        COUNT(*) FILTER (WHERE risk_category <> 'High' AND is_fraud = 0) AS true_negatives
    FROM fraud_risk_scored
)
SELECT
    true_positives,
    false_positives,
    false_negatives,
    true_negatives,
    (true_positives + false_positives)               AS total_flagged,
    (true_positives + false_negatives)                AS total_actual_fraud,
    ROUND(100.0 * true_positives / NULLIF(true_positives + false_positives, 0), 2) AS precision_pct,
    ROUND(100.0 * true_positives / NULLIF(true_positives + false_negatives, 0), 2) AS recall_fraud_capture_rate_pct,
    ROUND(100.0 * (true_positives + true_negatives)
        / NULLIF(true_positives + false_positives + false_negatives + true_negatives, 0), 2) AS overall_accuracy_pct
FROM confusion;


-- Threshold sensitivity: relaxing the flag to Medium-or-High
-- Business Question: If the review threshold is relaxed to include Medium risk as well as High,
-- how does that change the fraud-capture rate versus precision trade-off?
-- SQL Skills: conditional aggregation, threshold sensitivity analysis
WITH confusion_relaxed AS (
    SELECT
        COUNT(*) FILTER (WHERE risk_category IN ('Medium', 'High') AND is_fraud = 1) AS true_positives,
        COUNT(*) FILTER (WHERE risk_category IN ('Medium', 'High') AND is_fraud = 0) AS false_positives,
        COUNT(*) FILTER (WHERE risk_category = 'Low' AND is_fraud = 1)               AS false_negatives
    FROM fraud_risk_scored
)
SELECT
    true_positives,
    false_positives,
    false_negatives,
    ROUND(100.0 * true_positives / NULLIF(true_positives + false_positives, 0), 2) AS precision_pct,
    ROUND(100.0 * true_positives / NULLIF(true_positives + false_negatives, 0), 2) AS recall_fraud_capture_rate_pct
FROM confusion_relaxed;


-- ****************************************************************************
-- CLOSING DISCLAIMER: The risk score, point weights, and every threshold above
-- are illustrative analytical assumptions built for a SQL portfolio project on
-- a synthetic Kaggle dataset. They are additive and hand-assigned, not derived
-- or validated against labeled data the way a real fraud model's weights
-- would be. Precision/recall figures describe how well this specific
-- hand-built heuristic agrees with this dataset's synthetic fraud label —
-- they are NOT a claim about real-world fraud detection performance, and this
-- file should never be represented as a production model.
-- ****************************************************************************

-- ============================================================================
-- Screenshot-worthy for GitHub: the risk category distribution, the confusion
-- matrix / precision / recall output, and the threshold-sensitivity comparison
-- are the three strongest, most differentiating outputs in the entire project.
-- ============================================================================
