-- =====================================================================
-- Biller Analytics Pipeline - staging, cleaning, and star schema
-- Target: PostgreSQL. Idempotent: safe to re-run.
-- Prerequisite: scripts/import_data.py has loaded staging.raw_transactions
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS staging;
CREATE SCHEMA IF NOT EXISTS dw;


-- ---------------------------------------------------------------------
-- 1. Raw landing table
--    Dates land as VARCHAR so a malformed value fails at the cast step
--    (visible, fixable) instead of aborting the whole load.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS staging.raw_transactions (
    id_transaksi        VARCHAR(20) PRIMARY KEY,
    tanggal             VARCHAR(20),
    no_rekening         BIGINT,
    nama_nasabah        VARCHAR(100),
    jenis_biller        VARCHAR(50),
    nama_biller         VARCHAR(50),
    nomor_pelanggan     BIGINT,
    nominal             BIGINT,
    biaya_admin         BIGINT,
    total_bayar         BIGINT,
    channel             VARCHAR(50),
    status              VARCHAR(20)
);


-- ---------------------------------------------------------------------
-- 2. Cleaned staging layer
--    - dates cast to DATE, month/year pre-extracted for reporting
--    - text fields trimmed (source has trailing spaces)
--    - NULL numerics coalesced to 0
--    - is_success: Pending is grouped with Gagal, because a pending
--      payment has not produced confirmed revenue. The original 3-value
--      status column is preserved so the distinction is never lost.
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS staging.stg_transactions;
CREATE TABLE staging.stg_transactions AS
SELECT
    id_transaksi,
    CAST(tanggal AS DATE)                       AS transaction_date_clean,
    EXTRACT(MONTH FROM CAST(tanggal AS DATE))   AS transaction_month,
    EXTRACT(YEAR  FROM CAST(tanggal AS DATE))   AS transaction_year,
    no_rekening,
    TRIM(nama_nasabah)                          AS nama_nasabah,
    TRIM(jenis_biller)                          AS jenis_biller,
    TRIM(nama_biller)                           AS nama_biller,
    nomor_pelanggan,
    COALESCE(nominal, 0)                        AS nominal,
    COALESCE(biaya_admin, 0)                    AS biaya_admin,
    COALESCE(total_bayar, 0)                    AS total_bayar,
    TRIM(channel)                               AS channel,
    TRIM(status)                                AS status,
    CASE WHEN TRIM(status) = 'Sukses' THEN 1 ELSE 0 END AS is_success
FROM staging.raw_transactions;


-- ---------------------------------------------------------------------
-- 3. Data quality checks - all four columns must return 0
-- ---------------------------------------------------------------------
SELECT
    COUNT(*) FILTER (WHERE transaction_date_clean IS NULL)        AS null_dates,
    COUNT(*) FILTER (WHERE channel IS NULL OR channel = '')       AS null_channels,
    COUNT(*) FILTER (WHERE status  IS NULL OR status  = '')       AS null_status,
    COUNT(*) FILTER (WHERE total_bayar <> nominal + biaya_admin)  AS amount_mismatch
FROM staging.stg_transactions;


-- ---------------------------------------------------------------------
-- 4. Dimensions
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS dw.fact_transactions;
DROP TABLE IF EXISTS dw.dim_date;
DROP TABLE IF EXISTS dw.dim_channel;
DROP TABLE IF EXISTS dw.dim_biller;

CREATE TABLE dw.dim_date (
    date_key        INTEGER PRIMARY KEY,
    full_date       DATE NOT NULL UNIQUE,
    day_of_month    SMALLINT,
    day_name        VARCHAR(20),
    day_of_week     SMALLINT,
    month           SMALLINT,
    month_name      VARCHAR(20),
    quarter         SMALLINT,
    year            SMALLINT
);

INSERT INTO dw.dim_date
SELECT DISTINCT
    TO_CHAR(transaction_date_clean, 'YYYYMMDD')::INTEGER,
    transaction_date_clean,
    EXTRACT(DAY   FROM transaction_date_clean),
    TRIM(TO_CHAR(transaction_date_clean, 'Day')),
    EXTRACT(DOW   FROM transaction_date_clean),
    EXTRACT(MONTH FROM transaction_date_clean),
    TRIM(TO_CHAR(transaction_date_clean, 'Month')),
    EXTRACT(QUARTER FROM transaction_date_clean),
    EXTRACT(YEAR  FROM transaction_date_clean)
FROM staging.stg_transactions;

CREATE TABLE dw.dim_channel (
    channel_key     SERIAL PRIMARY KEY,
    channel_name    VARCHAR(50) NOT NULL UNIQUE
);
INSERT INTO dw.dim_channel (channel_name)
SELECT DISTINCT channel FROM staging.stg_transactions ORDER BY 1;

CREATE TABLE dw.dim_biller (
    biller_key      SERIAL PRIMARY KEY,
    jenis_biller    VARCHAR(50) NOT NULL,
    nama_biller     VARCHAR(50) NOT NULL UNIQUE
);
INSERT INTO dw.dim_biller (jenis_biller, nama_biller)
SELECT DISTINCT jenis_biller, nama_biller FROM staging.stg_transactions ORDER BY 1, 2;


-- ---------------------------------------------------------------------
-- 5. Fact table
--    biaya_admin is the bank's own revenue; nominal and total_bayar are
--    pass-through amounts owed to the biller. Kept separate on purpose.
-- ---------------------------------------------------------------------
CREATE TABLE dw.fact_transactions (
    transaction_id      VARCHAR(20) PRIMARY KEY,
    date_key            INTEGER REFERENCES dw.dim_date(date_key),
    channel_key         INTEGER REFERENCES dw.dim_channel(channel_key),
    biller_key          INTEGER REFERENCES dw.dim_biller(biller_key),
    no_rekening         BIGINT,
    nomor_pelanggan     BIGINT,
    nominal             BIGINT,   -- pass-through: bill amount owed to the biller
    biaya_admin         BIGINT,   -- net revenue: fee retained by the bank
    total_bayar         BIGINT,   -- GMV: nominal + biaya_admin
    status              VARCHAR(20),
    is_success          SMALLINT
);

INSERT INTO dw.fact_transactions
SELECT
    s.id_transaksi,
    TO_CHAR(s.transaction_date_clean, 'YYYYMMDD')::INTEGER,
    c.channel_key,
    b.biller_key,
    s.no_rekening,
    s.nomor_pelanggan,
    s.nominal,
    s.biaya_admin,
    s.total_bayar,
    s.status,
    s.is_success
FROM staging.stg_transactions s
JOIN dw.dim_channel c ON s.channel     = c.channel_name
JOIN dw.dim_biller  b ON s.nama_biller = b.nama_biller;

CREATE INDEX idx_fact_date    ON dw.fact_transactions(date_key);
CREATE INDEX idx_fact_channel ON dw.fact_transactions(channel_key);
CREATE INDEX idx_fact_biller  ON dw.fact_transactions(biller_key);


-- ---------------------------------------------------------------------
-- 6. Load check - all three counts must match
-- ---------------------------------------------------------------------
SELECT
    (SELECT COUNT(*) FROM staging.raw_transactions) AS raw_rows,
    (SELECT COUNT(*) FROM staging.stg_transactions) AS staged_rows,
    (SELECT COUNT(*) FROM dw.fact_transactions)     AS fact_rows;


-- ---------------------------------------------------------------------
-- 7. Reporting view - this is what Tableau connects to.
--    gmv_settled and net_revenue are pre-zeroed for failed transactions
--    so a BI tool cannot accidentally sum revenue that was never earned.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW dw.vw_transaction_report AS
SELECT
    f.transaction_id,
    dd.full_date,
    dd.day_name,
    dd.month,
    dd.month_name,
    dd.quarter,
    dd.year,
    dc.channel_name,
    db.jenis_biller,
    db.nama_biller,
    f.nominal,
    f.biaya_admin,
    f.total_bayar,
    f.status,
    f.is_success,
    CASE WHEN f.is_success = 1 THEN f.total_bayar ELSE 0 END AS gmv_settled,
    CASE WHEN f.is_success = 1 THEN f.biaya_admin ELSE 0 END AS net_revenue
FROM dw.fact_transactions f
JOIN dw.dim_date    dd ON f.date_key    = dd.date_key
JOIN dw.dim_channel dc ON f.channel_key = dc.channel_key
JOIN dw.dim_biller  db ON f.biller_key  = db.biller_key;
