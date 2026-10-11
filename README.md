# FINE-U

Pencarian informasi publik di internet dari terminal, ditulis dengan Bash.
Masukkan satu nama, lokasi, atau barang. FINE-U mencari ke banyak sumber sekaligus
(berita, ensiklopedia, forum, kode, buku, jurnal, web umum, dan media sosial),
lalu hanya menampilkan sumber yang menemukan hasil, lengkap dengan link-nya.

## Menjalankan

Butuh `bash`, `curl`, `jq`, dan `awk`. Di Kali Linux biasanya sudah ada.

```bash
sudo apt install -y curl jq gawk   # hanya jika belum ada
git clone https://github.com/USERNAME/fine-u.git
cd fine-u
chmod +x fine-u.sh setup-searxng.sh
./fine-u.sh
```

## Menu

1. **Mulai cari**: ketik nama / lokasi / barang, lihat hasil, lalu pilih cari lagi atau kembali.
2. **Riwayat hasil**: daftar pencarian yang sudah tersimpan, pilih nomor untuk membuka hasil terakhir.
3. **Status sumber**: sumber umum dan platform media sosial mana yang aktif.
4. **Setting**: isi atau ubah API key dan preferensi. Disimpan ke `.env`.
5. **Keluar**.

Tanpa menu:

```bash
./fine-u.sh -q "nama yang dicari"   # satu kali cari, hasil tersimpan
./fine-u.sh --status
./fine-u.sh --help
```

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
Pakai `akurat` jika ingin berhemat.

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

## Keamanan `.env`

API key disimpan di `.env`, yang dibuat otomatis oleh menu Setting. Tidak ada file contoh `.env` di repo ini.

- `.env` sudah ada di `.gitignore`, jadi tidak ikut `git add` / `git push`.
  Orang yang membuka repo ini tidak akan melihat key milikmu.
- Menu Setting memberi peringatan jika `.env` ternyata sudah terlacak Git.
- Jika `.env` pernah ter-commit atau ter-push: `git rm --cached .env`, commit, lalu **buat ulang
  semua key** di dashboard masing-masing. Menghapus file saja tidak cukup karena key tetap
  ada di riwayat Git.
- `.env` dibaca sebagai data, bukan di-source sebagai skrip, dan dibuat dengan izin `600`.
- Folder `hasil/` juga di-ignore karena bisa berisi informasi tentang orang.

## Hasil tersimpan

```
hasil/<nama-yang-dicari>/<tanggal_jam>.md
hasil/<nama-yang-dicari>/<tanggal_jam>.json
```

## Catatan

Program ini hanya mengambil data yang memang terbuka untuk umum. Jika dipakai untuk
mencari informasi tentang orang, gunakan secara bertanggung jawab dan patuhi hukum
yang berlaku, termasuk UU Pelindungan Data Pribadi.
