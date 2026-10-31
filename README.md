# Hermes + 9router (Gemini) — one-command VPS setup

Installer Debian/Ubuntu untuk memasang Docker 9router + Hermes Agent, menambahkan Gemini API key, memilih model Gemini yang tersedia, membuat combo fallback, dan menghubungkan Telegram gateway.

> Masukkan Gemini API key dan Telegram bot token hanya di prompt VPS. Jangan commit `.env`, jangan tempel secret ke command line atau chat.

## Satu perintah

```bash
curl -fsSL https://raw.githubusercontent.com/OWNER/hermes-gemini-9router/main/install.sh -o install.sh && sudo bash install.sh
```

Ganti `OWNER` dengan pemilik repo. Repo public diperlukan agar raw installer bisa diunduh tanpa autentikasi.

## Yang dilakukan

- Memasang Docker (jika belum ada) dan menjalankan 9router pada `127.0.0.1:20128` saja.
- Meminta password dashboard, Gemini API key, Telegram bot token, dan Telegram user ID secara tersembunyi.
- Memverifikasi Gemini API key melalui `v1beta/models` dan hanya menawarkan model yang mendukung `generateContent`.
- Mengonfigurasi provider Gemini dan membuat combo berisi urutan model yang dipilih.
- Menginstal Hermes Agent, mengarahkan Hermes ke 9router lokal, lalu memasang gateway systemd.
- Menyimpan rahasia di file berizin `600`; memverifikasi API model dan gateway.

## Prasyarat

- VPS Debian/Ubuntu, akses root/sudo, akses internet; x86_64 atau arm64.
- Gemini API key dari [Google AI Studio](https://aistudio.google.com/app/apikey). API billing/quota terpisah dari langganan Google AI Pro/Flow.
- Telegram bot token dari `@BotFather` dan numeric Telegram user ID. Installer tidak mempublikasikan port Telegram atau dashboard.

## Akses dashboard dengan SSH tunnel

```bash
ssh -N -L 20128:127.0.0.1:20128 root@IP-VPS
```

Lalu buka `http://localhost:20128`.

## Security

- Port 9router bind loopback saja; jangan ubah jadi `0.0.0.0` tanpa firewall/auth yang sesuai.
- Rahasia tidak ditampilkan ulang. File state installer dan `~/.hermes/.env` mode `600`.
- Gunakan key khusus dengan quota/billing yang dipahami. API key Gemini memberi akses/billing sesuai project Google lu.
- Jangan menjalankan script remote yang belum ditinjau. Unduh, baca, lalu jalankan; cek tag/release hash bila tersedia.

## Status

Project awal; verifikasi pada VPS baru tetap dibutuhkan sebelum dipakai produksi. 9router image `latest` bisa berubah; installer memeriksa endpoint readiness dan model API sebelum menandai sukses.
