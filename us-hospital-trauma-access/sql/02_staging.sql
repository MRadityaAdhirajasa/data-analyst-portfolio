-- A. Tabel mapping trauma

DROP TABLE IF EXISTS staging.trauma_map CASCADE;

CREATE TABLE staging.trauma_map (
    trauma_raw       text PRIMARY KEY,
    trauma_category  text     NOT NULL,
    adult_level      smallint,           -- 1 = Level I (tertinggi) ... 5 = Level V
    pediatric_level  smallint,
    has_pediatric    boolean  NOT NULL
);

INSERT INTO staging.trauma_map VALUES
    -- tidak dilaporkan 
    ('NOT AVAILABLE',                                  'NOT REPORTED',      NULL, NULL, false),
    -- skala adult standar
    ('LEVEL I',                                        'ADULT',             1,    NULL, false),
    ('LEVEL II',                                       'ADULT',             2,    NULL, false),
    ('LEVEL III',                                      'ADULT',             3,    NULL, false),
    ('LEVEL IV',                                       'ADULT',             4,    NULL, false),
    ('LEVEL V',                                        'ADULT',             5,    NULL, false),
    ('LEVEL I ADULT',                                  'ADULT',             1,    NULL, false),
    ('LEVEL II ADULT',                                 'ADULT',             2,    NULL, false),
    ('LEVEL III ADULT',                                'ADULT',             3,    NULL, false),
    -- adult + pediatric
    ('LEVEL I ADULT, LEVEL I PEDIATRIC',               'ADULT',             1,    1,    true),
    ('LEVEL I, LEVEL I PEDIATRIC',                     'ADULT',             1,    1,    true),
    ('LEVEL I ADULT, LEVEL II PEDIATRIC',              'ADULT',             1,    2,    true),
    ('LEVEL I, LEVEL II PEDIATRIC',                    'ADULT',             1,    2,    true),
    ('LEVEL II ADULT, LEVEL II PEDIATRIC',             'ADULT',             2,    2,    true),
    ('LEVEL II, LEVEL II PEDIATRIC',                   'ADULT',             2,    2,    true),
    ('LEVEL II, LEVEL III PEDIATRIC, LEVEL II REHAB',  'ADULT',             2,    3,    true),
    ('LEVEL II / PEDIATRIC',                           'ADULT',             2,    NULL, true),
    -- pediatric saja
    ('LEVEL I PEDIATRIC',                              'PEDIATRIC ONLY',    NULL, 1,    true),
    ('LEVEL II PEDIATRIC',                             'PEDIATRIC ONLY',    NULL, 2,    true),
    ('PEDIATRIC',                                      'PEDIATRIC ONLY',    NULL, NULL, true),
    -- designasi rehabilitasi trauma
    ('LEVEL I PEDIATRIC REHAB',                        'TRAUMA REHAB',      NULL, NULL, false),
    ('LEVEL II REHAB',                                 'TRAUMA REHAB',      NULL, NULL, false),
  
    ('TRH',                                            'STATE DESIGNATION', NULL, NULL, false),
    ('TRF',                                            'STATE DESIGNATION', NULL, NULL, false),
    ('CTH',                                            'STATE DESIGNATION', NULL, NULL, false),
    ('ATH',                                            'STATE DESIGNATION', 3,    NULL, false),
    ('RTC',                                            'STATE DESIGNATION', 2,    NULL, false),
    ('RTH',                                            'STATE DESIGNATION', 2,    NULL, false),
    ('I-RPTC',                                         'STATE DESIGNATION', NULL, NULL, false),
    ('PARC',                                           'STATE DESIGNATION', NULL, NULL, false),
    ('REGIONAL',                                       'STATE DESIGNATION', NULL, NULL, false);



-- B. View staging.hospitals

DROP VIEW IF EXISTS staging.hospitals;

CREATE VIEW staging.hospitals AS
SELECT
    -- identitas
    h.id                                        AS hospital_id,
    h.name                                      AS hospital_name,
    NULLIF(h.alt_name, 'NOT AVAILABLE')         AS alt_name,
    h.type                                      AS hospital_type,
    h.status,
    -- kepemilikan
    NULLIF(h.owner, 'NOT AVAILABLE')            AS owner_type,
    CASE
        WHEN h.owner LIKE 'GOVERNMENT%' THEN 'GOVERNMENT'
        WHEN h.owner = 'NOT AVAILABLE'  THEN NULL
        ELSE h.owner
    END                                         AS owner_group,
    -- lokasi 
    h.address,
    h.city,
    h.state,
    h.zip,
    h.county,
    h.countyfips                                AS county_fips,
    h.st_fips                                   AS state_fips,
    h.country,
    -- 50 negara bagian + DC
    (h.state NOT IN ('PR','GU','VI','AS','MP','PW')) AS is_us_state,
    h.latitude::numeric                         AS latitude,
    h.longitude::numeric                        AS longitude,
    -- kapasitas
    NULLIF(h.beds, '-999')::int                 AS beds,
    -- klasifikasi industri
    h.naics_code,
    h.naics_desc,
    -- fasilitas
    CASE h.helipad
        WHEN 'Y' THEN true
        WHEN 'N' THEN false
    END                                         AS has_helipad,
    -- trauma
    NULLIF(h.trauma, 'NOT AVAILABLE')           AS trauma_raw,
    tm.trauma_category,
    tm.adult_level                              AS trauma_adult_level,
    tm.pediatric_level                          AS trauma_pediatric_level,
    tm.has_pediatric                            AS has_pediatric_trauma,
    -- lain-lain
    NULLIF(h.website, 'NOT AVAILABLE')          AS website,
    to_date(left(h.sourcedate, 10), 'YYYY/MM/DD') AS source_date,

    COUNT(*) OVER (PARTITION BY h.name, h.address, h.city) AS units_at_site
FROM raw.hospitals h
LEFT JOIN staging.trauma_map tm
       ON tm.trauma_raw = h.trauma;

-- C. Verifikasi

-- C1
SELECT COUNT(*) AS total_rows FROM staging.hospitals;

-- C2
SELECT DISTINCT r.trauma
FROM raw.hospitals r
WHERE NOT EXISTS (
    SELECT 1 FROM staging.trauma_map tm WHERE tm.trauma_raw = r.trauma
);

-- C3
SELECT
    COUNT(*) FILTER (WHERE beds IS NULL)          AS beds_null,
    COUNT(*) FILTER (WHERE owner_type IS NULL)    AS owner_null,
    COUNT(*) FILTER (WHERE has_helipad IS NULL)   AS helipad_null,
    COUNT(*) FILTER (WHERE website IS NULL)       AS website_null,
    COUNT(*) FILTER (WHERE source_date IS NULL)   AS source_date_null
FROM staging.hospitals;

-- C4
SELECT trauma_category, COUNT(*) AS n
FROM staging.hospitals
GROUP BY trauma_category
ORDER BY n DESC;