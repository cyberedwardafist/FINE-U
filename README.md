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
chmod +x fine-u.sh
./fine-u.sh
```

## Cara pakai

1. Pilih `1` untuk mulai cari, lalu ketik nama / lokasi / barang.
2. FINE-U menampilkan sumber yang menemukan hasil beserta link-nya.
3. Pilih `1` untuk cari lagi, atau `2` untuk kembali ke menu awal.

Setiap pencarian yang punya hasil otomatis disimpan di:

```
hasil/<nama-yang-dicari>/<tanggal_jam>.md
hasil/<nama-yang-dicari>/<tanggal_jam>.json
```

Di layar tiap sumber menampilkan maksimal 5 hasil (ubah `MAX_PER_SOURCE` di
`fine-u.sh`). Daftar lengkapnya ada di file.

## Sumber

Tanpa API key: Google News, Bing News, Wikipedia (ID dan EN), Wikimedia Commons,
Internet Archive, Reddit, Hacker News, GitHub, OpenStreetMap, Open Library, Crossref.

Dengan API key (salin `.env.example` menjadi `.env`): Brave Search, Google Web,
dan pencarian file publik `.pdf .docx .xlsx .pptx .csv`.

## Catatan

Program ini hanya mengambil data yang memang terbuka untuk umum. Jika dipakai untuk
mencari informasi tentang orang, gunakan secara bertanggung jawab dan patuhi hukum
yang berlaku, termasuk UU Pelindungan Data Pribadi.
