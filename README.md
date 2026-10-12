# FINE-U

Pencarian informasi publik di internet dari terminal, ditulis dengan Bash.
Masukkan satu nama, lokasi, atau barang. FINE-U mencari ke banyak sumber sekaligus
(berita, ensiklopedia, forum, kode, buku, jurnal, web umum, dan media sosial),
lalu hanya menampilkan sumber yang menemukan hasil, lengkap dengan link-nya.

## Butuh

```bash
sudo apt-get update
sudo snap install ngrok
sudo apt update && sudo apt install -y pipx
pipx ensurepath
pipx install seleniumbase
sudo apt update && sudo apt install -y seclists dirsearch
sudo apt install -y curl jq gawk   # hanya jika belum ada
```
Untuk **cloudflared** Resmi

```bash
wget https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
sudo dpkg -i cloudflared-linux-amd64.deb
rm cloudflared-linux-amd64.deb
```

Tambahan **opsional** untuk menu Cari email (tanpa ini, pemeriksaan lain tetap jalan):

```bash
pipx install holehe          # daftar situs tempat email terdaftar
pipx install ghunt           # profil Google untuk alamat Gmail
ghunt login                  # wajib sekali, GHunt butuh login Google
```

Hasil akan aktif otomatis setelah terpasang (cek di menu **Status sumber**). Layanan berkunci
(HaveIBeenPwned, Hunter, Abstract, ZeroBounce, IPQualityScore, EmailRep, SEON, DeHashed) diisi di
menu **Setting**; rinciannya ada di bagian "Cari email".

## Menjalankan

Butuh `bash`, `curl`, `jq`, dan `awk`. Di Kali Linux biasanya sudah ada.

```bash
git clone https://github.com/cyberedwardafist/fine-u.git
cd fine-u
chmod +x fine-u.sh setup-searxng.sh
./fine-u.sh
```

## Menu

**FITUR** (pilih dengan angka):

1. **Mulai cari**: ketik nama / lokasi / barang, lihat hasil, lalu pilih cari lagi atau kembali.
2. **Cari email**: masukkan satu alamat email, FINE-U memeriksanya (lihat bagian "Cari email").
3. **Cek IP**: analisis pasif alamat IP, domain, atau file header email (lihat bagian "Cek IP").

**TAMBAHAN** (pilih dengan huruf, huruf besar atau kecil sama saja):

- **H**: Riwayat hasil. Pilih jenis riwayat (pencarian umum, cek email, atau cek IP), lalu nomor untuk membuka hasil terakhir.
- **S**: Status sumber. Sumber umum, media sosial, pemeriksaan email, dan limit harian mana yang aktif.
- **P**: Setting. Isi atau ubah API key, preferensi, dan **limit harian per API**. Disimpan ke `.env`.
- **X**: Keluar.

Salah ketik atau salah tekan tidak menutup program: FINE-U menampilkan pesan "Input tidak dikenali" lalu
meminta input lagi, jadi tidak perlu dijalankan ulang.

Tanpa menu:

```bash
./fine-u.sh -q "nama yang dicari"   # satu kali cari, hasil tersimpan
./fine-u.sh -e "nama@domain.com"    # satu kali cek email, hasil tersimpan
./fine-u.sh --status
./fine-u.sh --help
```
untuk bypass:

```bash
python3 bypass-fetch.py "https://halaman-target-yang-diproteksi.com"
```

## Cari email

Menu **Cari email** menerima satu alamat email lalu menjalankan semua pemeriksaan sekaligus
dan menampilkan **skor kepercayaan 0-100**, daftar alasan yang mempengaruhi skor, ringkasan
temuan (nama, username, akun terhubung), dan detail tiap pemeriksaan.

**Tanpa key (langsung jalan):**

| Pemeriksaan | Isi |
|---|---|
| Sintaks & alamat | Format, alias `+tag`, bentuk kanonik Gmail, akun peran (`admin@`, `info@`), salah ketik domain (`gmial.com`). |
| DNS & server email | MX, penyedia email (Google, Microsoft 365, Niagahoster, dst.), SPF, DMARC, DKIM selector umum, null MX, domain tidak ada. |
| Email sekali pakai | Daftar [disposable-email-domains](https://github.com/disposable-email-domains/disposable-email-domains) (diunduh ke `cache/`, diperbarui tiap 7 hari) + Kickbox publik. |
| Registrasi domain | RDAP: tanggal daftar, umur domain, kedaluwarsa, registrar, nameserver. Domain baru dapat penalti. |
| Gravatar | Profil publik yang dibuat pemilik email: nama tampilan, username, lokasi, akun terhubung. |
| GitHub | Akun dengan email publik dan commit publik yang memakai email itu (nama di commit, repositori). |
| Kunci PGP | Ada atau tidaknya kunci terverifikasi di keys.openpgp.org. |
| EmailRep | Reputasi, jumlah referensi, pertama/terakhir terlihat, platform tempat email terdeteksi. |
| LeakCheck | Muncul di berapa kebocoran data, sumbernya, dan jenis data yang terpapar (tanpa isi kredensial). |
| Pivoting username | Menebak username dari bagian sebelum `@` dan membuat tautan GitHub/GitLab/Instagram. Hanya tebakan: halaman tidak dibuka, tidak mempengaruhi skor. |
| Platform kreatif | Memeriksa apakah profil publik dengan username tebakan (bagian sebelum `@`) ada di 23 platform: Figma, Canva, Pinterest, Behance, Dribbble, ArtStation, DeviantArt, Flickr, 500px, Unsplash, Pexels, SoundCloud, Vimeo, Medium, Tumblr, Linktree, Ko-fi, Patreon, Gumroad, Itch.io, Sketchfab, CodePen, Etsy. **Bukan cek email terdaftar**, hanya tebakan username, tidak mempengaruhi skor. Tiap platform dites dulu dengan username acak; jika situs membalas "ada" untuk semua nama atau memblokir bot, ditandai "tidak bisa dipastikan" (bukan temuan). Platform baru: tambah satu baris di `KREATIF_PLATFORMS` dalam `fine-u.sh`. |
| Jejak di web | Mencari alamat persis lewat semua sumber umum yang aktif; hanya halaman yang memuat alamat itu secara harfiah yang ditampilkan. |

**Dengan key (isi di Setting, opsional):**

| Layanan | Menambah |
|---|---|
| HaveIBeenPwned | Nama kebocoran lengkap, tanggal, jenis data, dan paste publik. |
| Hunter | Status verifikasi, skor, dan halaman web publik yang memuat email itu. |
| Abstract Email | Deliverability, skor kualitas, catch-all, akun peran. |
| ZeroBounce | Status valid/catch-all/spamtrap/abuse, umur domain, penyedia SMTP. |
| IPQualityScore | Skor fraud, honeypot, penyalahgunaan terbaru. |
| EmailRep (key) | Batas pemakaian lebih longgar. |

Skor dihitung dari nilai dasar 40 ditambah/dikurangi pengaruh tiap pemeriksaan. Domain sekali pakai,
domain yang tidak bisa menerima email, atau sintaks rusak membatasi skor maksimum menjadi 20.
Pemeriksaan yang tidak bisa dijangkau tidak mengubah skor dan ditandai `✕`.

**Tool dan layanan tambahan:**

| Pemeriksaan | Cara mengaktifkan | Isi |
|---|---|---|
| Holehe | `pipx install holehe` (aktif otomatis jika ada di PATH) | Daftar situs tempat email terdaftar. Holehe memakai fitur lupa-kata-sandi/registrasi tiap situs, dan tidak mengirim notifikasi ke pemilik email. Butuh sekitar 30-90 detik. |
| GHunt | `pipx install ghunt` lalu `ghunt login` (aktif otomatis, hanya untuk alamat Gmail) | Gaia ID, nama profil Google, foto, tautan kontribusi Google Maps. Parser GHunt bersifat longgar karena format keluarannya bisa berubah antarversi. |
| SEON | `SEON_API_KEY` di Setting (butuh paket SEON) | Skor fraud dan akun yang terdaftar di puluhan platform. |
| DeHashed | `DEHASHED_API_KEY` di Setting | Nama basis data dan jenis data yang terpapar. Nilai kata sandi, hash, dan data pribadi dari entri bocor **tidak ditampilkan**. |

Holehe, GHunt, dan SEON mengungkap akun yang tidak terindeks mesin pencari, jadi pakailah hanya untuk
keperluan yang sah (verifikasi, keamanan, penelusuran alamat milikmu sendiri atau yang kamu berhak periksa).

Hasil disimpan di `hasil-email/<email>/<tanggal_jam>.md` dan `.json`.

## Limit harian per API

Banyak API gratis membatasi pemakaian (mis. 100 permintaan per hari). Di menu **Setting**, bagian
**Limit harian**, kamu bisa mengatur batas sendiri untuk tiap layanan berkunci:

| Layanan | Kunci di `.env` | Layanan | Kunci di `.env` |
|---|---|---|---|
| Tavily | `LIMIT_TAVILY` | ZeroBounce | `LIMIT_ZEROBOUNCE` |
| Brave Search | `LIMIT_BRAVE` | IPQualityScore | `LIMIT_IPQS` |
| Google CSE | `LIMIT_CSE` | EmailRep | `LIMIT_EMAILREP` |
| YouTube Data API | `LIMIT_YOUTUBE` | DeHashed | `LIMIT_DEHASHED` |
| HaveIBeenPwned | `LIMIT_HIBP` | SEON | `LIMIT_SEON` |
| Hunter | `LIMIT_HUNTER` | Abstract Email | `LIMIT_ABSTRACT` |

- Isi angka bulat, mis. `100`. Ketik `-` (atau `0`) untuk **tanpa batas / unlimited**, sama seperti sebelum ada limiter (bawaan).
- Yang dihitung adalah **setiap permintaan** yang benar-benar dikirim ke API, bukan jumlah pencarian.
  Satu pencarian bisa memakai beberapa permintaan (varian kueri, kelompok media sosial, file `.pdf` dsb.).
- Begitu batas tercapai, permintaan berikutnya **tidak dikirim** dan layar menampilkan
  "Batas harian tercapai: ...". Sumber lain tetap jalan. Untuk media sosial dengan `SOCIAL_BACKEND=auto`,
  FINE-U otomatis pindah ke mesin web lain yang masih punya jatah.
- Hitungan **reset otomatis tiap tengah malam** (jam lokal komputer). Di menu Setting, ketik `r`
  untuk mereset hitungan hari ini secara manual.
- Sisa jatah terlihat di menu Setting dan di **Status sumber** (`./fine-u.sh --status`).
- Hitungan disimpan di `cache/usage/<tanggal>/<layanan>` (sudah di `.gitignore`), dan catatan lebih dari
  7 hari dihapus otomatis. Penambahan hitungan dikunci (`flock`), jadi tetap akurat walau banyak sumber jalan paralel.
- Hitungan dibuat dari sisi FINE-U, jadi hanya mencatat pemakaian lewat FINE-U. Pemakaian lain dari key yang sama
  tidak ikut terhitung. Beri jarak aman dari batas asli penyedia (mis. isi 90 jika batas resminya 100).

## Akurasi dan cakupan

Setiap hasil diberi skor kecocokan terhadap kata yang dicari, ditampilkan sebagai
`[persis]`, `[semua kata]`, `[sebagian]`, atau `[lemah]`. Hasil dengan skor tertinggi
muncul paling atas, dan URL kembar dari beberapa sumber digabung.

Atur lewat menu **Setting > Mode pencarian** (`SEARCH_MODE`):

| Mode | Perilaku |
|---|---|
| `akurat` | Hanya frasa persis di mesin web/berita, dan hanya hasil yang memuat semua kata. |
| `seimbang` (bawaan) | Frasa persis + pencarian longgar. Hasil yang hanya cocok sebagian kecil dibuang. |
| `luas` | Ditambah variasi urutan nama ("Santoso Budi"), semua hasil ditampilkan. |

Catatan: mode `seimbang` dan `luas` mengirim lebih dari satu permintaan per sumber web
berkunci (Tavily, Brave, Google CSE), jadi kuota gratisnya terpakai lebih cepat.
Pakai `akurat` jika ingin berhemat, dan atur **Limit harian** di Setting supaya kuota tidak terlewat.

## Sumber

**Tanpa key:** Google News (ID dan EN), Bing News, GDELT, Wikipedia ID dan EN, Wikidata,
Wikimedia Commons, Internet Archive, Reddit, Hacker News, GitHub, GitLab, npm,
OpenStreetMap, Open Library, Google Books, Crossref, OpenAlex, Europe PMC, DuckDuckGo (HTML).

**Web umum dan file publik (aktif setelah diisi di Setting):** paling menentukan cakupan,
karena menjangkau blog, situs berita lokal, halaman tag, PDF, dan sejenisnya.

| Sumber | Cara mendapatkan | Catatan |
|---|---|---|
| SearXNG | `./setup-searxng.sh` (butuh Docker) | Gratis, jalan di komputer sendiri. Bisa kena blokir jika terlalu sering dipakai. |
| Tavily | https://tavily.com | Ada jatah gratis bulanan, cek dashboard. |
| Brave Search | https://brave.com/search/api/ | Skema gratis berubah-ubah, cek paket terbaru. |
| Google CSE | Key: https://console.cloud.google.com/apis/credentials (aktifkan Custom Search API). `cx`: https://programmablesearchengine.google.com/ | Menambah pencarian file `.pdf .docx .xlsx .pptx .csv`. Kuota gratis kecil. |

## Mencari URL atau domain langsung

Kalau yang kamu masukkan di "Mulai cari" sudah berupa alamat web atau domain
(mis. `kampus.ac.id` atau `https://contoh.com/halaman`), FINE-U otomatis menambahkan:

- **Alamat langsung**: mengambil halaman itu apa adanya (judul + deskripsi). Ini hanya
  mengunjungi URL yang kamu kasih sendiri, bukan menebak-nebak URL lain.
- **Wayback Machine**: salinan lama dari domain itu yang pernah disimpan Internet Archive.
- **Common Crawl**: arsip web publik lain, dicari dengan cara serupa.

FINE-U tidak menyertakan cara untuk menembus Cloudflare, CAPTCHA, atau proteksi anti-bot
lain, dan tidak menebak-nebak pola URL untuk menarik data pribadi dari halaman yang sengaja
disembunyikan (`noindex`, butuh login, dsb). Untuk halaman seperti itu, satu-satunya cara
yang didukung adalah kamu memberi URL pastinya sendiri.

## Media sosial

FINE-U tidak masuk ke akun siapa pun dan tidak melewati login. Hanya yang terlihat publik.

- **Langsung lewat API publik:** Reddit, GitHub, Bluesky, Mastodon, Lemmy, Stack Overflow,
  Hugging Face, Dailymotion, Roblox, Duolingo (hanya username tanpa spasi), dan YouTube
  jika `YOUTUBE_API_KEY` diisi.
- **Lewat mesin pencari web** (pencarian `site:` per platform, butuh SearXNG, Brave, Tavily,
  atau Google CSE): WhatsApp, Instagram, Facebook, TikTok, Telegram, X (Twitter), LinkedIn,
  Pinterest, Discord, Threads, Quora, Twitch, Snapchat, Line, KakaoTalk, WeChat, Signal,
  Tumblr, Medium, Substack, Clubhouse, VK, Vimeo, Rumble, Kick, Kaggle, Hashnode, Dev.to,
  Product Hunt, Behance, Dribbble, ArtStation, VRChat, Goodreads, Wattpad, Letterboxd,
  Strava, dan YouTube (tanpa key).

Platform digabung per kelompok (bawaan 6 platform per kueri) supaya kuota API tidak habis.
Mesin web dipilih otomatis (SearXNG, lalu Brave, Tavily, Google CSE) atau bisa dipaksa
di Setting. Untuk WhatsApp, Signal, dan Discord, yang bisa ditemukan hanya tautan undangan
atau halaman yang memang terindeks mesin pencari.

## User-Agent

Setiap permintaan memakai User-Agent browser acak (rotasi sederhana). Ini tidak menembus Cloudflare,
CAPTCHA, atau proteksi anti-bot. Beberapa layanan (mis. OpenStreetMap dan Wikimedia) meminta klien
mengenalkan diri, jadi matikan dengan `UA_ROTATE=0` di `.env` jika kamu sering terkena blokir dari layanan itu.

## Keamanan `.env`

API key disimpan di `.env`, yang dibuat otomatis oleh menu Setting. Tidak ada file contoh `.env` di repo ini.

- `.env` sudah ada di `.gitignore`, jadi tidak ikut `git add` / `git push`.
  Orang yang membuka repo ini tidak akan melihat key milikmu.
- Menu Setting memberi peringatan jika `.env` ternyata sudah terlacak Git.
- Jika `.env` pernah ter-commit atau ter-push: `git rm --cached .env`, commit, lalu **buat ulang
  semua key** di dashboard masing-masing. Menghapus file saja tidak cukup karena key tetap
  ada di riwayat Git.
- `.env` dibaca sebagai data, bukan di-source sebagai skrip, dan dibuat dengan izin `600`.
- Folder `hasil/` dan `hasil-email/` juga di-ignore karena bisa berisi informasi tentang orang. Folder `cache/` (daftar domain sekali pakai) juga di-ignore.

## Hasil tersimpan

```
hasil/<nama-yang-dicari>/<tanggal_jam>.md
hasil/<nama-yang-dicari>/<tanggal_jam>.json
```

## Catatan

Program ini hanya mengambil data yang memang terbuka untuk umum. Jika dipakai untuk
mencari informasi tentang orang, gunakan secara bertanggung jawab dan patuhi hukum
yang berlaku, termasuk UU Pelindungan Data Pribadi.

## Cek IP

Menganalisis alamat IP yang **sudah Anda miliki**: dari log server Anda sendiri, header email yang Anda terima,
atau hasil resolve sebuah domain. Masukan bisa berupa:

- **Alamat IP** (IPv4 / IPv6), mis. `8.8.8.8`
- **Domain atau URL**, mis. `contoh.com` (di-resolve ke IP, maksimum 5 IP)
- **Path file header email** (`.eml` / `.txt`): FINE-U membaca jalur `Received`, `X-Originating-IP`, hasil SPF / DKIM /
  DMARC, dan memberi peringatan jika `Reply-To` berbeda domain dari `From`

Yang diperiksa per IP: pemilik blok IP (RDAP / WHOIS), reverse DNS, perkiraan lokasi dan ISP, jenis jaringan
(hosting, seluler, CDN), node keluar Tor, dan reputasi lewat IPQualityScore bila `IPQS_API_KEY` diisi.

Catatan: lokasi IP hanya perkiraan titik jaringan ISP, bukan alamat rumah atau identitas pemilik. Webmail besar
(Gmail, Yahoo, Outlook) menyembunyikan IP asli pengirim. FINE-U sengaja **tidak** menyediakan IP logger / link
pelacak untuk menjebak orang lain.

```bash
./fine-u.sh -i 8.8.8.8
./fine-u.sh -i contoh.com
./fine-u.sh -i ~/email-mencurigakan.eml
```

Hasil tersimpan di `hasil-ip/` (tidak ikut Git) dan bisa dibuka lagi lewat **H > Cek IP**.

