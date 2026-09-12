-- =====================================================================
-- Biller Analytics Pipeline - business questions
--
-- Convention used throughout: every revenue measure filters on
-- is_success = 1. Failed and pending transactions carry a biaya_admin
-- value in the source, but that fee is never collected.
-- =====================================================================


-- ---------------------------------------------------------------------
-- Q1. Transaction volume per month
--     April 2026 contains a single day (1 Apr). It is flagged here so
--     the partial period is never mistaken for a collapse in demand.
-- ---------------------------------------------------------------------
SELECT
    year,
    month,
    month_name,
    COUNT(*)                                    AS total_transactions,
    COUNT(DISTINCT full_date)                   AS days_with_data,
    ROUND(COUNT(*)::NUMERIC / COUNT(DISTINCT full_date), 0) AS avg_txn_per_day,
    CASE WHEN COUNT(DISTINCT full_date) < 28 THEN 'PARTIAL MONTH' END AS data_note
FROM dw.vw_transaction_report
GROUP BY year, month, month_name
ORDER BY year, month;


-- ---------------------------------------------------------------------
-- Q2. Revenue per month - GMV vs net revenue
--
--     The brief asked for "total revenue". SUM(total_bayar) answers it
--     literally, but total_bayar is the customer's bill plus a service
--     fee, and the bill is pass-through money forwarded to PLN / PDAM /
--     BPJS. The bank's actual revenue is biaya_admin: ~0.9% of GMV.
--     Both are reported, labelled distinctly.
-- ---------------------------------------------------------------------
SELECT
    year,
    month_name,
    COUNT(*) FILTER (WHERE is_success = 1)      AS settled_transactions,
    SUM(gmv_settled)                            AS gmv,
    SUM(net_revenue)                            AS net_revenue,
    ROUND(100.0 * SUM(net_revenue) / NULLIF(SUM(gmv_settled), 0), 2) AS take_rate_pct
FROM dw.vw_transaction_report
GROUP BY year, month, month_name
ORDER BY year, month;


-- ---------------------------------------------------------------------
-- Q3. Top 5 billers by transaction volume
-- ---------------------------------------------------------------------
SELECT
    nama_biller,
    jenis_biller,
    COUNT(*)                                    AS total_transactions,
    SUM(net_revenue)                            AS net_revenue,
    ROUND(100.0 * AVG(is_success), 2)           AS success_rate_pct
FROM dw.vw_transaction_report
GROUP BY nama_biller, jenis_biller
ORDER BY total_transactions DESC
LIMIT 5;


-- ---------------------------------------------------------------------
-- Q4. Channel breakdown
--     Share is computed with a window function so each row carries its
--     own percentage of the whole without a second pass over the table.
-- ---------------------------------------------------------------------
SELECT
    channel_name,
    COUNT(*)                                                        AS total_transactions,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)              AS share_of_volume_pct,
    SUM(net_revenue)                                                AS net_revenue,
    ROUND(100.0 * SUM(net_revenue) / SUM(SUM(net_revenue)) OVER (), 2) AS share_of_revenue_pct,
    ROUND(100.0 * AVG(is_success), 2)                               AS success_rate_pct
FROM dw.vw_transaction_report
GROUP BY channel_name
ORDER BY total_transactions DESC;


-- ---------------------------------------------------------------------
-- Q5. Success vs failure, and what the failures cost
--
--     This is the headline number: 8.60% of transactions never settle,
--     and the fees on them - Rp 43.0M over the period - are never
--     collected. That is 8.6% of potential fee revenue.
-- ---------------------------------------------------------------------
SELECT
    status,
    COUNT(*)                                            AS transactions,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)  AS share_pct,
    SUM(biaya_admin)                                    AS fees_at_stake,
    SUM(CASE WHEN is_success = 0 THEN biaya_admin ELSE 0 END) AS fees_forgone
FROM dw.vw_transaction_report
GROUP BY status
ORDER BY transactions DESC;


-- ---------------------------------------------------------------------
-- Q6. Is the failure rate concentrated anywhere?
--
--     Answer: no. Success rate lands between 91.1% and 91.7% for every
--     channel, every biller and every weekday - a spread under 0.6pp,
--     which is noise at 200k rows. There is no worst-performing segment
--     to prioritise; the failure rate is a platform-wide baseline, and
--     diagnosing it needs gateway/timeout logs this dataset lacks.
--
--     This query is kept because ruling a hypothesis out is a result.
-- ---------------------------------------------------------------------
SELECT
    'channel'   AS dimension, channel_name AS segment,
    COUNT(*) AS transactions, ROUND(100.0 * AVG(is_success), 2) AS success_rate_pct
FROM dw.vw_transaction_report GROUP BY channel_name

UNION ALL
SELECT
    'biller', nama_biller,
    COUNT(*), ROUND(100.0 * AVG(is_success), 2)
FROM dw.vw_transaction_report GROUP BY nama_biller

UNION ALL
SELECT
    'weekday', day_name,
    COUNT(*), ROUND(100.0 * AVG(is_success), 2)
FROM dw.vw_transaction_report GROUP BY day_name

ORDER BY dimension, success_rate_pct;


-- ---------------------------------------------------------------------
-- Q7. Daily trend (optional in the brief)
--     Restricted to Jan-Mar: April holds one day and would render as a
--     cliff in any line chart.
-- ---------------------------------------------------------------------
SELECT
    full_date,
    COUNT(*)            AS total_transactions,
    SUM(is_success)     AS settled_transactions,
    SUM(net_revenue)    AS net_revenue
FROM dw.vw_transaction_report
WHERE full_date < DATE '2026-04-01'
GROUP BY full_date
ORDER BY full_date;
