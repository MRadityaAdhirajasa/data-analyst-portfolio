-- =====================================================================
-- 01 - Staging: cast, clean, derive.
-- Target: PostgreSQL 16. Idempotent: safe to re-run.
-- Prerequisite: ingest/load.py has filled staging.raw_*
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS staging;


-- ---------------------------------------------------------------------
-- 1. Transactions
--
--    amount arrives as '$-77.00'  -> strip the sign-prefixed dollar mark
--    zip    arrives as '58523.0'  -> numeric first, then integer
--    errors arrives comma-joined  -> array, exploded into a bridge later
--
--    is_online follows use_chip, NOT merchant_city. 1,563,700 rows carry
--    merchant_city = 'ONLINE' but only 1,557,912 are tagged
--    'Online Transaction'; the 5,788-row gap is source noise. use_chip is
--    what the authorisation channel actually was, so it wins. The
--    disagreement is counted in the quality block at the bottom.
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS staging.stg_transactions;
CREATE TABLE staging.stg_transactions AS
SELECT
    t.id::BIGINT                                    AS transaction_id,
    t.date::TIMESTAMP                               AS transacted_at,
    t.date::DATE                                    AS transaction_date,
    EXTRACT(HOUR FROM t.date::TIMESTAMP)::SMALLINT  AS hour_of_day,
    t.client_id::INTEGER                            AS client_id,
    t.card_id::INTEGER                              AS card_id,
    REPLACE(t.amount, '$', '')::NUMERIC(12,2)       AS amount,
    t.use_chip                                      AS channel,
    t.merchant_id::INTEGER                          AS merchant_id,
    t.merchant_city,
    t.merchant_state,
    t.zip::NUMERIC::INTEGER                          AS zip,
    t.mcc::INTEGER                                  AS mcc,
    STRING_TO_ARRAY(t.errors, ',')                  AS error_list,
    (t.errors IS NOT NULL)                          AS is_failed,
    (t.use_chip = 'Online Transaction')             AS is_online,
    (f.is_fraud IS NOT NULL)                        AS has_fraud_label,
    (f.is_fraud = 'Yes')                            AS is_fraud
FROM staging.raw_transactions t
LEFT JOIN staging.raw_fraud_labels f
       ON f.transaction_id::BIGINT = t.id::BIGINT;

ALTER TABLE staging.stg_transactions ADD PRIMARY KEY (transaction_id);
CREATE INDEX ON staging.stg_transactions (transaction_date);
CREATE INDEX ON staging.stg_transactions (card_id);


-- ---------------------------------------------------------------------
-- 2. Clients
--    Income and debt arrive as '$29278'. debt_to_income is the standard
--    lending ratio; yearly_income is never 0 in this source but NULLIF
--    keeps the division honest if that ever changes.
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS staging.stg_clients;
CREATE TABLE staging.stg_clients AS
SELECT
    id::INTEGER                                     AS client_id,
    current_age::SMALLINT                           AS current_age,
    retirement_age::SMALLINT                        AS retirement_age,
    gender,
    latitude::NUMERIC(9,4)                          AS latitude,
    longitude::NUMERIC(9,4)                         AS longitude,
    REPLACE(per_capita_income, '$', '')::INTEGER    AS per_capita_income,
    REPLACE(yearly_income, '$', '')::INTEGER        AS yearly_income,
    REPLACE(total_debt, '$', '')::INTEGER           AS total_debt,
    credit_score::SMALLINT                          AS credit_score,
    num_credit_cards::SMALLINT                      AS num_credit_cards,
    ROUND(
        REPLACE(total_debt, '$', '')::NUMERIC
        / NULLIF(REPLACE(yearly_income, '$', '')::NUMERIC, 0), 3
    )                                               AS debt_to_income
FROM staging.raw_users;

ALTER TABLE staging.stg_clients ADD PRIMARY KEY (client_id);


-- ---------------------------------------------------------------------
-- 3. Cards
--    'expires' and 'acct_open_date' are MM/YYYY -> first of that month.
--    card_on_dark_web is 'No' for all 6,146 rows, so it is dropped here
--    rather than carried into the model as a constant column.
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS staging.stg_cards;
CREATE TABLE staging.stg_cards AS
SELECT
    id::INTEGER                                     AS card_id,
    client_id::INTEGER                              AS client_id,
    card_brand,
    card_type,
    TO_DATE(expires, 'MM/YYYY')                     AS expires_on,
    TO_DATE(acct_open_date, 'MM/YYYY')              AS account_opened_on,
    (has_chip = 'YES')                              AS has_chip,
    num_cards_issued::SMALLINT                      AS num_cards_issued,
    REPLACE(credit_limit, '$', '')::INTEGER         AS credit_limit
FROM staging.raw_cards;

ALTER TABLE staging.stg_cards ADD PRIMARY KEY (card_id);


-- ---------------------------------------------------------------------
-- 4. Quality checks - every column below must return 0.
--    The last one is informational: it is the 5,788-row use_chip vs
--    merchant_city disagreement documented in section 1, kept visible so
--    it is never mistaken for a regression.
-- ---------------------------------------------------------------------
SELECT
    COUNT(*) FILTER (WHERE transacted_at IS NULL)               AS null_dates,
    COUNT(*) FILTER (WHERE amount IS NULL)                      AS null_amounts,
    COUNT(*) FILTER (WHERE t.mcc IS NULL)                       AS null_mcc,
    COUNT(*) FILTER (WHERE c.card_id IS NULL)                   AS orphan_cards,
    COUNT(*) FILTER (WHERE u.client_id IS NULL)                 AS orphan_clients,
    COUNT(*) FILTER (WHERE m.mcc IS NULL)                       AS unknown_mcc,
    COUNT(*) FILTER (WHERE t.is_failed AND t.error_list IS NULL) AS failed_without_error
FROM staging.stg_transactions t
LEFT JOIN staging.stg_cards   c ON c.card_id   = t.card_id
LEFT JOIN staging.stg_clients u ON u.client_id = t.client_id
LEFT JOIN staging.raw_mcc     m ON m.mcc::INTEGER = t.mcc;

SELECT COUNT(*) AS informational_channel_disagreement
FROM staging.stg_transactions
WHERE is_online <> (merchant_city = 'ONLINE');
