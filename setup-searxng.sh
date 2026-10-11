#!/usr/bin/env bash
# Menjalankan SearXNG lokal (meta-search gratis) lewat Docker untuk FINE-U,
# lalu mengisi SEARXNG_URL di .env. Hanya mendengarkan di 127.0.0.1.
set -euo pipefail

BASE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PORT="${SEARXNG_PORT:-8888}"
NAME="fine-u-searxng"
CONF_DIR="$BASE/searxng"

if ! command -v docker >/dev/null; then
  echo "Docker belum terpasang. Di Kali:"
  echo "  sudo apt update && sudo apt install -y docker.io"
  echo "  sudo systemctl enable --now docker"
  echo "Lalu jalankan ulang skrip ini."
  exit 1
fi

DOCKER=(docker)
docker info >/dev/null 2>&1 || DOCKER=(sudo docker)

mkdir -p "$CONF_DIR"
if [ ! -f "$CONF_DIR/settings.yml" ]; then
  SECRET=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
  cat > "$CONF_DIR/settings.yml" <<YML
use_default_settings: true
server:
  secret_key: "$SECRET"
  limiter: false
  image_proxy: false
search:
  formats:
    - html
    - json
YML
  echo "Membuat $CONF_DIR/settings.yml (format JSON aktif, limiter mati untuk pemakaian lokal)."
fi

"${DOCKER[@]}" rm -f "$NAME" >/dev/null 2>&1 || true
"${DOCKER[@]}" run -d --name "$NAME" --restart unless-stopped \
  -p "127.0.0.1:$PORT:8080" \
  -v "$CONF_DIR:/etc/searxng" \
  searxng/searxng >/dev/null
echo "Container '$NAME' dijalankan di http://127.0.0.1:$PORT. Menunggu siap..."

URL="http://127.0.0.1:$PORT"
for _ in $(seq 1 40); do
  if curl -fsS --max-time 3 "$URL/search?q=test&format=json" 2>/dev/null | grep -q '"results"'; then
    OK=1; break
  fi
  sleep 1
done

if [ "${OK:-0}" != "1" ]; then
  echo "SearXNG belum merespons JSON. Cek log: ${DOCKER[*]} logs $NAME"
  exit 1
fi

touch "$BASE/.env"
if grep -q '^SEARXNG_URL=' "$BASE/.env"; then
  sed -i "s#^SEARXNG_URL=.*#SEARXNG_URL=$URL#" "$BASE/.env"
else
  printf '\nSEARXNG_URL=%s\n' "$URL" >> "$BASE/.env"
fi
echo "Siap. SEARXNG_URL=$URL sudah ditulis ke .env. Jalankan ./fine-u.sh --status untuk memeriksa."
