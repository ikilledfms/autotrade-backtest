# Backtest AutoTrade EA via GitHub Actions

**Status: run #5 FAILED at the seed-login step (18 Nov ~19:40 WIB).**
`mt5.initialize()` gave IPC timeout (-10005) after 300s — the Python
package could not connect to the terminal at all, so the HFM login was
never attempted (password still untested; the server name is already
verified correct from prince's HFM app screenshot). The terminal was busy
with first-run recompilation (131 files) + a 71 MB LiveUpdate download
when initialize was called; recompilation finished but IPC stayed dead
until the timeout — likely the terminal restarted to apply the update.
**Perbaikan run #6:** step "Warm up terminal" runs the terminal once for
300s first so first-run setup finishes before the seed step, and
`scripts/seed_login.py` retries initialize() up to 3 times with 60s gaps
(step timeout raised to 30 min). Jangan anggap jalur ini sudah terbukti
sampai satu run menghasilkan laporan `.htm` dengan trade > 0.

## Kenapa jalur ini

Backtest EA terblokir sejak 16 Nov ~19:20 WIB (0 run, 0 trade): terminal MT5 di
VM tidak bisa connect ke server broker (egress proxy menolak CONNECT berbasis
IP). Runner Windows GitHub punya internet langsung, jadi terminal bisa login ke
server HFM, sinkronisasi, dan unduh histori — masalah yang memblokir VM hilang.

## Yang diuji

- **EA:** `ea/AutoTrade.mq5` — snapshot build 16 Nov 2026 (1.153 baris di sumber,
  compile bersih 0 errors / 0 warnings; sha256 salinan ini
  `f4568020…a7ac676`). Salinan ini identik dengan sumber kecuali komentar
  header: nomor akun demo di-redact (hanya ada di GitHub Secrets). File `.ex5`
  TIDAK di-commit — di-compile ulang di runner setiap run. Kalau EA berubah,
  copy ulang file `.mq5` ke folder `ea/` ini.
- **Mode:** min-lot di demo $100, uji logika saja (keputusan prince 16 Nov
  18:50 WIB). Deposit tester $100 + `InpMinLotRiskCapPct=5.0` di `ea/AutoTrade.set`.
- **Simbol / TF / model:** XAUUSD, H1, Model 1 (1-minute OHLC — cukup untuk EA
  H1, jauh lebih cepat dari real ticks).
- **Jendela default:** 2026.08.03 → 2026.10.16 (~10,5 minggu; selaras dengan
  histori CSV lokal 81.384 bar M1, 2 Agu–19 Okt 2026).
- **Akun:** HFM MT5 DEMO PREMIUM (XAUUSD, leverage 1:2000) — via Secrets, lihat bawah.

## Biaya

**$0 bila repo-nya PUBLIC** — runner GitHub-hosted gratis tanpa batas menit
untuk repo publik. (Repo privat dapat 2.000 menit gratis/bulan; satu run ini
diperkirakan < 1 jam, jadi tetap aman juga.) Tidak ada kartu / pembayaran.

## Repo: pakai yang mana

**Rekomendasi: repo BARU yang publik, mis. `ikilledfms/autotrade-backtest`.**
Alasan: repo portfolio `ikilledfms.github.io` jangan dicampur dengan riset
trading; repo khusus lebih bersih, Secrets-nya terpisah, dan riwayat run-nya
tidak mengotori situs. Repo yang sudah ada tetap bisa dipakai secara teknis,
tapi tidak direkomendasikan.

## Setup (sekali saja)

1. **Buat repo publik baru** di GitHub (mis. `autotrade-backtest`).
2. **Push isi folder ini ke root repo** — struktur harus persis seperti ini:
   ```
   .github/workflows/mt5-backtest.yml
   ea/AutoTrade.mq5
   ea/SyncHistory.mq5
   ea/AutoTrade.set
   tester/tester.ini.template
   tester/login.ini.template
   scripts/prepare-tester-config.ps1
   scripts/collect-results.ps1
   scripts/seed_login.py
   README.md
   ```
   Jangan push apa pun lagi (terutama jangan push file berisi kredensial).
3. **Isi 3 Secrets** — repo → Settings → Secrets and variables → Actions →
   New repository secret:

   | Secret | Isi | Dari mana |
   |---|---|---|
   | `HFM_MT5_LOGIN` | Nomor akun demo MT5 HFM (akun Premium $100 yang terverifikasi 16 Nov) | Aplikasi/portal HFM |
   | `HFM_MT5_PASSWORD` | Password trading akun demo itu | Sama — **jangan pernah ditempel di chat/file** |
   | `HFM_MT5_SERVER` | Nama server demo HFM persis seperti di aplikasi HFM | ✅ Terverifikasi benar: `HFMarketsGlobal-Demo 4` (screenshot aplikasi HFM prince, 18 Nov 19:21 WIB) |

4. **Jalankan:** repo → Actions → "MT5 Backtest — AutoTrade EA" → Run workflow.
   Input bisa diubah per run (tanggal, model, deposit); default-nya sudah benar
   untuk backtest pertama. Tunggu sampai selesai (install ±3 mnt, compile ±1 mnt,
   login check ±2 mnt, tester: tergantung — Model 1 atas ~10 minggu biasanya
   puluhan menit; batas langkah tester 300 mnt, batas job 360 mnt).
5. **Unduh hasil:** artifact `mt5-backtest-results` di halaman run (retensi 30 hari).

## Cara baca hasil

- `SUMMARY.md` — ada/tidaknya laporan + metrik utama (best-effort parse).
- `AutoTrade-Backtest.htm` — laporan lengkap (buka di browser). Cek dulu:
  **jumlah trade** (target ≥ 50–100 trade), Total Net Profit, Profit Factor,
  Maximal Drawdown, dan **rentang tanggal yang benar-benar teruji** (kalau
  histori demo HFM lebih pendek dari jendela, laporan hanya mencakup yang tersedia).
- `AutoTrade-Backtest.png` — kurva ekuitas.
- `logs/` — journal terminal (untuk diagnosis bila run gagal).
- `AutoTrade-compile.log`, `AutoTrade.set`, `tester.ini.template` — bukti
  konfigurasi run itu.

**Penilaian kasar (bukan keputusan live):** trade ≥ 50, profit factor > 1,
drawdown masuk akal vs target sistem (max DD EA 15%). Hasil backtest demo
Premium (spread ~0,34–0,36) BUKAN hasil akun Cent live (XAUUSDc, spread dari
1,4 pip) — kalibrasi ulang sebelum live. Setelah backtest lolos: forward test
demo 30–50 trade → baru bicara live, sesuai `bridge-plan.md`. **Workflow ini
TIDAK trading live dan tidak bisa menyentuh dana real.**

## Batasan yang sudah diketahui (baca sebelum run pertama)

- **`/portable` + `MetaEditor /portable`:** diasumsikan berlaku (terdokumentasi
  di referensi skill mt5-robot-tester). Bila compile/tester tidak menemukan
  file di folder install, collect step juga memeriksa folder `%APPDATA%` —
  dan README ini harus di-update dari hasil run pertama.
- **`[Common] Password` di `tester.ini`:** login+server via `[Common]` sudah
  terverifikasi di VM (tanpa password, sesi tersimpan dipakai ulang). Di runner
  baru tidak ada sesi tersimpan — dan run #4 membuktikan password di ini
  TIDAK dipakai untuk membuat sesi baru: terminal tidak pernah mencoba login
  sama sekali (tidak ada baris login di jurnal, tidak ada marker gagal).
  **Perbaikan run #5:** step seed login via paket Python MetaTrader5 membuat
  sesi tersimpan dulu; pre-flight jadi hard gate yang memverifikasi login
  dari jurnal sebelum lanjut.
- **Nama server TERVERIFIKASI benar** — `HFMarketsGlobal-Demo 4`, dari
  screenshot aplikasi HFM prince (18 Nov 19:21 WIB).
- **Leverage di INI diabaikan tester** — yang dipakai adalah leverage akun
  (1:2000). Sudah dicatat dari smoke test VM, bukan blocker.
- **Kalender ekonomi tidak ada di tester; `InpManualNews` default (Des 2026–
  Feb 2027) jatuh DI LUAR jendela backtest** — jadi tidak ada blackout NFP/FOMC
  di dalam backtest ini. Keterbatasan yang diketahui; untuk jendela yang
  mencakup NFP, isi `InpManualNews` di `.set` dengan tanggal yang relevan.
- **Kedalaman histori demo HFM tidak diketahui** — bila M1 tidak mencapai
  Agu 2026, laporan hanya mencakup data yang ada. Cek rentang tanggal laporan.
- **Model 1 (OHLC M1), bukan real ticks** — memadai untuk uji logika EA H1;
  untuk validasi akhir bisa re-run dengan Model 0/4 (lebih lambat, butuh unduh
  tick).
- **Dialog first-run:** run #4 menunjukkan terminal baru bisa diam total
  (tidak ada percobaan login) sampai timeout — kemungkinan terjebak di dialog
  "Open an Account". Run #5 menunjukkan masalah lanjutannya: `mt5.initialize()`
  IPC timeout karena terminal masih sibuk first-run recompilation + LiveUpdate
  saat dipanggil. Step warm-up + retry (run #6) dibuat untuk melewati ini;
  bila pre-flight hard gate tetap gagal, journal di artifact menunjukkan
  penyebabnya.
- **Sintaks PowerShell belum divalidasi lokal** (tidak ada PowerShell di VM ini)
  — ditulis hati-hati dan di-review baris-per-baris; bila step PowerShell
  error, log-nya yang dibaca dulu.

## Fallback CSV (tidak terhubung ke workflow)

Histori lokal `XAUUSD_M1_20260801-20261019_MT5.csv` (81.384 bar) **sengaja
tidak** dimasukkan ke workflow: impor CSV headless tidak dimungkinkan di MT5
build 6320 — tombol impor di-grey-out untuk simbol server, dan custom symbol
tidak bisa dibuat lewat GUI. Jalur utama adalah sinkronisasi dari server
broker (step SyncHistory di workflow). Bila sinkronisasi gagal, CSV tetap
tersedia untuk impor manual di terminal desktop (lalu backtest di mesin yang
terhubung), bukan lewat workflow ini. Opsi berikutnya bila sync server tetap
gagal: buat custom symbol + impor CSV lewat fungsi MQL5 `CustomSymbolCreate` /
`CustomRatesUpdate` dari script (tanpa GUI) — belum dibangun.

## Keamanan

- Secrets tidak pernah di-print ke log; file `tester.ini`/`login.ini` hasil
  generate TIDAK PERNAH di-upload sebagai artifact (collect step sengaja
  mengecualikannya).
- Jangan commit file berisi kredensial apa pun ke repo ini — repo-nya publik.
- Workflow hanya `contents: read`, hanya jalan manual (`workflow_dispatch`),
  dan hanya login ke akun DEMO.
