-- ============================================================
-- 03_GOLD: tabel siap analisis, dibaca notebook Python
-- Empat view pertama mengikuti kontrak keluaran modul (halaman 09).
-- Tiga view terakhir menyimpan data per pengguna, sehingga bisa dipotong per platform,
-- kota, dan bulan tanpa kehilangan penyebut yang benar.
-- ============================================================

-- funnel_counts: cacah PENGGUNA unik per tahap
CREATE OR REPLACE VIEW gold.funnel_counts AS
SELECT
    stage_number,
    event_name,
    COUNT(DISTINCT user_id) AS users
FROM silver.user_stages
GROUP BY stage_number, event_name;

-- conversion_rates: penyebut tahap TEPAT sebelumnya; tahap pertama NULL, bukan nol
CREATE OR REPLACE VIEW gold.conversion_rates AS
SELECT
    stage_number,
    event_name,
    users,
    LAG(users) OVER (ORDER BY stage_number) AS prev_users,
    ROUND(users * 100.0 / LAG(users) OVER (ORDER BY stage_number), 2)          AS conversion_rate,
    ROUND(100.0 - users * 100.0 / LAG(users) OVER (ORDER BY stage_number), 2)  AS drop_off_rate
FROM gold.funnel_counts;

-- platform_split: satu baris per platform per tahap
CREATE OR REPLACE VIEW gold.platform_split AS
SELECT
    platform,
    stage_number,
    event_name,
    COUNT(DISTINCT user_id) AS users
FROM silver.user_stages
GROUP BY platform, stage_number, event_name;

-- time_between: jarak hari ke tahap berikutnya milik pengguna yang sama.
-- (tanggal - tanggal) di PostgreSQL menghitung batas hari yang dilewati,
-- sama dengan dateDiff('day', ...) di ClickHouse. Nilai negatif tidak dibuang.
CREATE OR REPLACE VIEW gold.time_between AS
SELECT
    user_id,
    stage_number,
    event_name,
    first_event_at,
    LEAD(stage_number)   OVER w AS next_stage,
    LEAD(first_event_at) OVER w AS next_event_at,
    (LEAD(first_event_at) OVER w)::date - first_event_at::date AS days_to_next
FROM silver.user_stages
WINDOW w AS (PARTITION BY user_id ORDER BY stage_number);

-- ---------- data per pengguna, untuk dipotong-potong di Python ----------

-- dim_tahap: daftar lima tahap beserta nama langkah menuju tahap itu
CREATE OR REPLACE VIEW gold.dim_tahap AS
SELECT * FROM (VALUES
    (1::SMALLINT, 'Visit',       NULL),
    (2::SMALLINT, 'SignUp',      'Visit → SignUp'),
    (3::SMALLINT, 'VerifyPhone', 'SignUp → VerifyPhone'),
    (4::SMALLINT, 'FirstOrder',  'VerifyPhone → FirstOrder'),
    (5::SMALLINT, 'SecondOrder', 'FirstOrder → SecondOrder')
) AS t(stage_number, tahap, langkah_menuju_tahap_ini);

-- fact_keanggotaan: satu baris per pengguna per tahap, dengan bulan dan penanda keanggotaan meloncat
CREATE OR REPLACE VIEW gold.fact_keanggotaan AS
SELECT
    a.user_id,
    a.stage_number,
    a.event_name                               AS tahap,
    a.first_event_at,
    DATE_TRUNC('month', a.first_event_at)::date AS bulan,
    a.platform,
    a.city,
    (a.stage_number > 1 AND b.user_id IS NULL) AS meloncat
FROM silver.user_stages a
LEFT JOIN silver.user_stages b
       ON b.user_id = a.user_id
      AND b.stage_number = a.stage_number - 1;

-- fact_transisi: satu baris per pengguna per langkah yang dimulainya.
-- Penyebut: pengguna yang mencapai tahap asal; lanjut = 1 kalau juga mencapai tahap berikutnya.
-- Ini definisi per pengguna, yang dipakai untuk uji dengan kelompok pembanding.
CREATE OR REPLACE VIEW gold.fact_transisi AS
SELECT
    a.user_id,
    a.stage_number                              AS dari_tahap,
    d.langkah_menuju_tahap_ini                  AS langkah,
    DATE_TRUNC('month', a.first_event_at)::date AS bulan_masuk,
    a.platform,
    a.city,
    CASE WHEN b.user_id IS NULL THEN 0 ELSE 1 END AS lanjut,
    b.first_event_at::date - a.first_event_at::date AS hari_ke_tahap_berikutnya
FROM silver.user_stages a
JOIN gold.dim_tahap d
  ON d.stage_number = a.stage_number + 1
LEFT JOIN silver.user_stages b
       ON b.user_id = a.user_id
      AND b.stage_number = a.stage_number + 1
WHERE a.stage_number < 5;

-- ============================================================
-- GERBANG GOLD (bukti): semua baris harus berstatus 'cocok'.
-- Hasilnya langsung tampil di Data Output saat F5.
-- ============================================================
WITH aktual AS (
    SELECT 1 AS urut, 'pengguna tahap 1 Visit' AS ukuran, (SELECT users FROM gold.funnel_counts WHERE stage_number = 1)::numeric AS nilai, 19946::numeric AS harapan
    UNION ALL SELECT 2,  'pengguna tahap 2 SignUp',       (SELECT users FROM gold.funnel_counts WHERE stage_number = 2), 14874
    UNION ALL SELECT 3,  'pengguna tahap 3 VerifyPhone',  (SELECT users FROM gold.funnel_counts WHERE stage_number = 3), 8144
    UNION ALL SELECT 4,  'pengguna tahap 4 FirstOrder',   (SELECT users FROM gold.funnel_counts WHERE stage_number = 4), 5652
    UNION ALL SELECT 5,  'pengguna tahap 5 SecondOrder',  (SELECT users FROM gold.funnel_counts WHERE stage_number = 5), 3966
    UNION ALL SELECT 6,  'konversi SignUp ke VerifyPhone (%)', (SELECT conversion_rate FROM gold.conversion_rates WHERE stage_number = 3), 54.75
    UNION ALL SELECT 7,  'berhenti di verifikasi (%)',    (SELECT drop_off_rate FROM gold.conversion_rates WHERE stage_number = 3), 45.25
    UNION ALL SELECT 8,  'tahap yang jumlah platformnya tidak sama dengan total',
              (SELECT COUNT(*) FROM (SELECT f.stage_number FROM gold.funnel_counts f JOIN gold.platform_split p USING (stage_number)
                                     GROUP BY f.stage_number, f.users HAVING f.users <> SUM(p.users)) x), 0
    UNION ALL SELECT 9,  'transisi bertetangga diperiksa', (SELECT COUNT(*) FROM gold.time_between WHERE next_stage = stage_number + 1), 32477
    UNION ALL SELECT 10, 'transisi bertetangga mundur',   (SELECT COUNT(*) FROM gold.time_between WHERE next_stage = stage_number + 1 AND days_to_next < 0), 35
    UNION ALL SELECT 11, 'keanggotaan meloncat',          (SELECT COUNT(*) FROM gold.fact_keanggotaan WHERE meloncat), 159
    UNION ALL SELECT 12, 'pendaftar tak pernah verifikasi', (SELECT COUNT(*) FROM gold.fact_transisi WHERE dari_tahap = 2 AND lanjut = 0), 6787
)
SELECT ukuran, nilai, harapan,
       CASE WHEN nilai = harapan THEN 'cocok' ELSE 'TIDAK COCOK' END AS status
FROM aktual
ORDER BY urut;
