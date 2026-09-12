-- =====================================================================
-- 02 - Warehouse: star schema + the BI-facing views.
-- Target: PostgreSQL 16. Idempotent: safe to re-run.
-- Prerequisite: sql/01_staging.sql
--
-- Surrogate keys are minted only where the source has no clean key of its
-- own (dates, channels, error types). client_id, card_id, merchant_id and
-- mcc are already stable integers -- wrapping them in a second integer
-- would add a join without adding meaning.
-- =====================================================================

-- Both schemas hold nothing but what this file creates, so both are
-- rebuilt whole rather than table by table.
--
-- This replaces a hand-maintained list of nine DROP TABLE statements,
-- which drifted the moment dim_merchant was replaced by dim_location:
-- the list still named the old table, nothing dropped the new one, and
-- the script failed on its second run while leaving the bi views
-- already dropped. A list that has to be kept in step with the tables
-- below it will go stale again; dropping the schema cannot.
DROP SCHEMA IF EXISTS bi CASCADE;
DROP SCHEMA IF EXISTS dw CASCADE;
CREATE SCHEMA dw;
CREATE SCHEMA bi;


-- ---------------------------------------------------------------------
-- dim_date
--    Generated, not harvested from the fact table. A date dimension
--    assembled with SELECT DISTINCT silently omits days with no
--    transactions, which breaks every rolling and period-over-period
--    calculation that walks the calendar.
-- ---------------------------------------------------------------------
CREATE TABLE dw.dim_date (
    date_key        INTEGER PRIMARY KEY,
    full_date       DATE NOT NULL UNIQUE,
    day_of_month    SMALLINT,
    day_name        VARCHAR(10),
    day_of_week     SMALLINT,
    is_weekend      BOOLEAN,
    month           SMALLINT,
    month_name      VARCHAR(10),
    month_start     DATE,
    quarter         SMALLINT,
    year            SMALLINT
);

INSERT INTO dw.dim_date
SELECT
    TO_CHAR(d, 'YYYYMMDD')::INTEGER,
    d::DATE,
    EXTRACT(DAY FROM d),
    TRIM(TO_CHAR(d, 'Day')),
    EXTRACT(ISODOW FROM d),
    EXTRACT(ISODOW FROM d) >= 6,
    EXTRACT(MONTH FROM d),
    TRIM(TO_CHAR(d, 'Month')),
    DATE_TRUNC('month', d)::DATE,
    EXTRACT(QUARTER FROM d),
    EXTRACT(YEAR FROM d)
FROM GENERATE_SERIES('2010-01-01'::DATE, '2019-12-31'::DATE, '1 day') AS d;


-- ---------------------------------------------------------------------
-- dim_client
--    Credit-score bands follow the standard FICO cut-offs rather than
--    quantiles of this dataset, so the labels mean the same thing they
--    mean outside it. Every band carries an explicit sort order: without
--    it Power BI orders bands alphabetically and "$120k+" lands first.
-- ---------------------------------------------------------------------
CREATE TABLE dw.dim_client AS
SELECT
    client_id,
    current_age,
    gender,
    credit_score,
    yearly_income,
    total_debt,
    debt_to_income,
    num_credit_cards,
    latitude,
    longitude,
    CASE
        WHEN current_age < 35 THEN 'Under 35'
        WHEN current_age < 45 THEN '35-44'
        WHEN current_age < 55 THEN '45-54'
        WHEN current_age < 65 THEN '55-64'
        ELSE '65+'
    END AS age_band,
    CASE
        WHEN current_age < 35 THEN 1 WHEN current_age < 45 THEN 2
        WHEN current_age < 55 THEN 3 WHEN current_age < 65 THEN 4
        ELSE 5
    END::SMALLINT AS age_band_order,
    CASE
        WHEN credit_score < 580 THEN 'Poor (<580)'
        WHEN credit_score < 670 THEN 'Fair (580-669)'
        WHEN credit_score < 740 THEN 'Good (670-739)'
        WHEN credit_score < 800 THEN 'Very Good (740-799)'
        ELSE 'Exceptional (800+)'
    END AS credit_band,
    CASE
        WHEN credit_score < 580 THEN 1 WHEN credit_score < 670 THEN 2
        WHEN credit_score < 740 THEN 3 WHEN credit_score < 800 THEN 4
        ELSE 5
    END::SMALLINT AS credit_band_order,
    CASE
        WHEN yearly_income <  40000 THEN 'Under $40k'
        WHEN yearly_income <  60000 THEN '$40-60k'
        WHEN yearly_income <  80000 THEN '$60-80k'
        WHEN yearly_income < 120000 THEN '$80-120k'
        ELSE '$120k+'
    END AS income_band,
    CASE
        WHEN yearly_income <  40000 THEN 1 WHEN yearly_income <  60000 THEN 2
        WHEN yearly_income <  80000 THEN 3 WHEN yearly_income < 120000 THEN 4
        ELSE 5
    END::SMALLINT AS income_band_order,
    CASE
        WHEN debt_to_income < 1 THEN 'Under 1x'
        WHEN debt_to_income < 2 THEN '1-2x'
        WHEN debt_to_income < 3 THEN '2-3x'
        ELSE '3x+'
    END AS dti_band,
    CASE
        WHEN debt_to_income < 1 THEN 1 WHEN debt_to_income < 2 THEN 2
        WHEN debt_to_income < 3 THEN 3 ELSE 4
    END::SMALLINT AS dti_band_order
FROM staging.stg_clients;

ALTER TABLE dw.dim_client ADD PRIMARY KEY (client_id);


-- ---------------------------------------------------------------------
-- dim_card
--    No card number, no CVV, no PIN history: those columns are dropped
--    at ingest and never reach this schema.
-- ---------------------------------------------------------------------
CREATE TABLE dw.dim_card AS
SELECT
    card_id,
    client_id,
    card_brand,
    card_type,
    has_chip,
    credit_limit,
    account_opened_on,
    expires_on,
    num_cards_issued,
    CASE
        WHEN credit_limit <  5000 THEN 'Under $5k'
        WHEN credit_limit < 15000 THEN '$5-15k'
        WHEN credit_limit < 30000 THEN '$15-30k'
        ELSE '$30k+'
    END AS limit_band,
    CASE
        WHEN credit_limit <  5000 THEN 1 WHEN credit_limit < 15000 THEN 2
        WHEN credit_limit < 30000 THEN 3 ELSE 4
    END::SMALLINT AS limit_band_order
FROM staging.stg_cards;

ALTER TABLE dw.dim_card ADD PRIMARY KEY (card_id);


-- ---------------------------------------------------------------------
-- dim_location  (replaces an earlier dim_merchant keyed on merchant_id)
--
--    merchant_id is NOT a stable merchant identity in this source. 16,166
--    merchant_ids appear at more than one place and 15,783 of them span
--    more than one state -- merchant 57 alone shows up in MO, TX, TN, CA,
--    WI, MA, MD, MI and FL. The id is reused, not owned.
--
--    Keying a merchant dimension on it therefore forces one location per
--    id and silently discards the rest: doing that here put the wrong
--    city on 8,479,374 of 11,742,215 card-present transactions, 72% of
--    them. So location is modelled as what it actually is -- an attribute
--    of the transaction, not of the merchant. 25,424 distinct places.
--
--    merchant_id stays on the fact as a degenerate dimension, which is
--    all it can honestly support: counting distinct ids, nothing more.
--
--    merchant_state holds a 2-letter code for US merchants and a spelled
--    out country name for the rest, so length is what separates domestic
--    from foreign.
-- ---------------------------------------------------------------------
CREATE TABLE dw.dim_location (
    location_key SERIAL PRIMARY KEY,
    city         TEXT,
    state        TEXT,
    country      TEXT,
    is_domestic  BOOLEAN,
    zip          INTEGER,
    is_online    BOOLEAN NOT NULL
);

-- Sentinels ('' for state, -1 for zip) stand in for NULL so the fact can
-- join on plain equality. A NULL-safe join across 13.3M rows would give
-- up the hash join for nothing.
INSERT INTO dw.dim_location (city, state, country, is_domestic, zip, is_online)
SELECT DISTINCT
    merchant_city,
    COALESCE(merchant_state, ''),
    CASE WHEN merchant_city = 'ONLINE'        THEN NULL
         WHEN LENGTH(merchant_state) = 2      THEN 'United States'
         ELSE merchant_state END,
    CASE WHEN merchant_city = 'ONLINE'        THEN NULL
         ELSE LENGTH(merchant_state) = 2 END,
    COALESCE(zip, -1),
    (merchant_city = 'ONLINE')
FROM staging.stg_transactions;

CREATE UNIQUE INDEX ON dw.dim_location (city, state, zip);


-- ---------------------------------------------------------------------
-- dim_mcc
--    spend_category is the one piece of business logic that is not in
--    the source data. 109 merchant category codes are unreadable on a
--    chart; ten spend categories are the level a portfolio manager
--    actually reasons about. Written here in SQL rather than as a
--    calculated column in Power BI so every consumer sees the same
--    grouping.
-- ---------------------------------------------------------------------
CREATE TABLE dw.dim_mcc AS
SELECT
    mcc::INTEGER AS mcc,
    description,
    CASE
        WHEN mcc::INT IN (5411, 5499, 5300, 5921)
            THEN 'Groceries & Food Retail'
        WHEN mcc::INT IN (5812, 5813, 5814)
            THEN 'Restaurants & Bars'
        WHEN mcc::INT IN (5541, 5533, 7531, 7538, 7542, 7549)
            THEN 'Fuel & Automotive'
        WHEN mcc::INT IN (3722, 3730, 3771, 3775, 4111, 4112, 4121, 4131,
                          4214, 4411, 4511, 4722, 4784, 7011)
            THEN 'Transport & Travel'
        WHEN mcc::INT IN (4814, 4899, 4900, 3780)
            THEN 'Utilities & Telecom'
        WHEN mcc::INT IN (5815, 5816, 7801, 7802, 7832, 7922, 7995, 7996)
            THEN 'Digital & Entertainment'
        WHEN mcc::INT IN (5912, 7210, 7230, 8011, 8021, 8041, 8043, 8049,
                          8062, 8099)
            THEN 'Health & Personal Care'
        WHEN mcc::INT IN (4829, 6300, 7276, 7393, 8111, 8931, 9402)
            THEN 'Financial & Professional Services'
        WHEN mcc::INT IN (1711, 3504, 3509, 3596, 3640, 3684, 5211, 5251,
                          5261, 7349)
            THEN 'Home & Trade Supplies'
        WHEN mcc::INT BETWEEN 3000 AND 3999
            THEN 'Home & Trade Supplies'
        ELSE 'General Retail & Apparel'
    END AS spend_category
FROM staging.raw_mcc;

ALTER TABLE dw.dim_mcc ADD PRIMARY KEY (mcc);


-- ---------------------------------------------------------------------
-- dim_channel
-- ---------------------------------------------------------------------
CREATE TABLE dw.dim_channel (
    channel_key     SMALLINT PRIMARY KEY,
    channel_name    VARCHAR(20) NOT NULL UNIQUE,
    is_card_present BOOLEAN NOT NULL
);
INSERT INTO dw.dim_channel VALUES
    (1, 'Chip',   TRUE),
    (2, 'Swipe',  TRUE),
    (3, 'Online', FALSE);


-- ---------------------------------------------------------------------
-- dim_ticket_band
--    Fraud rate tracks ticket size closely enough that the band is worth
--    modelling rather than bucketing inside each query: 0.085% at
--    $25-100 against 0.858% above $500, a factor of ten.
--
--    Kept as a 5-row dimension with a SMALLINT key on the fact rather
--    than a text column on 3.9M rows -- same reasoning as dim_channel.
--    Boundaries live here so the report, the SQL in 03_analysis.sql and
--    anyone querying later all cut the data at the same places.
-- ---------------------------------------------------------------------
CREATE TABLE dw.dim_ticket_band (
    ticket_band_key   SMALLINT PRIMARY KEY,
    ticket_band       VARCHAR(20) NOT NULL UNIQUE,
    lower_bound       NUMERIC(12,2) NOT NULL,
    upper_bound       NUMERIC(12,2)          -- NULL = tidak terbatas
);
INSERT INTO dw.dim_ticket_band VALUES
    (1, 'Under $25',  0,    25),
    (2, '$25-100',    25,   100),
    (3, '$100-250',   100,  250),
    (4, '$250-500',   250,  500),
    (5, '$500+',      500,  NULL);


-- ---------------------------------------------------------------------
-- dim_error
--    fault_owner is the point of this dimension. Grouping every decline
--    into one "failed" bucket hides that they have different owners:
--    Insufficient Balance is the customer's own balance and the bank
--    cannot fix it, while Bad Expiration means the bank did not reissue
--    a card before it expired -- entirely the issuer's to prevent.
-- ---------------------------------------------------------------------
CREATE TABLE dw.dim_error (
    error_key   SMALLINT PRIMARY KEY,
    error_name  VARCHAR(30) NOT NULL UNIQUE,
    fault_owner VARCHAR(20) NOT NULL
);
INSERT INTO dw.dim_error VALUES
    (1, 'Insufficient Balance', 'Customer'),
    (2, 'Bad PIN',              'Customer'),
    (3, 'Technical Glitch',     'Issuer'),
    (4, 'Bad Expiration',       'Issuer'),
    (5, 'Bad Card Number',      'Data entry'),
    (6, 'Bad CVV',              'Data entry'),
    (7, 'Bad Zipcode',          'Data entry');


-- ---------------------------------------------------------------------
-- fact_transaction  -  grain: one card transaction
--
--    has_fraud_label matters as much as is_fraud. Labels cover 8,914,963
--    of 13,305,915 rows (67%), sampled at random rather than by date, so
--    any fraud rate must divide by labelled rows only. Dividing by every
--    row understates it by a third: 0.100% instead of 0.150%.
-- ---------------------------------------------------------------------
--    is_zero_auth marks the 10,639 transactions of exactly $0.00, of
--    which 10,610 are MCC 4829 Money Transfer. These are account
--    verification authorisations -- a merchant asking "is this card
--    live?" without charging anything. They are real events, but they
--    are not spend: left unflagged they pad the transaction count and
--    drag Avg Ticket down. They are also the textbook card-testing
--    probe, which makes them worth isolating rather than deleting.
CREATE TABLE dw.fact_transaction AS
SELECT
    t.transaction_id,
    TO_CHAR(t.transaction_date, 'YYYYMMDD')::INTEGER AS date_key,
    t.hour_of_day,
    t.client_id,
    t.card_id,
    t.merchant_id,          -- degenerate: an id, not a merchant identity
    l.location_key,
    t.mcc,
    ch.channel_key,
    tb.ticket_band_key,
    t.amount,
    ABS(t.amount)       AS abs_amount,
    (t.amount < 0)      AS is_refund,
    (t.amount = 0)      AS is_zero_auth,
    t.is_failed,
    t.is_online,
    t.has_fraud_label,
    COALESCE(t.is_fraud, FALSE) AS is_fraud
FROM staging.stg_transactions t
JOIN dw.dim_channel ch ON ch.channel_name = SPLIT_PART(t.channel, ' ', 1)
JOIN dw.dim_ticket_band tb
       ON ABS(t.amount) >= tb.lower_bound
      AND (tb.upper_bound IS NULL OR ABS(t.amount) < tb.upper_bound)
JOIN dw.dim_location l
       ON l.city  = t.merchant_city
      AND l.state = COALESCE(t.merchant_state, '')
      AND l.zip   = COALESCE(t.zip, -1);

ALTER TABLE dw.fact_transaction ADD PRIMARY KEY (transaction_id);
CREATE INDEX ON dw.fact_transaction (date_key);
CREATE INDEX ON dw.fact_transaction (card_id);
CREATE INDEX ON dw.fact_transaction (mcc);
CREATE INDEX ON dw.fact_transaction (location_key);
CREATE INDEX ON dw.fact_transaction (ticket_band_key);


-- ---------------------------------------------------------------------
-- br_transaction_error  -  a transaction can decline for several reasons
--    at once ("Bad Card Number,Bad Expiration,Insufficient Balance"), so
--    the error cannot be a foreign key on the fact row. This is the
--    bridge that lets one transaction carry several.
-- ---------------------------------------------------------------------
CREATE TABLE dw.br_transaction_error AS
SELECT
    t.transaction_id,
    e.error_key
FROM staging.stg_transactions t
CROSS JOIN LATERAL UNNEST(t.error_list) AS raw_error
JOIN dw.dim_error e ON e.error_name = TRIM(raw_error)
WHERE t.error_list IS NOT NULL;

ALTER TABLE dw.br_transaction_error ADD PRIMARY KEY (transaction_id, error_key);
CREATE INDEX ON dw.br_transaction_error (error_key);


-- ---------------------------------------------------------------------
-- BI layer
--    Power BI imports from here, not from dw directly. The window is the
--    last three full-ish years (2017-01-01 onward); the full 2010-2019
--    history stays in dw for the SQL-side analysis that needs a longer
--    run-up, such as the 2015 EMV comparison.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW bi.fact_transaction AS
SELECT f.* FROM dw.fact_transaction f WHERE f.date_key >= 20170101;

CREATE OR REPLACE VIEW bi.br_transaction_error AS
SELECT b.* FROM dw.br_transaction_error b
JOIN dw.fact_transaction f USING (transaction_id)
WHERE f.date_key >= 20170101;

-- dw.dim_date runs to 2019-12-31 so the calendar is whole, but the data
-- stops on 2019-10-31. Exposing the full calendar to Power BI would end
-- every trend line with 61 days of zeroes that look like a collapse in
-- volume rather than the end of the file, so the BI view stops where the
-- facts do -- read from the facts, not hard-coded, so it stays true if
-- the source is ever extended.
CREATE OR REPLACE VIEW bi.dim_date AS
SELECT d.* FROM dw.dim_date d
WHERE d.full_date >= DATE '2017-01-01'
  AND d.date_key <= (SELECT MAX(date_key) FROM dw.fact_transaction);

CREATE OR REPLACE VIEW bi.dim_client   AS SELECT * FROM dw.dim_client;
CREATE OR REPLACE VIEW bi.dim_card     AS SELECT * FROM dw.dim_card;
CREATE OR REPLACE VIEW bi.dim_location AS SELECT * FROM dw.dim_location;
CREATE OR REPLACE VIEW bi.dim_mcc      AS SELECT * FROM dw.dim_mcc;
CREATE OR REPLACE VIEW bi.dim_channel  AS SELECT * FROM dw.dim_channel;
CREATE OR REPLACE VIEW bi.dim_ticket_band AS SELECT * FROM dw.dim_ticket_band;
CREATE OR REPLACE VIEW bi.dim_error    AS SELECT * FROM dw.dim_error;


-- ---------------------------------------------------------------------
-- Reconciliation - every column in the first block must be 0.
--
-- wrong_location and empty_bi_days are here because both were real
-- defects found by auditing the built warehouse rather than the source:
-- a merchant dimension keyed on a reused id put the wrong city on 72% of
-- card-present rows, and a calendar running past the last fact left 61
-- empty days at the end of every chart. Neither shows up in a NULL
-- check, so both now have a standing test.
-- ---------------------------------------------------------------------
SELECT
    (SELECT COUNT(*) FROM staging.stg_transactions)
      - (SELECT COUNT(*) FROM dw.fact_transaction)          AS rows_lost,
    (SELECT SUM(amount) FROM staging.stg_transactions)
      - (SELECT SUM(amount) FROM dw.fact_transaction)       AS amount_drift,
    (SELECT COUNT(*) FROM dw.dim_mcc WHERE spend_category IS NULL)
                                                            AS uncategorised_mcc,
    (SELECT COUNT(*) FROM dw.fact_transaction WHERE location_key IS NULL)
                                                            AS unmatched_location,
    (SELECT COUNT(*) FROM dw.fact_transaction WHERE ticket_band_key IS NULL)
                                                            AS unbanded_ticket,
    -- every fact row must carry the location its source row actually had
    (SELECT COUNT(*)
       FROM dw.fact_transaction f
       JOIN dw.dim_location l USING (location_key)
       JOIN staging.stg_transactions t USING (transaction_id)
      WHERE l.city  IS DISTINCT FROM t.merchant_city
         OR l.state IS DISTINCT FROM COALESCE(t.merchant_state, ''))
                                                            AS wrong_location,
    -- no day inside the BI window may be empty
    (SELECT COUNT(*) FROM bi.dim_date d
      WHERE NOT EXISTS (SELECT 1 FROM bi.fact_transaction f
                         WHERE f.date_key = d.date_key))    AS empty_bi_days;

SELECT
    (SELECT COUNT(*) FROM bi.fact_transaction)              AS bi_window_rows,
    (SELECT COUNT(*) FROM dw.dim_location)                  AS locations,
    (SELECT COUNT(*) FROM dw.br_transaction_error)          AS bridge_rows,
    (SELECT COUNT(*) FROM dw.fact_transaction WHERE is_fraud)      AS fraud_rows,
    (SELECT COUNT(*) FROM dw.fact_transaction WHERE is_zero_auth)  AS zero_auth_rows;
