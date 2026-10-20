-- ============================================================
-- 01_BRONZE: data mentah apa adanya
-- Funnel onboarding super-app, PostgreSQL 16+
-- Jalankan di database funnel_onboarding (lihat panduan langkah 2).
-- Nama kolom memakai huruf kecil dengan garis bawah, konvensi PostgreSQL:
--   EventID -> event_id, UserID -> user_id, EventName -> event_name,
--   EventTimestamp -> event_timestamp, Platform -> platform, City -> city
-- ============================================================

CREATE SCHEMA IF NOT EXISTS bronze;
CREATE SCHEMA IF NOT EXISTS silver;
CREATE SCHEMA IF NOT EXISTS gold;

DROP TABLE IF EXISTS bronze.user_events CASCADE;
CREATE TABLE bronze.user_events (
    event_id         VARCHAR(20),
    user_id          VARCHAR(20),
    event_name       VARCHAR(50),
    event_timestamp  TIMESTAMP,
    platform         VARCHAR(20),
    city             VARCHAR(50)
);

-- Memuat CSV. Pilih SATU dari dua cara:
--
-- Cara A (disarankan): klik kanan tabel bronze.user_events di pgAdmin,
--   pilih Import/Export Data, lalu ikuti panduan langkah 3.
--
-- Cara B: hapus tanda komentar baris COPY di bawah dan sesuaikan lokasinya.
--   Berkas harus bisa dibaca layanan PostgreSQL, jadi taruh di folder seperti
--   C:\data\user_events.csv, bukan di folder Downloads.
-- COPY bronze.user_events FROM 'C:/data/user_events.csv' WITH (FORMAT csv, HEADER true);

-- Gerbang: harus 80.000 baris dan 20.000 pengguna
-- SELECT COUNT(*) AS baris, COUNT(DISTINCT user_id) AS pengguna FROM bronze.user_events;
