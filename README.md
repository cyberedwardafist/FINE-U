# FINE-U

Pencarian informasi publik di internet dari terminal, ditulis dengan Bash.
Masukkan satu nama, lokasi, atau barang. FINE-U mencari ke banyak sumber sekaligus
dan hanya menampilkan sumber yang menemukan hasil, lengkap dengan link-nya.

## Menjalankan

Butuh `bash`, `curl`, dan `jq`. Di Kali Linux biasanya sudah ada.

```bash
sudo apt install -y curl jq      # hanya jika belum ada
git clone https://github.com/USERNAME/fine-u.git
cd fine-u
chmod +x fine-u.sh setup-searxng.sh
./fine-u.sh
```

## Menu

1. **Mulai cari**: ketik nama / lokasi / barang, lihat hasil, lalu pilih cari lagi atau kembali.
2. **Riwayat hasil**: daftar pencarian yang sudah tersimpan, pilih nomor untuk membuka hasil terakhir.
3. **Status sumber**: sumber mana yang aktif, dan variabel `.env` apa yang perlu diisi untuk sisanya.
4. **Keluar**.

Tanpa menu:

```bash
./fine-u.sh -q "nama yang dicari"   # satu kali cari, hasil tersimpan
./fine-u.sh --status
./fine-u.sh --help
```

Setiap pencarian yang punya hasil otomatis disimpan di:

```
hasil/<nama-yang-dicari>/<tanggal_jam>.md
hasil/<nama-yang-dicari>/<tanggal_jam>.json
```

## Sumber

**Aktif tanpa konfigurasi (15):** Google News, Bing News, GDELT, Wikipedia ID dan EN,
Wikidata, Wikimedia Commons, Internet Archive, Reddit, Hacker News, GitHub,
OpenStreetMap, Open Library, Crossref, OpenAlex.

**Web umum dan file publik (aktif setelah diisi di `.env`):** ini yang paling menentukan
cakupan, karena menjangkau blog, situs berita lokal, halaman tag, PDF di Scribd, dan sejenisnya.

| Sumber | Cara mendapatkan | Catatan |
|---|---|---|
| SearXNG | `./setup-searxng.sh` (butuh Docker) | Gratis, jalan di komputer sendiri, menggabungkan beberapa mesin pencari. Bisa kena blokir jika terlalu sering dipakai. |
| Tavily | Daftar di https://tavily.com, salin API key | Ada jatah gratis bulanan, cek dashboard. |
| Brave Search | https://brave.com/search/api/ | Skema gratis berubah-ubah, cek paket terbaru. |
| Google CSE | Key: https://console.cloud.google.com/apis/credentials (aktifkan Custom Search API). `cx`: https://programmablesearchengine.google.com/ | Menambah pencarian file `.pdf .docx .xlsx .pptx .csv`. Cek apakah engine baru masih bisa mencari seluruh web. |

Salin `.env.example` menjadi `.env`, isi yang kamu punya, lalu cek dengan `./fine-u.sh --status`.

## Pengaturan (`.env`)

- `EXACT_MATCH=1` mencari nama/frasa persis dalam tanda kutip di mesin pencari web dan berita
  (lebih akurat untuk nama orang). Isi `0` untuk pencarian longgar.
- `MAX_PER_SOURCE=5` jumlah hasil per sumber di layar. Daftar lengkap tetap ada di file hasil.
- `SEARXNG_LANG=all` bahasa hasil SearXNG.

## Catatan

Program ini hanya mengambil data yang memang terbuka untuk umum. Jika dipakai untuk
mencari informasi tentang orang, gunakan secara bertanggung jawab dan patuhi hukum
yang berlaku, termasuk UU Pelindungan Data Pribadi.
