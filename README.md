# Data Analyst Portfolio — Muhammad Raditya Adhirajasa

Empat project analitik, dari data mentah sampai dashboard yang siap dipakai mengambil keputusan.

Benang merahnya: **satu pertanyaan bisnis per project**, dan **logika bisnis ditulis sedekat mungkin ke sumber data** — di SQL atau di spreadsheet, bukan sebagai calculated field di BI tool. Tiap project juga mencatat apa yang **tidak** bisa disimpulkan dari datanya.

**Tools:** PostgreSQL · SQL · Docker · Python · Power BI (DAX) · Tableau · Looker Studio · Google Sheets · Dimensional modeling

---

| Project | Pertanyaan | Data | Stack | Dashboard |
|---|---|---|---|---|
| [Coffee Shop Sales](./coffee-shop-sales-analytic) | Kapan toko paling ramai, dan produk mana yang benar-benar menggerakkan pendapatan? | 149.116 transaksi, 3 gerai NYC | Google Sheets → Looker Studio | [Live ↗](https://datastudio.google.com/reporting/dd257a9e-f591-4e20-b7d4-b4c97d23618a) |
| [Biller Analytics Pipeline](./biller-analytics-pipeline) | Bagaimana membentuk data transaksi mentah jadi warehouse yang bisa dilaporkan? | 200.000 pembayaran tagihan | Excel → PostgreSQL → Tableau | [Live ↗](https://public.tableau.com/views/Book1_17760717152110/TransactionReport) |
| [US Hospital Trauma Access](./us-hospital-trauma-access) | Seberapa jauh tiap rumah sakit AS dari layanan trauma terdekat? | 7.551 rumah sakit, 51 wilayah | PostgreSQL → Tableau | [Live ↗](https://public.tableau.com/views/USHospitalTraumaAccess/Dashboard1) |
| [Financial Transaction Analytics](./finansial-transaction-analytics) | Berapa uang yang bocor dari portofolio kartu, dan berapa yang bisa diperbaiki bank? | 13,3 juta transaksi kartu | Docker + PostgreSQL → Power BI | Screenshot* |

---

## Ringkasan

### Coffee Shop Sales
Seluruh cleaning, transformasi, dan agregasi dikerjakan **di dalam spreadsheet** — tanpa database, tanpa script.

Bisnis tumbuh **103,8%** dalam enam bulan, merata di ketiga gerai (selisih antar toko hanya 2,8%). Segmen **morning rush 08.00–11.00 menyumbang 36,7% revenue hanya dalam tiga jam**. Produk terlaris ternyata bukan penyumbang revenue terbesar: Brewed Chai tea terjual paling banyak, tapi Barista Espresso menghasilkan uang lebih banyak.

### Biller Analytics Pipeline
Project modeling: Excel → staging → **star schema** → Tableau dengan **koneksi live ke database**, bukan extract statis.

Distribusi transaksi antar channel merata — EDC sedikit unggul, tapi tidak ada channel yang dominan. Keterbatasan datanya dicatat terbuka: April hanya berisi satu hari, jadi penurunan di line chart adalah batas data, bukan penurunan performa.

### US Hospital Trauma Access
Tiga layer SQL (`raw` → `staging` → `mart`), masing-masing punya query verifikasi yang harus lolos sebelum layer berikutnya jalan.

**Rumah sakit Critical Access lima kali lebih jauh dari trauma center** dibanding rumah sakit umum — median 86,7 km lawan 16,4 km — padahal merekalah yang paling mungkin menerima korban kecelakaan pedesaan. Median nasional yang terlihat aman (18,8 km) menyembunyikan **989 rumah sakit berjarak lebih dari 100 km**.

### Financial Transaction Analytics
Yang paling teknis: 13,3 juta baris, star schema dengan bridge table, dan measure DAX.

**$4,17 juta gagal menjadi transaksi, tapi hanya 13% yang ada di tangan bank** — sisanya saldo nasabah yang memang tidak cukup. Temuan yang bisa langsung ditindaklanjuti: **kartu basi 29× lebih sering** di merchant yang menyimpan nomor kartu untuk tagihan bulanan, dibanding merchant yang menerima kartu secara fisik.

Project ini juga mendokumentasikan dua batasan yang membatalkan sebagian analisis: label fraud hanya menutup 67% transaksi, dan aturan pelabelannya berubah di tahun 2017.

---

## Kontak

- Email: ikarugaryazu@gmail.com
- LinkedIn: www.linkedin.com/in/muhammad-raditya-adhirajasa
