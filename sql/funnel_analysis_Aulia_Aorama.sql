-- ============================================================
-- FUNNEL ANALYSIS — PakaiApp
-- Analyst: Aulia Aorama
-- Date: 8 Oktober 2026
-- Stakeholder: Pak Fajar (VP of Product)
-- Decision: Identifikasi drop-off terbesar di funnel onboarding
--           untuk optimasi budget akuisisi Rp 2 miliar/bulan
-- Source: bronze.user_events di database PostgreSQL funnel_onboarding (80.000 baris)
-- Dialek: PostgreSQL 16+. Padanan fungsi ClickHouse di modul:
--   argMin(x, t)      -> (ARRAY_AGG(x ORDER BY t))[1]
--   dateDiff('day')   -> tanggal_akhir::date - tanggal_awal::date
--   uniqExactIf       -> COUNT(DISTINCT ...) FILTER (WHERE ...)
--   toDateTime('...') -> TIMESTAMP '...', count() -> COUNT(*)
--   toNullable tidak diperlukan (LAG di PostgreSQL sudah menghasilkan NULL).
-- Cara menjalankan: buka di Query Tool pgAdmin pada database funnel_onboarding
--   sesudah bronze.user_events terisi. Tidak ada angka acak; batas waktu tetap
--   31 Maret 2026, jadi hasilnya sama kapan pun dijalankan.
-- ============================================================

-- ============================================================
-- STEP 0: MEMUAT DATA KE SKEMA YANG DIRUJUK KUERI
-- ============================================================

-- Data mentah sudah dimuat apa adanya ke bronze.user_events (lihat 01_bronze.sql,
-- atau bagian Load di notebook). Semua kueri di bawah membaca tabel itu.
-- Gerbang: 80.000 baris, 20.000 pengguna.
SELECT COUNT(*) AS baris, COUNT(DISTINCT user_id) AS pengguna FROM bronze.user_events;

-- ============================================================
-- STEP 1: DATA CLEANING
-- Issues: duplicate events, NULL event_name, future timestamps
-- Gerbang: 80.000 -> 76.850 -> 76.350 -> 76.204 (lihat cleaning impact query)
-- ============================================================

WITH clean_events AS (
    -- Tiga tahap pembuangan. Filter baris (nama kosong, stempel masa depan) bisa
    -- ditaruh sebelum GROUP BY tanpa mengubah hasil akhir, karena keduanya
    -- menyaring kolom yang juga menjadi kunci kelompok. Cacah per tahap dilaporkan
    -- terpisah di cleaning impact query.
    --   (1) baris kembar: kelompok atas KELIMA kolom isi, event_id dikeluarkan dari kunci
    --   (2) event_name NULL atau untai kosong (IS NOT NULL saja tidak menangkap '')
    --   (3) stempel waktu sesudah akhir periode data, bukan sesudah waktu kueri dijalankan
    SELECT
        MIN(event_id)  AS event_id,     -- wakil kelompok dipilih dengan aturan, bukan acak
        user_id,
        event_name,
        event_timestamp,
        platform,
        city
    FROM bronze.user_events
    WHERE event_name IS NOT NULL
      AND trim(event_name) <> ''
      AND event_timestamp <= TIMESTAMP '2026-03-31 23:59:59'
    GROUP BY user_id, event_name, event_timestamp, platform, city
),

-- ============================================================
-- STEP 2: STAGE ASSIGNMENT
-- Visit=1, SignUp=2, VerifyPhone=3, FirstOrder=4, SecondOrder=5
-- ============================================================

stage_assignment AS (
    -- Urutan tahap berasal dari pengetahuan produk, bukan dari data.
    -- Tanpa ELSE: peristiwa di luar funnel mendapat stage_number NULL dan tersaring
    -- di langkah berikutnya. Kolom lain diteruskan apa adanya; lapisan ini hanya MENAMBAH.
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
    FROM clean_events
),

-- ============================================================
-- STEP 3: USER STAGES
-- Earliest timestamp per user per stage; platform dan city dari baris yang sama
-- Gerbang: 52.582 baris, satu per pengguna per tahap
-- ============================================================

user_stages AS (
    -- Satu baris per pengguna per tahap yang pernah dicapai.
    -- Pengguna dianggap mencapai tahap pada peristiwa PERTAMA-nya di tahap itu.
    -- platform dan city diambil dari baris yang sama (padanan argMin ClickHouse),
    -- bukan dari baris mana pun yang kebetulan diproses lebih dulu.
    SELECT
        user_id,
        stage_number,
        event_name,
        MIN(event_timestamp)                     AS first_event_at,
        (ARRAY_AGG(platform ORDER BY event_timestamp))[1]       AS platform,
        (ARRAY_AGG(city ORDER BY event_timestamp))[1]       AS city
    FROM stage_assignment
    WHERE stage_number IS NOT NULL
    GROUP BY user_id, stage_number, event_name
),

-- ============================================================
-- STEP 4: FUNNEL COUNTS
-- Count distinct users reaching each stage
-- Gerbang: 19.946 / 14.874 / 8.144 / 5.652 / 3.966
-- ============================================================

funnel_counts AS (
    -- Cacah PENGGUNA unik, bukan baris. Masukannya sudah satu baris per pengguna
    -- per tahap, dan COUNT(DISTINCT) dipertahankan sebagai jaring pengaman.
    SELECT
        stage_number,
        event_name,
        CAST(COUNT(DISTINCT user_id) AS BIGINT) AS users
    FROM user_stages
    GROUP BY stage_number, event_name
),

-- ============================================================
-- STEP 5: CONVERSION RATES
-- Users at step N / users at step N-1 (penyebut: tahap TEPAT sebelumnya)
-- ============================================================

conversion_rates AS (
    -- Penyebut: tahap TEPAT sebelumnya. Tahap pertama sengaja NULL, bukan nol.
    -- drop_off_rate dihitung dari nilai penuh lalu dibulatkan, bukan 100 dikurangi
    -- angka yang sudah dibulatkan.
    SELECT
        stage_number,
        event_name,
        users,
        LAG(users) OVER (ORDER BY stage_number)                                   AS prev_users,
        ROUND(users * 100.0 / LAG(users) OVER (ORDER BY stage_number), 2)          AS conversion_rate,
        ROUND(100.0 - users * 100.0 / LAG(users) OVER (ORDER BY stage_number), 2)  AS drop_off_rate
    FROM funnel_counts
),

-- ============================================================
-- STEP 6: PLATFORM SPLIT
-- Same funnel grouped by platform; satu baris per platform per tahap
-- ============================================================

platform_split AS (
    -- Satu baris per platform per tahap. Ketiga baris tiap tahap wajib berjumlah
    -- sama dengan users di funnel_counts (pemeriksaan 4).
    SELECT
        platform,
        stage_number,
        event_name,
        CAST(COUNT(DISTINCT user_id) AS BIGINT) AS users
    FROM user_stages
    GROUP BY platform, stage_number, event_name
),

-- ============================================================
-- STEP 7: TIME BETWEEN STEPS
-- Jarak hari ke tahap berikutnya milik pengguna yang sama; negatif tidak dibuang
-- ============================================================

time_between AS (
    -- Tahap berikutnya MILIK PENGGUNA YANG SAMA (PARTITION BY user_id).
    -- days_to_next bertanda: nilai negatif adalah temuan alat ukur, tidak dibuang.
    -- tanggal - tanggal menghitung batas hari yang dilewati, sama dengan dateDiff ClickHouse.
    SELECT
        user_id,
        stage_number,
        event_name,
        first_event_at,
        LEAD(stage_number)   OVER w                                        AS next_stage,
        LEAD(first_event_at) OVER w                                        AS next_event_at,
        (LEAD(first_event_at) OVER w)::date - first_event_at::date AS days_to_next
    FROM user_stages
    WINDOW w AS (PARTITION BY user_id ORDER BY stage_number)
)

-- ============================================================
-- FINAL OUTPUT
-- ============================================================

SELECT *
FROM conversion_rates
ORDER BY stage_number;

-- ============================================================
-- VIEW DENGAN NAMA DAN DEFINISI IDENTIK DENGAN KETUJUH CTE
-- CTE hanya hidup di dalam satu pernyataan. Supaya pemeriksaan di bawah bisa
-- dijalankan terpisah tanpa menyalin rantai CTE tujuh kali, definisi yang sama
-- didaftarkan sebagai VIEW. VIEW bukan salinan hasil: ia dihitung ulang dari
-- data mentah setiap kali dipanggil, jadi tidak ada salinan basi yang divalidasi.
-- ============================================================

CREATE OR REPLACE VIEW clean_events AS
    -- Tiga tahap pembuangan. Filter baris (nama kosong, stempel masa depan) bisa
    -- ditaruh sebelum GROUP BY tanpa mengubah hasil akhir, karena keduanya
    -- menyaring kolom yang juga menjadi kunci kelompok. Cacah per tahap dilaporkan
    -- terpisah di cleaning impact query.
    --   (1) baris kembar: kelompok atas KELIMA kolom isi, event_id dikeluarkan dari kunci
    --   (2) event_name NULL atau untai kosong (IS NOT NULL saja tidak menangkap '')
    --   (3) stempel waktu sesudah akhir periode data, bukan sesudah waktu kueri dijalankan
    SELECT
        MIN(event_id)  AS event_id,     -- wakil kelompok dipilih dengan aturan, bukan acak
        user_id,
        event_name,
        event_timestamp,
        platform,
        city
    FROM bronze.user_events
    WHERE event_name IS NOT NULL
      AND trim(event_name) <> ''
      AND event_timestamp <= TIMESTAMP '2026-03-31 23:59:59'
    GROUP BY user_id, event_name, event_timestamp, platform, city;

CREATE OR REPLACE VIEW stage_assignment AS
    -- Urutan tahap berasal dari pengetahuan produk, bukan dari data.
    -- Tanpa ELSE: peristiwa di luar funnel mendapat stage_number NULL dan tersaring
    -- di langkah berikutnya. Kolom lain diteruskan apa adanya; lapisan ini hanya MENAMBAH.
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
    FROM clean_events;

CREATE OR REPLACE VIEW user_stages AS
    -- Satu baris per pengguna per tahap yang pernah dicapai.
    -- Pengguna dianggap mencapai tahap pada peristiwa PERTAMA-nya di tahap itu.
    -- platform dan city diambil dari baris yang sama (padanan argMin ClickHouse),
    -- bukan dari baris mana pun yang kebetulan diproses lebih dulu.
    SELECT
        user_id,
        stage_number,
        event_name,
        MIN(event_timestamp)                     AS first_event_at,
        (ARRAY_AGG(platform ORDER BY event_timestamp))[1]       AS platform,
        (ARRAY_AGG(city ORDER BY event_timestamp))[1]       AS city
    FROM stage_assignment
    WHERE stage_number IS NOT NULL
    GROUP BY user_id, stage_number, event_name;

CREATE OR REPLACE VIEW funnel_counts AS
    -- Cacah PENGGUNA unik, bukan baris. Masukannya sudah satu baris per pengguna
    -- per tahap, dan COUNT(DISTINCT) dipertahankan sebagai jaring pengaman.
    SELECT
        stage_number,
        event_name,
        CAST(COUNT(DISTINCT user_id) AS BIGINT) AS users
    FROM user_stages
    GROUP BY stage_number, event_name;

CREATE OR REPLACE VIEW conversion_rates AS
    -- Penyebut: tahap TEPAT sebelumnya. Tahap pertama sengaja NULL, bukan nol.
    -- drop_off_rate dihitung dari nilai penuh lalu dibulatkan, bukan 100 dikurangi
    -- angka yang sudah dibulatkan.
    SELECT
        stage_number,
        event_name,
        users,
        LAG(users) OVER (ORDER BY stage_number)                                   AS prev_users,
        ROUND(users * 100.0 / LAG(users) OVER (ORDER BY stage_number), 2)          AS conversion_rate,
        ROUND(100.0 - users * 100.0 / LAG(users) OVER (ORDER BY stage_number), 2)  AS drop_off_rate
    FROM funnel_counts;

CREATE OR REPLACE VIEW platform_split AS
    -- Satu baris per platform per tahap. Ketiga baris tiap tahap wajib berjumlah
    -- sama dengan users di funnel_counts (pemeriksaan 4).
    SELECT
        platform,
        stage_number,
        event_name,
        CAST(COUNT(DISTINCT user_id) AS BIGINT) AS users
    FROM user_stages
    GROUP BY platform, stage_number, event_name;

CREATE OR REPLACE VIEW time_between AS
    -- Tahap berikutnya MILIK PENGGUNA YANG SAMA (PARTITION BY user_id).
    -- days_to_next bertanda: nilai negatif adalah temuan alat ukur, tidak dibuang.
    -- tanggal - tanggal menghitung batas hari yang dilewati, sama dengan dateDiff ClickHouse.
    SELECT
        user_id,
        stage_number,
        event_name,
        first_event_at,
        LEAD(stage_number)   OVER w                                        AS next_stage,
        LEAD(first_event_at) OVER w                                        AS next_event_at,
        (LEAD(first_event_at) OVER w)::date - first_event_at::date AS days_to_next
    FROM user_stages
    WINDOW w AS (PARTITION BY user_id ORDER BY stage_number);

-- ============================================================
-- CLEANING IMPACT QUERY (statement terpisah)
-- Porsi tiap tahap dihitung terhadap DATA MENTAH, supaya bisa dijumlahkan.
-- Hasil: 80.000 / 76.850 / 3.150 / 500 / 146 / 76.204 / 4,75%; pengguna 20.000 -> 20.000
-- ============================================================

WITH raw_events AS (
    SELECT * FROM bronze.user_events
),
deduped AS (
    SELECT MIN(event_id) AS event_id, user_id, event_name, event_timestamp, platform, city
    FROM raw_events
    GROUP BY user_id, event_name, event_timestamp, platform, city
),
valid_named_events AS (
    SELECT * FROM deduped
    WHERE event_name IS NOT NULL AND trim(event_name) <> ''
),
clean_events AS (
    SELECT * FROM valid_named_events
    WHERE event_timestamp <= TIMESTAMP '2026-03-31 23:59:59'
)
SELECT
    (SELECT COUNT(*) FROM raw_events)                                              AS raw_rows,
    (SELECT COUNT(*) FROM deduped)                                                 AS rows_after_dedup,
    (SELECT COUNT(*) FROM raw_events) - (SELECT COUNT(*) FROM deduped)             AS duplicate_rows_removed,
    (SELECT COUNT(*) FROM deduped) - (SELECT COUNT(*) FROM valid_named_events)     AS null_or_blank_rows_removed,
    (SELECT COUNT(*) FROM valid_named_events) - (SELECT COUNT(*) FROM clean_events) AS future_rows_removed,
    (SELECT COUNT(*) FROM clean_events)                                            AS clean_rows,
    ROUND(100.0 * ((SELECT COUNT(*) FROM raw_events) - (SELECT COUNT(*) FROM clean_events))
          / (SELECT COUNT(*) FROM raw_events), 2)                                  AS pct_rows_removed,
    (SELECT COUNT(DISTINCT user_id) FROM raw_events)                                AS raw_users,
    (SELECT COUNT(DISTINCT user_id) FROM clean_events)                              AS clean_users;

-- Rincian per tahap pembuangan (berkas 1): baris dibuang, porsi terhadap mentah, sisa
WITH raw_events AS (SELECT * FROM bronze.user_events),
deduped AS (
    SELECT MIN(event_id) AS event_id, user_id, event_name, event_timestamp, platform, city
    FROM raw_events GROUP BY user_id, event_name, event_timestamp, platform, city),
valid_named_events AS (SELECT * FROM deduped WHERE event_name IS NOT NULL AND trim(event_name) <> ''),
clean_events AS (SELECT * FROM valid_named_events WHERE event_timestamp <= TIMESTAMP '2026-03-31 23:59:59'),
n AS (
    SELECT (SELECT COUNT(*) FROM raw_events)         AS n0,
           (SELECT COUNT(*) FROM deduped)            AS n1,
           (SELECT COUNT(*) FROM valid_named_events) AS n2,
           (SELECT COUNT(*) FROM clean_events)       AS n3)
SELECT 0 AS urutan, 'baris mentah' AS tahap, NULL AS baris_dibuang, NULL AS porsi_dari_mentah, n0 AS sisa FROM n
UNION ALL SELECT 1, 'baris kembar persis',      n0 - n1, ROUND((n0 - n1) * 100.0 / n0, 2), n1 FROM n
UNION ALL SELECT 2, 'nama peristiwa kosong',    n1 - n2, ROUND((n1 - n2) * 100.0 / n0, 2), n2 FROM n
UNION ALL SELECT 3, 'stempel waktu masa depan', n2 - n3, ROUND((n2 - n3) * 100.0 / n0, 2), n3 FROM n
UNION ALL SELECT 4, 'total dibuang',            n0 - n3, ROUND((n0 - n3) * 100.0 / n0, 2), n3 FROM n
ORDER BY urutan;

-- Pemeriksaan nama peristiwa, dibaca dengan mata
-- Daftar seluruh nama peristiwa unik beserta cacahnya, dibaca dengan mata:
-- yang dicari dua baris yang tampak seperti hal yang sama (mis. VerifyPhone / Verify_Phone).
SELECT event_name, COUNT(*) AS event_rows
FROM bronze.user_events
GROUP BY event_name
ORDER BY event_rows DESC;

-- ============================================================
-- VALIDATION QUERIES (jalankan terpisah)
-- Urutan: bentuk dulu (1, 2), baru mutu (3, 4, 5).
-- Hasil di data ini: 1 lolos, 2 lolos, 3 tercatat (35 dari 32.477), 4 lolos, 5 tidak lolos (159).
-- ============================================================

-- Pemeriksaan 1: funnel menurun monoton (perbandingan, bukan pengurangan)
SELECT
    stage_number,
    event_name,
    users,
    LAG(users) OVER (ORDER BY stage_number) AS prev_users,
    CASE
        WHEN LAG(users) OVER (ORDER BY stage_number) IS NULL THEN 'kosong, tahap pertama'
        WHEN users > LAG(users) OVER (ORDER BY stage_number) THEN 'TIDAK LOLOS, tidak monoton'
        ELSE 'lolos'
    END AS hasil
FROM funnel_counts
ORDER BY stage_number;

-- Pemeriksaan 2: konversi di rentang 0 sampai 100
SELECT
    stage_number,
    event_name,
    conversion_rate,
    CASE
        WHEN conversion_rate > 100   THEN 'TIDAK LOLOS, di atas 100'
        WHEN conversion_rate < 0     THEN 'TIDAK LOLOS, negatif'
        WHEN conversion_rate IS NULL THEN 'kosong, tahap pertama'
        ELSE 'lolos'
    END AS hasil
FROM conversion_rates
ORDER BY stage_number;

-- Pemeriksaan 3: transisi BERTETANGGA yang stempelnya mundur.
-- Penyebut: transisi bertetangga (next_stage = stage_number + 1), bukan pengguna, bukan baris.
SELECT
    COUNT(*) FILTER (WHERE days_to_next < 0)                         AS transisi_mundur,
    COUNT(*)                                                         AS transisi_diperiksa,
    ROUND(COUNT(*) FILTER (WHERE days_to_next < 0) * 100.0 / COUNT(*), 2) AS porsi_persen
FROM time_between
WHERE next_stage = stage_number + 1;

-- Pemeriksaan 4: jumlah ketiga platform sama dengan total tiap tahap
SELECT
    f.stage_number,
    f.event_name,
    f.users                AS total,
    CAST(SUM(p.users) AS BIGINT) AS jumlah_platform,
    CASE WHEN f.users = SUM(p.users) THEN 'lolos' ELSE 'TIDAK LOLOS, selisih' END AS hasil
FROM funnel_counts f
JOIN platform_split p USING (stage_number)
GROUP BY f.stage_number, f.event_name, f.users
ORDER BY f.stage_number;

-- Pemeriksaan 4b: hal yang sama untuk pecahan kota
SELECT
    f.stage_number,
    f.users                AS total,
    CAST(SUM(c.users) AS BIGINT) AS jumlah_kota,
    CASE WHEN f.users = SUM(c.users) THEN 'lolos' ELSE 'TIDAK LOLOS, selisih' END AS hasil
FROM funnel_counts f
JOIN (SELECT city, stage_number, COUNT(DISTINCT user_id) AS users
      FROM user_stages GROUP BY city, stage_number) c USING (stage_number)
GROUP BY f.stage_number, f.users
ORDER BY f.stage_number;

-- Pemeriksaan 5: apakah tiap tahap bersarang di tahap sebelumnya.
-- LEFT JOIN, supaya pengguna tanpa pasangan tetap muncul. Di PostgreSQL baris tanpa
-- pasangan berisi NULL (ClickHouse mengisinya untai kosong), jadi syaratnya IS NULL.
SELECT
    atas.stage_number,
    atas.event_name,
    COUNT(*) FILTER (WHERE bawah.user_id IS NULL) AS tanpa_tahap_sebelumnya,
    COUNT(*)                                     AS pengguna_di_tahap
FROM user_stages AS atas
LEFT JOIN user_stages AS bawah
       ON atas.user_id = bawah.user_id
      AND bawah.stage_number = atas.stage_number - 1
WHERE atas.stage_number > 1
GROUP BY atas.stage_number, atas.event_name
ORDER BY atas.stage_number;

-- Pemeriksaan tambahan (di luar lima): satu baris per pengguna per tahap,
-- hanya nomor tahap 1 sampai 5, dan cacah pengguna sebelum vs sesudah pembersihan.
SELECT
    (SELECT COUNT(*) FROM (SELECT user_id, stage_number, COUNT(*) AS n
                           FROM user_stages GROUP BY user_id, stage_number HAVING COUNT(*) > 1) x) AS baris_kembar_user_stages,
    (SELECT COUNT(*) FROM user_stages WHERE stage_number NOT BETWEEN 1 AND 5)            AS nomor_tahap_di_luar_1_5,
    (SELECT COUNT(*) FROM user_stages)                                                   AS baris_user_stages,
    (SELECT SUM(users) FROM funnel_counts)                                               AS jumlah_cacah_lima_tahap,
    (SELECT COUNT(DISTINCT user_id) FROM bronze.user_events)                     AS pengguna_data_mentah,
    (SELECT COUNT(DISTINCT user_id) FROM clean_events)                                    AS pengguna_data_bersih,
    (SELECT COUNT(DISTINCT user_id) FROM user_stages)                                     AS pengguna_dengan_tahap_funnel;

-- ============================================================
-- SUPPORTING ANALYSIS
-- ============================================================

-- Ringkasan jarak hari, hanya transisi BERTETANGGA, nilai negatif dipisahkan
SELECT
    stage_number,
    event_name                                                         AS dari,
    MIN(next_stage)                                             AS ke_nomor,
    COUNT(*)                                                          AS transisi,
    ROUND(AVG(days_to_next), 2)                                       AS rata_rata_hari,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY days_to_next)                                              AS median_hari,
    MAX(days_to_next)                                                 AS maksimum_hari,
    COUNT(*) FILTER (WHERE days_to_next < 0)                          AS transisi_negatif,
    ROUND(AVG(days_to_next) FILTER (WHERE days_to_next >= 0), 2)      AS rata_rata_tanpa_negatif
FROM time_between
WHERE next_stage = stage_number + 1
GROUP BY stage_number, event_name
ORDER BY stage_number;

-- Pecahan kota untuk langkah terburuk (SignUp -> VerifyPhone), dua penyebut.
-- Tabel A: pengguna yang punya KEDUA tahap (menilai perpindahan antar tahap).
SELECT
    s.city,
    COUNT(*)                                          AS signup_users,
    COUNT(v.user_id)                                   AS verify_juga_signup,
    ROUND(COUNT(v.user_id) * 100.0 / COUNT(*), 2)      AS conversion_rate
FROM user_stages s
LEFT JOIN user_stages v
       ON v.user_id = s.user_id AND v.stage_number = 3
WHERE s.stage_number = 2
GROUP BY s.city
ORDER BY conversion_rate ASC;

-- Tabel B: penyebut cacah tahap per kota (seluruh pengguna tahap itu, seperti funnel_counts)
WITH c AS (
    SELECT city, stage_number, COUNT(DISTINCT user_id) AS users
    FROM user_stages GROUP BY city, stage_number
)
SELECT
    a.city,
    a.users                                    AS signup_users,
    b.users                                    AS verify_users,
    ROUND(b.users * 100.0 / a.users, 2)        AS conversion_rate
FROM c a JOIN c b ON a.city = b.city AND a.stage_number = 2 AND b.stage_number = 3
ORDER BY conversion_rate ASC;

-- Konversi tiap platform di tiap langkah, penyebut: tahap sebelumnya DI PLATFORM ITU
WITH g AS (SELECT platform, stage_number, event_name, users FROM platform_split),
k AS (
    SELECT
        platform,
        LAG(event_name) OVER (PARTITION BY platform ORDER BY stage_number) || ' ke ' || event_name AS langkah,
        LAG(users)     OVER (PARTITION BY platform ORDER BY stage_number)                        AS pengguna_tahap_sebelumnya,
        users                                                                                    AS pengguna_tahap_ini,
        ROUND(users * 100.0 / LAG(users) OVER (PARTITION BY platform ORDER BY stage_number), 2)  AS conversion_rate
    FROM g)
SELECT * FROM k
WHERE pengguna_tahap_sebelumnya IS NOT NULL
ORDER BY langkah, platform;

-- ============================================================
-- BUSINESS INSIGHT
-- ============================================================

/*
Temuan untuk Pak Fajar.

Data ini menunjukkan DI MANA orang berhenti. Ia tidak memuat satu pun percobaan,
tidak memuat catatan pengiriman kode verifikasi, dan tidak memuat alasan orang
berhenti, jadi ia tidak bisa menunjukkan KENAPA. Tiap kalimat yang berbunyi
seperti sebab di bawah ditandai sebagai dugaan.

Butir 1 sampai 6 mengikuti struktur template. Padanannya dengan pemisahan temuan
di notebook, portofolio, catatan keputusan, dan deck:
   Temuan utama 1      = butir 1 (langkah verifikasi paling bocor)
   Temuan utama 2      = butir 2 dan 3 (selisih platform terlalu kecil, temuan penolakan)
   Temuan pendukung 1  = butir 5, ukuran (a) (orang berhenti, bukan tertunda; dibaca 7 hari)
   Temuan pendukung 2  = butir 4, dua poin pertama (alat ukur belum sepenuhnya bisa dipercaya)
   Temuan pendukung 3  = butir 4, poin terakhir (rata-rata jarak menyesatkan)

1. Drop-off terbesar: Step 2 (SignUp) -> Step 3 (VerifyPhone).
   - Porsi: 45,25% berhenti (konversi 54,75%, penyebut pendaftar).
   - Dalam satuan orang: 6.730 dari 14.874 pendaftar tidak menyelesaikan verifikasi.
   - Porsi berhenti tiga langkah lain: 25,43% (5.072 dari 19.946), 30,60% (2.492 dari
     8.144), 29,83% (1.686 dari 5.652). Langkah ini kehilangan lebih banyak orang
     daripada dua langkah terakhir digabung (6.730 lawan 4.178).
   - Catatan definisi: 6.730 adalah selisih bersih dua cacah tahap. Pendaftar yang
     benar-benar tidak pernah verifikasi 6.787 (45,63%), karena 57 orang terverifikasi
     tidak pernah tercatat mendaftar. Kesimpulannya sama.
   - Ketahanan: konversi langkah ini terendah (porsi berhenti tertinggi) di 15 dari 15 bulan dan di 12 dari 12 potongan
     data (dua jendela enam bulan, tanpa 159 pengguna meloncat, tiap platform, tiap kota).

2. Pecahan platform, dengan penyebut platform itu sendiri (SignUp ke VerifyPhone):
   - iOS: 55,28% (2.891 dari 5.230)
   - Android: 54,91% (3.683 dari 6.707)
   - Web: 53,46% (1.570 dari 2.937)
   - Jarak terlebar: 1,82 poin, di langkah SignUp ke VerifyPhone (Web lawan iOS).
     Konversi keseluruhan Visit ke SecondOrder: Android 20,15%, iOS 20,11%, Web 18,88%.

3. Satu temuan yang berbentuk PENOLAKAN: platform bukan dasar prioritas.
   - Pola yang terlihat: Web memang terendah, di tiga dari empat langkah dan di
     konversi keseluruhan (18,88%, lebih rendah 1,27 poin daripada Android).
   - Ukurannya: 1,82 poin di langkah terburuk; di langkah mana pun jarak antarplatform
     tidak mencapai 2 poin (terlebar 1,85 di VerifyPhone ke FirstOrder). Selisihnya
     tidak bisa dibedakan dari kebetulan (chi-kuadrat tiga platform p = 0,27).
     Selisih antara langkah verifikasi dan langkah terburuk kedua: 14,65 poin.
   - Kenapa ia tidak dipakai: memperbaiki Web lebih dulu menghabiskan satu-satunya
     antrean kerja untuk selisih satu sampai dua poin, sementara langkah yang dilalui
     ketiga platform menahan 45,25% pendaftar. Hal yang sama untuk kota (53,51% Medan sampai
     56,69% Bandung, penyebut yang sama, p = 0,17). Klaim yang TIDAK dibuat: bahwa platform tidak berpengaruh.

4. Batas alat ukur.
   - Keanggotaan tahap yang muncul tanpa tahap sebelumnya: 159 (SignUp 48,
     VerifyPhone 57, FirstOrder 31, SecondOrder 23), dari 159 pengguna berbeda.
   - Transisi bertetangga yang stempel waktunya mundur: 35 dari 32.477, yaitu 0,11%.
   - Akibatnya pada klaim: angka funnel punya batas ketelitian. Dua tabel kota yang
     sama-sama benar berjumlah 8.087 atau 8.144 di langkah verifikasi (selisih 57,
     persis keanggotaan VerifyPhone tanpa SignUp). Tanpa ke-159 pengguna itu, langkah
     verifikasi tetap terburuk (45,65% berhenti), jadi temuan 1 tidak berbalik.
   - Rata-rata jarak Visit ke SignUp 70,68 hari tetapi mediannya 1 hari; 55,03%
     mendaftar di hari yang sama atau esoknya. Rata-rata tidak dilaporkan sendirian.

5. Rekomendasi, dan UKURAN YANG AKAN MEMBATALKANNYA.
   - Tindakan: arahkan satu antrean kerja kuartal ini ke langkah verifikasi telepon,
     berlaku untuk ketiga platform sekaligus, dijalankan sebagai uji terukur dengan
     kelompok pembanding (sebagian pendaftar baru memakai alur yang diperbaiki,
     sebagian alur lama). Dahului dengan audit kelengkapan pencatatan peristiwa
     verifikasi; kalau sebagian besar kehilangan ternyata cacat pencatatan,
     prioritasnya berubah.
   - Ukuran yang akan membatalkannya, ditetapkan sebelum perbaikan dikerjakan:
     (a) konversi SignUp ke VerifyPhone kelompok uji lawan pembanding, penyebut
         pendaftar kelompok itu; nilai awal 54,75%; dibaca 7 hari sesudah tiap
         pendaftaran, karena tidak ada yang verifikasi lebih dari 6 hari sesudah
         mendaftar (86,06% di hari yang sama atau esoknya). Selisih nol berarti
         rekomendasinya keliru atau perbaikannya salah sasaran;
     (b) jumlah pendaftar yang menyelesaikan verifikasi, dalam satuan orang;
         nilai awal 8.144 dari 14.874;
     (c) cacah keanggotaan tahap yang meloncat; nilai awal 159. Kalau tidak turun
         sesudah audit, perbandingan sebelum-sesudah belum layak dipercaya.
   - Tidak ada kalimat yang menjanjikan hasil: data ini tidak memuat percobaan.

6. Skenario kapasitas (OPSIONAL, ditandai skenario, tidak masuk ringkasan).
   - Skenario: jika konversi step 3 naik 5 poin persentase, +744 pendaftar
     terverifikasi selama 15 bulan (5% x 14.874), sekitar 50 per bulan; dengan
     konversi lanjutan tetap (69,40% x 70,17%), sekitar 362 pesanan kedua
     tambahan, sekitar 24 per bulan.
   - Andaian yang menopangnya: perbaikan berhasil sebesar itu, dan pengguna
     tambahan berperilaku seperti pengguna yang sekarang lolos verifikasi.
   - Ini angka kapasitas, BUKAN janji hasil, dan bukan temuan.
*/
