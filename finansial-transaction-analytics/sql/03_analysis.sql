-- =====================================================================
-- 03 - Analysis: the query behind every figure quoted in the README.
-- Target: PostgreSQL 16. Read-only.
--
-- Unless a query says otherwise it runs on the BI window (2017-01-01
-- onward). The EMV section at the bottom deliberately uses the full
-- 2010-2019 history, which is why that history stays in dw.
-- =====================================================================


-- =====================================================================
-- PILLAR 1 - REVENUE LEAKAGE: transactions that never completed
-- =====================================================================

-- 1.1 How much is leaking, and is it moving?
SELECT
    d.year,
    COUNT(*)                                            AS transactions,
    COUNT(*) FILTER (WHERE f.is_failed)                 AS failed,
    ROUND(100.0 * COUNT(*) FILTER (WHERE f.is_failed) / COUNT(*), 3)
                                                        AS failure_rate_pct,
    ROUND(SUM(f.abs_amount) FILTER (WHERE f.is_failed))  AS failed_value_usd
FROM bi.fact_transaction f
JOIN bi.dim_date d USING (date_key)
GROUP BY d.year
ORDER BY d.year;


-- 1.2 Who owns the failure? This is the split that decides whether the
--     bank can do anything about it.
SELECT
    e.fault_owner,
    e.error_name,
    COUNT(*)                        AS occurrences,
    ROUND(SUM(f.abs_amount))        AS value_usd,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_of_failures
FROM bi.br_transaction_error b
JOIN bi.dim_error e USING (error_key)
JOIN bi.fact_transaction f USING (transaction_id)
GROUP BY e.fault_owner, e.error_name
ORDER BY occurrences DESC;


-- 1.3 Failure rate by channel. A card-present decline and an online
--     decline are not the same operational problem.
SELECT
    c.channel_name,
    COUNT(*)                                            AS transactions,
    ROUND(100.0 * COUNT(*) FILTER (WHERE f.is_failed) / COUNT(*), 3)
                                                        AS failure_rate_pct,
    ROUND(SUM(f.abs_amount) FILTER (WHERE f.is_failed))  AS failed_value_usd
FROM bi.fact_transaction f
JOIN bi.dim_channel c USING (channel_key)
GROUP BY c.channel_name
ORDER BY failure_rate_pct DESC;


-- 1.4 Bad Expiration is the purely issuer-side failure: a card that
--     expired before the bank reissued it. Broken out on its own because
--     it is the one line item a reissue process can drive to zero.
SELECT
    d.year,
    COUNT(*)                    AS expired_card_declines,
    ROUND(SUM(f.abs_amount))    AS value_usd,
    COUNT(DISTINCT f.card_id)   AS cards_affected
FROM bi.br_transaction_error b
JOIN bi.dim_error e USING (error_key)
JOIN bi.fact_transaction f USING (transaction_id)
JOIN bi.dim_date d ON d.date_key = f.date_key
WHERE e.error_name = 'Bad Expiration'
GROUP BY d.year
ORDER BY d.year;


-- 1.5 Where the declines land, by spend category.
SELECT
    m.spend_category,
    COUNT(*)                                            AS transactions,
    ROUND(100.0 * COUNT(*) FILTER (WHERE f.is_failed) / COUNT(*), 3)
                                                        AS failure_rate_pct,
    ROUND(SUM(f.abs_amount) FILTER (WHERE f.is_failed))  AS failed_value_usd
FROM bi.fact_transaction f
JOIN bi.dim_mcc m USING (mcc)
GROUP BY m.spend_category
ORDER BY failed_value_usd DESC;


-- 1.6 Why the category failure rates differ: the error mix, not the
--     volume. Restaurants take cards in person and carry no stored
--     credential, so Bad Card Number / Bad CVV / Bad Expiration are
--     absent there. Utilities bill a card on file every month, and that
--     is exactly where those three appear.
SELECT
    m.spend_category,
    e.error_name,
    COUNT(*)                                                AS occurrences,
    ROUND(100.0 * COUNT(*)
          / SUM(COUNT(*)) OVER (PARTITION BY m.spend_category), 1)
                                                            AS pct_within_category
FROM bi.br_transaction_error b
JOIN bi.dim_error e USING (error_key)
JOIN bi.fact_transaction f USING (transaction_id)
JOIN bi.dim_mcc m USING (mcc)
GROUP BY m.spend_category, e.error_name
ORDER BY m.spend_category, occurrences DESC;


-- 1.7 Stale-credential declines: the card on file no longer matches the
--     card. Grouped as one problem because Bad Card Number, Bad CVV and
--     Bad Expiration all mean the same thing to a recurring biller, and
--     all three are fixed by the same thing -- pushing reissued card
--     details out to the merchants holding them. Bad Zipcode shares the
--     'Data entry' fault_owner but is an address mismatch, not a stale
--     card, so it is named out rather than swept in by fault_owner.
SELECT
    m.spend_category,
    COUNT(*)                    AS stale_credential_declines,
    ROUND(SUM(f.abs_amount))    AS value_usd,
    COUNT(DISTINCT f.card_id)   AS cards_affected
FROM bi.br_transaction_error b
JOIN bi.dim_error e USING (error_key)
JOIN bi.fact_transaction f USING (transaction_id)
JOIN bi.dim_mcc m USING (mcc)
WHERE e.error_name IN ('Bad Card Number', 'Bad CVV', 'Bad Expiration')
GROUP BY ROLLUP (m.spend_category)
ORDER BY value_usd DESC NULLS FIRST;

-- 1.7b The same thing as a rate. The split is by whether the category
--      bills a card it already holds, not by any one category: tolls,
--      transit and travel bookings store a card exactly like a utility
--      does, and at 0.8574% they are worse than utilities. Grouping them
--      is what makes the contrast honest -- 0.7467% against 0.0258%,
--      a factor of 29.
SELECT
    CASE WHEN m.spend_category IN ('Transport & Travel',
                                   'Utilities & Telecom',
                                   'Digital & Entertainment')
         THEN 'Card-on-file' ELSE 'Card-present' END AS segment,
    COUNT(*)                                                AS transactions,
    COUNT(*) FILTER (WHERE EXISTS (
        SELECT 1 FROM bi.br_transaction_error b
        JOIN bi.dim_error e USING (error_key)
        WHERE b.transaction_id = f.transaction_id
          AND e.error_name IN ('Bad Card Number', 'Bad CVV', 'Bad Expiration')
    ))                                                      AS stale_credential,
    ROUND(100.0 * COUNT(*) FILTER (WHERE EXISTS (
        SELECT 1 FROM bi.br_transaction_error b
        JOIN bi.dim_error e USING (error_key)
        WHERE b.transaction_id = f.transaction_id
          AND e.error_name IN ('Bad Card Number', 'Bad CVV', 'Bad Expiration')
    )) / COUNT(*), 4)                                       AS rate_pct
FROM bi.fact_transaction f
JOIN bi.dim_mcc m USING (mcc)
GROUP BY 1;


-- =====================================================================
-- PILLAR 2 - FRAUD
--
-- Every rate below divides by rows WHERE has_fraud_label. Labels cover
-- 67% of transactions, sampled at random, so dividing by all rows
-- understates fraud by a third. The unlabelled rows are not "not fraud",
-- they are unknown, and they are excluded rather than assumed clean.
-- =====================================================================

-- 2.1 The denominator, stated once so it can be checked.
SELECT
    COUNT(*)                                        AS all_rows,
    COUNT(*) FILTER (WHERE has_fraud_label)         AS labelled_rows,
    ROUND(100.0 * COUNT(*) FILTER (WHERE has_fraud_label) / COUNT(*), 1)
                                                    AS label_coverage_pct,
    COUNT(*) FILTER (WHERE is_fraud)                AS fraud_rows,
    ROUND(100.0 * COUNT(*) FILTER (WHERE is_fraud)
          / COUNT(*) FILTER (WHERE has_fraud_label), 4) AS fraud_rate_pct,
    ROUND(100.0 * COUNT(*) FILTER (WHERE is_fraud) / COUNT(*), 4)
                                                    AS wrong_denominator_pct
FROM bi.fact_transaction;


-- 2.2 Fraud by channel: rate and dollars.
SELECT
    c.channel_name,
    COUNT(*) FILTER (WHERE f.has_fraud_label)       AS labelled,
    COUNT(*) FILTER (WHERE f.is_fraud)              AS fraud_txns,
    ROUND(100.0 * COUNT(*) FILTER (WHERE f.is_fraud)
          / NULLIF(COUNT(*) FILTER (WHERE f.has_fraud_label), 0), 4)
                                                    AS fraud_rate_pct,
    ROUND(SUM(f.abs_amount) FILTER (WHERE f.is_fraud)) AS fraud_loss_usd,
    ROUND(AVG(f.abs_amount) FILTER (WHERE f.is_fraud), 2) AS avg_fraud_ticket,
    ROUND(AVG(f.abs_amount) FILTER (WHERE f.has_fraud_label
                                      AND NOT f.is_fraud), 2) AS avg_clean_ticket
FROM bi.fact_transaction f
JOIN bi.dim_channel c USING (channel_key)
GROUP BY c.channel_name
ORDER BY fraud_rate_pct DESC;


-- 2.3 Fraud by spend category - where to point a review queue.
SELECT
    m.spend_category,
    COUNT(*) FILTER (WHERE f.is_fraud)              AS fraud_txns,
    ROUND(100.0 * COUNT(*) FILTER (WHERE f.is_fraud)
          / NULLIF(COUNT(*) FILTER (WHERE f.has_fraud_label), 0), 4)
                                                    AS fraud_rate_pct,
    ROUND(SUM(f.abs_amount) FILTER (WHERE f.is_fraud)) AS fraud_loss_usd
FROM bi.fact_transaction f
JOIN bi.dim_mcc m USING (mcc)
GROUP BY m.spend_category
HAVING COUNT(*) FILTER (WHERE f.is_fraud) > 0
ORDER BY fraud_rate_pct DESC;


-- 2.4 Ticket size. If fraud clusters in a band, that band is a cheap
--     first filter for a review queue.
WITH banded AS (
    SELECT
        CASE
            WHEN abs_amount <   25 THEN '1. Under $25'
            WHEN abs_amount <  100 THEN '2. $25-100'
            WHEN abs_amount <  250 THEN '3. $100-250'
            WHEN abs_amount <  500 THEN '4. $250-500'
            ELSE                        '5. $500+'
        END AS ticket_band,
        has_fraud_label, is_fraud, abs_amount
    FROM bi.fact_transaction
)
SELECT
    ticket_band,
    COUNT(*) FILTER (WHERE has_fraud_label)         AS labelled,
    COUNT(*) FILTER (WHERE is_fraud)                AS fraud_txns,
    ROUND(100.0 * COUNT(*) FILTER (WHERE is_fraud)
          / NULLIF(COUNT(*) FILTER (WHERE has_fraud_label), 0), 4)
                                                    AS fraud_rate_pct,
    ROUND(SUM(abs_amount) FILTER (WHERE is_fraud))  AS fraud_loss_usd
FROM banded
GROUP BY ticket_band
ORDER BY ticket_band;


-- 2.5 Concentration: how small a slice of traffic carries the loss.
--     Transactions ranked by size; how much fraud loss sits in the top
--     1% / 5% / 10% of tickets.
WITH ranked AS (
    SELECT
        abs_amount, is_fraud,
        NTILE(100) OVER (ORDER BY abs_amount DESC) AS pct_rank
    FROM bi.fact_transaction
    WHERE has_fraud_label
)
SELECT
    CASE WHEN pct_rank <=  1 THEN 'Top 1% by ticket size'
         WHEN pct_rank <=  5 THEN 'Top 5%'
         WHEN pct_rank <= 10 THEN 'Top 10%'
         ELSE                     'Remaining 90%' END AS slice,
    COUNT(*)                                    AS transactions,
    COUNT(*) FILTER (WHERE is_fraud)            AS fraud_txns,
    ROUND(SUM(abs_amount) FILTER (WHERE is_fraud)) AS fraud_loss_usd
FROM ranked
GROUP BY 1
ORDER BY MIN(pct_rank);


-- 2.6 Hour of day.
SELECT
    hour_of_day,
    COUNT(*) FILTER (WHERE is_fraud)            AS fraud_txns,
    ROUND(100.0 * COUNT(*) FILTER (WHERE is_fraud)
          / NULLIF(COUNT(*) FILTER (WHERE has_fraud_label), 0), 4)
                                                AS fraud_rate_pct
FROM bi.fact_transaction
GROUP BY hour_of_day
ORDER BY fraud_rate_pct DESC
LIMIT 8;


-- 2.7 The evening block against everything else. 2.6 ranks single hours,
--     which is noisy; this is the same signal sized properly.
SELECT
    CASE WHEN hour_of_day BETWEEN 17 AND 19
         THEN 'Evening 17-19' ELSE 'All other hours' END     AS block,
    COUNT(*) FILTER (WHERE has_fraud_label)                  AS labelled,
    COUNT(*) FILTER (WHERE is_fraud)                         AS fraud_txns,
    ROUND(100.0 * COUNT(*) FILTER (WHERE is_fraud)
          / COUNT(*) FILTER (WHERE has_fraud_label), 4)      AS fraud_rate_pct,
    ROUND(SUM(abs_amount) FILTER (WHERE is_fraud))           AS fraud_loss_usd
FROM bi.fact_transaction
GROUP BY 1
ORDER BY fraud_rate_pct DESC;


-- 2.8 Card type. Kept at type level rather than brand x type: splitting
--     by brand as well leaves a few thousand labelled rows per cell, and
--     rates off a denominator that small move on noise.
SELECT
    ca.card_type,
    COUNT(*) FILTER (WHERE f.has_fraud_label)                AS labelled,
    COUNT(*) FILTER (WHERE f.is_fraud)                       AS fraud_txns,
    ROUND(100.0 * COUNT(*) FILTER (WHERE f.is_fraud)
          / NULLIF(COUNT(*) FILTER (WHERE f.has_fraud_label), 0), 4)
                                                             AS fraud_rate_pct
FROM bi.fact_transaction f
JOIN bi.dim_card ca USING (card_id)
GROUP BY ca.card_type
ORDER BY fraud_rate_pct DESC;


-- 2.9 Average ticket, fraud against clean. A detection signal in one
--     number: fraudulent tickets run 1.77x the size of clean ones.
SELECT
    ROUND(AVG(abs_amount) FILTER (WHERE is_fraud), 2)        AS avg_fraud_ticket,
    ROUND(AVG(abs_amount) FILTER (WHERE has_fraud_label
                                    AND NOT is_fraud), 2)    AS avg_clean_ticket,
    ROUND(AVG(abs_amount) FILTER (WHERE is_fraud)
          / AVG(abs_amount) FILTER (WHERE has_fraud_label
                                      AND NOT is_fraud), 2)  AS ratio
FROM bi.fact_transaction;


-- =====================================================================
-- PILLAR 3 - PORTFOLIO RISK: which customers carry the leakage
-- =====================================================================

-- 3.1 Credit band against both leakage measures.
SELECT
    cl.credit_band,
    COUNT(DISTINCT cl.client_id)                AS clients,
    COUNT(*)                                    AS transactions,
    ROUND(SUM(f.abs_amount))                    AS spend_usd,
    ROUND(100.0 * COUNT(*) FILTER (WHERE f.is_failed) / COUNT(*), 3)
                                                AS failure_rate_pct,
    ROUND(100.0 * COUNT(*) FILTER (WHERE f.is_fraud)
          / NULLIF(COUNT(*) FILTER (WHERE f.has_fraud_label), 0), 4)
                                                AS fraud_rate_pct
FROM bi.fact_transaction f
JOIN bi.dim_client cl USING (client_id)
GROUP BY cl.credit_band, cl.credit_band_order
ORDER BY cl.credit_band_order;


-- 3.2 Debt-to-income against the decline rate. The expectation is that
--     Insufficient Balance rises with leverage; this is where it is
--     checked rather than assumed.
SELECT
    cl.dti_band,
    COUNT(DISTINCT cl.client_id)                AS clients,
    ROUND(100.0 * COUNT(*) FILTER (WHERE f.is_failed) / COUNT(*), 3)
                                                AS failure_rate_pct,
    ROUND(100.0 * COUNT(*) FILTER (WHERE b.error_key = 1) / COUNT(*), 3)
                                                AS insufficient_balance_pct
FROM bi.fact_transaction f
JOIN bi.dim_client cl USING (client_id)
LEFT JOIN bi.br_transaction_error b
       ON b.transaction_id = f.transaction_id AND b.error_key = 1
GROUP BY cl.dti_band, cl.dti_band_order
ORDER BY cl.dti_band_order;


-- 3.3 Utilisation: annual spend against the card's credit limit.
--     Credit cards only. card_type has three values, not two, and an
--     earlier `<> 'Debit'` here silently kept 'Debit (Prepaid)': 578
--     prepaid cards averaging a $64 limit against 226 real credit cards
--     in the same band, which is a loaded balance, not a credit line.
SELECT
    ca.limit_band,
    COUNT(DISTINCT ca.card_id)                  AS cards,
    ROUND(SUM(f.abs_amount))                    AS spend_usd,
    ROUND(AVG(ca.credit_limit))                 AS avg_limit,
    ROUND(100.0 * COUNT(*) FILTER (WHERE f.is_failed) / COUNT(*), 3)
                                                AS failure_rate_pct
FROM bi.fact_transaction f
JOIN bi.dim_card ca USING (card_id)
WHERE ca.card_type = 'Credit'
GROUP BY ca.limit_band, ca.limit_band_order
ORDER BY ca.limit_band_order;


-- 3.4 Card brand and type.
SELECT
    ca.card_brand, ca.card_type, ca.has_chip,
    COUNT(*)                                    AS transactions,
    ROUND(100.0 * COUNT(*) FILTER (WHERE f.is_failed) / COUNT(*), 3)
                                                AS failure_rate_pct,
    ROUND(100.0 * COUNT(*) FILTER (WHERE f.is_fraud)
          / NULLIF(COUNT(*) FILTER (WHERE f.has_fraud_label), 0), 4)
                                                AS fraud_rate_pct
FROM bi.fact_transaction f
JOIN bi.dim_card ca USING (card_id)
GROUP BY ca.card_brand, ca.card_type, ca.has_chip
ORDER BY transactions DESC;


-- =====================================================================
-- SECTION 4 - IS THE SOURCE CONSISTENT ACROSS THE FILE?
--
-- Runs on dw (2010-2019), not bi. This started as a test of the October
-- 2015 US EMV liability shift, when responsibility for card-present
-- counterfeit fraud moved to whichever party had not adopted chip. The
-- expected pattern is a gradual swipe-to-chip migration and fraud
-- pushed toward online, where a chip cannot help.
--
-- Neither shows up. 4.1 returns a one-year cliff rather than a
-- migration, and 4.4 shows the fraud labels changing character
-- completely at 2017. Both are properties of how this dataset was
-- generated, not of card fraud. The queries are kept because the
-- conclusion they support -- what this data cannot be used to claim --
-- is a result, and because the 2017 break lands inside the reporting
-- window and has to be disclosed with it.
-- =====================================================================

-- 4.1 Channel mix by year. Real EMV adoption took several years. Here
--     swipe goes 88.2% -> 16.9% and chip 0% -> 70.8% between 2014 and
--     2015: a switch being thrown, not an industry migrating.
SELECT
    d.year,
    ROUND(100.0 * COUNT(*) FILTER (WHERE c.channel_name = 'Swipe')  / COUNT(*), 1) AS swipe_pct,
    ROUND(100.0 * COUNT(*) FILTER (WHERE c.channel_name = 'Chip')   / COUNT(*), 1) AS chip_pct,
    ROUND(100.0 * COUNT(*) FILTER (WHERE c.channel_name = 'Online') / COUNT(*), 1) AS online_pct,
    COUNT(*) AS transactions
FROM dw.fact_transaction f
JOIN dw.dim_date d USING (date_key)
JOIN dw.dim_channel c USING (channel_key)
GROUP BY d.year
ORDER BY d.year;


-- 4.2 Fraud rate by channel, before and after October 2015.
SELECT
    CASE WHEN f.date_key < 20151001 THEN 'Before Oct 2015'
         ELSE 'After Oct 2015' END              AS era,
    c.channel_name,
    COUNT(*) FILTER (WHERE f.has_fraud_label)   AS labelled,
    ROUND(100.0 * COUNT(*) FILTER (WHERE f.is_fraud)
          / NULLIF(COUNT(*) FILTER (WHERE f.has_fraud_label), 0), 4)
                                                AS fraud_rate_pct,
    ROUND(SUM(f.abs_amount) FILTER (WHERE f.is_fraud)) AS fraud_loss_usd
FROM dw.fact_transaction f
JOIN dw.dim_channel c USING (channel_key)
GROUP BY 1, c.channel_name
ORDER BY c.channel_name, 1 DESC;


-- 4.3 Share of all fraud losses carried by the online channel, by year.
SELECT
    d.year,
    ROUND(100.0 * SUM(f.abs_amount) FILTER (WHERE f.is_fraud AND f.is_online)
          / NULLIF(SUM(f.abs_amount) FILTER (WHERE f.is_fraud), 0), 1)
                                                AS online_share_of_fraud_loss_pct,
    ROUND(SUM(f.abs_amount) FILTER (WHERE f.is_fraud)) AS total_fraud_loss_usd
FROM dw.fact_transaction f
JOIN dw.dim_date d USING (date_key)
GROUP BY d.year
ORDER BY d.year;


-- 4.4 The break, stated plainly. Through 2016 fraud is 85-90% online.
--     In 2017 and 2019 online fraud is exactly zero, and the annual rate
--     swings 70-fold across the file (0.0043% in 2011, 0.3094% in 2010).
--     No card portfolio behaves this way; the labels were generated
--     under one rule up to 2016 and a different one afterwards.
--
--     Consequence for the dashboard: the 2017-2019 window sits entirely
--     inside the second regime. Fraud figures there describe a period
--     with no online fraud at all, so channel comparisons of fraud are
--     not reportable. Ticket-size and concentration patterns are
--     internally consistent within the window and are.
SELECT
    d.year,
    COUNT(*) FILTER (WHERE f.has_fraud_label)   AS labelled,
    COUNT(*) FILTER (WHERE f.is_fraud)          AS fraud_txns,
    ROUND(100.0 * COUNT(*) FILTER (WHERE f.is_fraud)
          / NULLIF(COUNT(*) FILTER (WHERE f.has_fraud_label), 0), 4)
                                                AS fraud_rate_pct,
    COUNT(*) FILTER (WHERE f.is_fraud AND f.is_online)     AS fraud_online,
    COUNT(*) FILTER (WHERE f.is_fraud AND NOT f.is_online) AS fraud_card_present,
    ROUND(SUM(f.abs_amount) FILTER (WHERE f.is_fraud))     AS fraud_loss_usd
FROM dw.fact_transaction f
JOIN dw.dim_date d USING (date_key)
GROUP BY d.year
ORDER BY d.year;


-- 1.7c The cleanest statement of the same thing: three categories record
--      not one stale-credential decline across 1.4 million transactions.
--      Zero, not "few" -- which is what a category that never holds a
--      card on file should look like.
SELECT
    m.spend_category,
    COUNT(*) AS transactions,
    COUNT(*) FILTER (WHERE EXISTS (
        SELECT 1 FROM bi.br_transaction_error b
        JOIN bi.dim_error e USING (error_key)
        WHERE b.transaction_id = f.transaction_id
          AND e.error_name IN ('Bad Card Number', 'Bad CVV', 'Bad Expiration')
    )) AS stale_credential
FROM bi.fact_transaction f
JOIN bi.dim_mcc m USING (mcc)
GROUP BY m.spend_category
ORDER BY stale_credential, transactions DESC;
