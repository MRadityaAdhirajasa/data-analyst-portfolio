-- A. mart.hospital_access  (grain: 1 baris = 1 rumah sakit)

DROP TABLE IF EXISTS mart.hospital_access;

CREATE TABLE mart.hospital_access AS
WITH base AS (
    SELECT *
    FROM staging.hospitals
    WHERE status = 'OPEN'
      AND is_us_state
),
trauma_centers AS (
    SELECT hospital_id, hospital_name, state, latitude, longitude
    FROM base
    WHERE trauma_adult_level <= 2
)
SELECT
    b.hospital_id,
    b.hospital_name,
    b.hospital_type,
    b.owner_group,
    b.owner_type,
    b.address,
    b.city,
    b.state,
    b.county,
    b.county_fips,
    b.latitude,
    b.longitude,
    b.beds,
    b.units_at_site,
    b.has_helipad,
    b.trauma_category,
    b.trauma_adult_level,
    COALESCE(b.trauma_adult_level <= 2, false)   AS is_level12_trauma,
    n.hospital_id                                AS nearest_trauma_id,
    n.hospital_name                              AS nearest_trauma_name,
    n.state                                      AS nearest_trauma_state,
    ROUND(n.distance_km::numeric, 1)             AS distance_km,
    CASE
        WHEN n.distance_km <  25  THEN '< 25 km'
        WHEN n.distance_km <  50  THEN '25-50 km'
        WHEN n.distance_km < 100  THEN '50-100 km'
        WHEN n.distance_km < 200  THEN '100-200 km'
        ELSE                           '> 200 km'
    END                                          AS distance_band,
    CASE
        WHEN n.distance_km <  25  THEN 1
        WHEN n.distance_km <  50  THEN 2
        WHEN n.distance_km < 100  THEN 3
        WHEN n.distance_km < 200  THEN 4
        ELSE                           5
    END                                          AS distance_band_order
FROM base b
CROSS JOIN LATERAL (
    -- untuk tiap RS, cari 1 trauma center dengan jarak terkecil
    SELECT
        t.hospital_id,
        t.hospital_name,
        t.state,
        2 * 6371 * ASIN(SQRT(LEAST(1,
            POWER(SIN(RADIANS(t.latitude  - b.latitude)  / 2), 2)
          + COS(RADIANS(b.latitude)) * COS(RADIANS(t.latitude))
          * POWER(SIN(RADIANS(t.longitude - b.longitude) / 2), 2)
        ))) AS distance_km
    FROM trauma_centers t
    ORDER BY distance_km, t.hospital_id
    LIMIT 1
) n;



-- B. mart.state_summary  (grain: 1 baris = 1 negara bagian)

DROP TABLE IF EXISTS mart.state_summary;

CREATE TABLE mart.state_summary AS
SELECT
    state,
    COUNT(*)                                                    AS n_hospitals,
    COUNT(DISTINCT (hospital_name, address, city))              AS n_sites,
    SUM(beds)                                                   AS total_beds,
    ROUND(COUNT(beds)::numeric / COUNT(*), 4)                   AS pct_beds_reported,
    COUNT(*) FILTER (WHERE is_level12_trauma)                   AS n_level12_trauma,
    COUNT(*) FILTER (WHERE hospital_type = 'CRITICAL ACCESS')   AS n_critical_access,
    ROUND(COUNT(*) FILTER (WHERE hospital_type = 'CRITICAL ACCESS')::numeric
          / COUNT(*), 4)                                        AS pct_critical_access,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY distance_km)::numeric, 1)
                                                                AS median_distance_km,
    MAX(distance_km)                                            AS max_distance_km,
    COUNT(*) FILTER (WHERE distance_km > 100)                   AS n_over_100km,
    ROUND(COUNT(*) FILTER (WHERE distance_km > 100)::numeric
          / COUNT(*), 4)                                        AS pct_over_100km,
    ROUND(COUNT(*) FILTER (WHERE trauma_category <> 'NOT REPORTED')::numeric
          / COUNT(*), 4)                                        AS trauma_reporting_rate,
    CASE
        WHEN COUNT(*) FILTER (WHERE trauma_category <> 'NOT REPORTED')::numeric
             / COUNT(*) < 0.10 THEN 'LOW'
        ELSE 'OK'
    END                                                         AS trauma_reporting_flag
FROM mart.hospital_access
GROUP BY state;

-- C. Verifikasi

-- C1
SELECT
    (SELECT COUNT(*) FROM staging.hospitals
      WHERE status = 'OPEN' AND is_us_state)     AS expected_rows,
    (SELECT COUNT(*) FROM mart.hospital_access)  AS actual_rows;

-- C2
SELECT
    COUNT(*) FILTER (WHERE distance_km IS NULL)                     AS distance_null,
    COUNT(*) FILTER (WHERE is_level12_trauma AND distance_km <> 0)  AS trauma_center_not_zero,
    COUNT(*) FILTER (WHERE distance_km < 0)                         AS distance_negative
FROM mart.hospital_access;

-- C3
SELECT
    SUM(n_hospitals)  AS total_hospitals,
    COUNT(*)          AS n_states
FROM mart.state_summary;

-- C4
SELECT hospital_name, city, state, hospital_type,
       nearest_trauma_name, nearest_trauma_state, distance_km
FROM mart.hospital_access
ORDER BY distance_km DESC
LIMIT 10;

-- C5
SELECT
    hospital_type,
    COUNT(*)                                                  AS n,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY distance_km)::numeric, 1)
                                                              AS median_km,
    COUNT(*) FILTER (WHERE distance_km > 100)                 AS n_over_100km
FROM mart.hospital_access
GROUP BY hospital_type
ORDER BY median_km DESC;
