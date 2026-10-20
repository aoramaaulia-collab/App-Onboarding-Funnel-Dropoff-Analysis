-- ============================================================
-- 04_VALIDASI: gerbang angka dan lima pemeriksaan modul
-- Jalankan sesudah 01-03 dengan F5. pgAdmin menampilkan hasil pernyataan TERAKHIR,
-- yaitu gerbang angka di akhir berkas: kedua belas baris harus berstatus 'cocok'.
-- Untuk melihat hasil satu pemeriksaan, blok kuerinya lalu tekan F5.
-- Kalau satu saja 'TIDAK COCOK', berhenti dan telusuri lapisan sebelumnya.
-- ============================================================

-- Pemeriksaan 1: funnel menurun monoton
SELECT stage_number, event_name, users, LAG(users) OVER (ORDER BY stage_number) AS prev_users,
       CASE WHEN LAG(users) OVER (ORDER BY stage_number) IS NULL THEN 'kosong, tahap pertama'
            WHEN users > LAG(users) OVER (ORDER BY stage_number) THEN 'TIDAK LOLOS'
            ELSE 'lolos' END AS hasil
FROM gold.funnel_counts ORDER BY stage_number;

-- Pemeriksaan 2: konversi di rentang 0 sampai 100 (harapan: 74,57 / 54,75 / 69,40 / 70,17)
SELECT stage_number, event_name, conversion_rate, drop_off_rate,
       CASE WHEN conversion_rate IS NULL THEN 'kosong, tahap pertama'
            WHEN conversion_rate BETWEEN 0 AND 100 THEN 'lolos' ELSE 'TIDAK LOLOS' END AS hasil
FROM gold.conversion_rates ORDER BY stage_number;

-- Pemeriksaan 3: transisi bertetangga yang stempelnya mundur (harapan: 35 dari 32.477, 0,11%)
SELECT COUNT(*) FILTER (WHERE days_to_next < 0) AS transisi_mundur,
       COUNT(*)                                  AS transisi_diperiksa,
       ROUND(COUNT(*) FILTER (WHERE days_to_next < 0) * 100.0 / COUNT(*), 2) AS porsi_persen
FROM gold.time_between
WHERE next_stage = stage_number + 1;

-- Pemeriksaan 4: jumlah ketiga platform sama dengan total tiap tahap
SELECT f.stage_number, f.users AS total, SUM(p.users) AS jumlah_platform,
       CASE WHEN f.users = SUM(p.users) THEN 'lolos' ELSE 'TIDAK LOLOS' END AS hasil
FROM gold.funnel_counts f JOIN gold.platform_split p USING (stage_number)
GROUP BY f.stage_number, f.users ORDER BY f.stage_number;

-- Pemeriksaan 5: tiap tahap bersarang di tahap sebelumnya
-- (sengaja tidak lolos; harapan: SignUp 48, VerifyPhone 57, FirstOrder 31, SecondOrder 23)
SELECT stage_number, tahap, COUNT(*) FILTER (WHERE meloncat) AS tanpa_tahap_sebelumnya, COUNT(*) AS pengguna_di_tahap
FROM gold.fact_keanggotaan WHERE stage_number > 1
GROUP BY stage_number, tahap ORDER BY stage_number;

-- Gerbang angka: dibandingkan dengan hasil notebook
WITH aktual AS (
    SELECT 'baris bronze'            AS ukuran, (SELECT COUNT(*) FROM bronze.user_events)          AS nilai, 80000 AS harapan
    UNION ALL SELECT 'pengguna bronze',      (SELECT COUNT(DISTINCT user_id) FROM bronze.user_events),  20000
    UNION ALL SELECT 'baris silver bersih',  (SELECT COUNT(*) FROM silver.clean_events),                76204
    UNION ALL SELECT 'pengguna silver',      (SELECT COUNT(DISTINCT user_id) FROM silver.clean_events),  20000
    UNION ALL SELECT 'keanggotaan tahap',    (SELECT COUNT(*) FROM silver.user_stages),                 52582
    UNION ALL SELECT 'tahap 1 Visit',        (SELECT users FROM gold.funnel_counts WHERE stage_number = 1), 19946
    UNION ALL SELECT 'tahap 2 SignUp',       (SELECT users FROM gold.funnel_counts WHERE stage_number = 2), 14874
    UNION ALL SELECT 'tahap 3 VerifyPhone',  (SELECT users FROM gold.funnel_counts WHERE stage_number = 3),  8144
    UNION ALL SELECT 'tahap 4 FirstOrder',   (SELECT users FROM gold.funnel_counts WHERE stage_number = 4),  5652
    UNION ALL SELECT 'tahap 5 SecondOrder',  (SELECT users FROM gold.funnel_counts WHERE stage_number = 5),  3966
    UNION ALL SELECT 'keanggotaan meloncat', (SELECT COUNT(*) FROM gold.fact_keanggotaan WHERE meloncat),     159
    UNION ALL SELECT 'pendaftar tak pernah verifikasi',
              (SELECT COUNT(*) FROM gold.fact_transisi WHERE dari_tahap = 2 AND lanjut = 0),             6787
)
SELECT ukuran, nilai, harapan,
       CASE WHEN nilai = harapan THEN 'cocok' ELSE 'TIDAK COCOK' END AS status
FROM aktual;
