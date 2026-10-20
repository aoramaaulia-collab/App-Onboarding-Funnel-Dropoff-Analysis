-- ============================================================
-- 02_SILVER: data bersih dan keanggotaan tahap
-- Dibuat sebagai VIEW, jadi selalu dihitung ulang dari bronze.
-- ============================================================

-- clean_events: tiga tahap pembuangan
--   (1) baris kembar: kelompok atas KELIMA kolom isi, wakil MIN(event_id)
--   (2) nama peristiwa NULL atau untai kosong
--   (3) stempel waktu sesudah akhir periode data (31 Maret 2026), bukan sesudah waktu kueri
CREATE OR REPLACE VIEW silver.clean_events AS
SELECT
    MIN(event_id)  AS event_id,
    user_id,
    event_name,
    event_timestamp,
    platform,
    city
FROM bronze.user_events
WHERE event_name IS NOT NULL
  AND TRIM(event_name) <> ''
  AND event_timestamp <= TIMESTAMP '2026-03-31 23:59:59'
GROUP BY user_id, event_name, event_timestamp, platform, city;

-- stage_assignment: urutan tahap dari pengetahuan produk, tanpa ELSE
CREATE OR REPLACE VIEW silver.stage_assignment AS
SELECT
    user_id,
    event_name,
    event_timestamp,
    platform,
    city,
    CAST(CASE
        WHEN event_name = 'Visit'       THEN 1
        WHEN event_name = 'SignUp'      THEN 2
        WHEN event_name = 'VerifyPhone' THEN 3
        WHEN event_name = 'FirstOrder'  THEN 4
        WHEN event_name = 'SecondOrder' THEN 5
    END AS SMALLINT) AS stage_number
FROM silver.clean_events;

-- user_stages: satu baris per pengguna per tahap, pada peristiwa PERTAMA-nya.
-- Platform dan kota diambil dari baris yang sama (padanan argMin di ClickHouse).
CREATE OR REPLACE VIEW silver.user_stages AS
SELECT
    user_id,
    stage_number,
    event_name,
    MIN(event_timestamp)                                     AS first_event_at,
    (ARRAY_AGG(platform ORDER BY event_timestamp))[1]        AS platform,
    (ARRAY_AGG(city     ORDER BY event_timestamp))[1]        AS city
FROM silver.stage_assignment
WHERE stage_number IS NOT NULL
GROUP BY user_id, stage_number, event_name;

-- ============================================================
-- GERBANG SILVER (bukti): semua baris harus berstatus 'cocok'.
-- Karena ini pernyataan terakhir, hasilnya langsung tampil di Data Output saat F5.
-- Simpan tangkapan layarnya sebagai bukti di folder bukti/.
-- ============================================================
WITH aktual AS (
    SELECT 1 AS urut, 'baris bronze' AS ukuran, (SELECT COUNT(*) FROM bronze.user_events) AS nilai, 80000 AS harapan
    UNION ALL SELECT 2, 'pengguna bronze',                    (SELECT COUNT(DISTINCT user_id) FROM bronze.user_events), 20000
    UNION ALL SELECT 3, 'baris bersih (clean_events)',        (SELECT COUNT(*) FROM silver.clean_events), 76204
    UNION ALL SELECT 4, 'pengguna bersih (clean_events)',     (SELECT COUNT(DISTINCT user_id) FROM silver.clean_events), 20000
    UNION ALL SELECT 5, 'baris tahap funnel (stage_assignment)',
              (SELECT COUNT(*) FROM silver.stage_assignment WHERE stage_number IS NOT NULL), 52582
    UNION ALL SELECT 6, 'keanggotaan tahap (user_stages)',    (SELECT COUNT(*) FROM silver.user_stages), 52582
    UNION ALL SELECT 7, 'pengguna funnel (user_stages)',      (SELECT COUNT(DISTINCT user_id) FROM silver.user_stages), 19994
    UNION ALL SELECT 8, 'pengguna dengan dua baris di tahap yang sama',
              (SELECT COUNT(*) FROM (SELECT user_id, stage_number FROM silver.user_stages
                                     GROUP BY user_id, stage_number HAVING COUNT(*) > 1) x), 0
)
SELECT ukuran, nilai, harapan,
       CASE WHEN nilai = harapan THEN 'cocok' ELSE 'TIDAK COCOK' END AS status
FROM aktual
ORDER BY urut;

-- Untuk melihat isi view dengan mata, blok salah satu kueri di bawah lalu tekan F5:
-- SELECT * FROM silver.stage_assignment ORDER BY user_id, event_timestamp LIMIT 15;
-- SELECT * FROM silver.user_stages ORDER BY user_id, stage_number LIMIT 15;
