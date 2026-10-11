#!/usr/bin/env bash
# FINE-U: pencarian informasi publik di internet dari terminal.
# Butuh: bash, curl, jq.
#
#   ./fine-u.sh                  mode interaktif (menu)
#   ./fine-u.sh -q "nama"        satu kali cari tanpa menu, hasil disimpan
#   ./fine-u.sh --status         daftar sumber aktif / nonaktif
#   ./fine-u.sh --help

BASE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
VERSION="1.1.0"
UA="FINE-U/$VERSION (personal research tool)"

# ---------- warna ----------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; D=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'
  CYN=$'\033[36m'; YEL=$'\033[33m'; R=$'\033[0m'
else
  B=""; D=""; RED=""; GRN=""; CYN=""; YEL=""; R=""
fi

# ---------- konfigurasi (.env) ----------
[ -f "$BASE/.env" ] && { set -a; . "$BASE/.env"; set +a; }
MAX_PER_SOURCE="${MAX_PER_SOURCE:-5}"   # hasil per sumber yang ditampilkan di layar
CURL_TIMEOUT="${CURL_TIMEOUT:-10}"
EXACT_MATCH="${EXACT_MATCH:-1}"         # 1 = frasa dalam tanda kutip untuk mesin pencari web/berita
FILE_TYPES=(pdf docx xlsx pptx csv)

clear_screen() { [ -t 1 ] && printf '\033[2J\033[3J\033[H'; }

header() {
  clear_screen
  printf '\n'
  printf '  %s%s%s\n' "$B$CYN" "███████╗██╗███╗   ██╗███████╗      ██╗   ██╗" "$R"
  printf '  %s%s%s\n' "$B$CYN" "██╔════╝██║████╗  ██║██╔════╝      ██║   ██║" "$R"
  printf '  %s%s%s\n' "$B$CYN" "█████╗  ██║██╔██╗ ██║█████╗  █████╗██║   ██║" "$R"
  printf '  %s%s%s\n' "$B$CYN" "██╔══╝  ██║██║╚██╗██║██╔══╝  ╚════╝██║   ██║" "$R"
  printf '  %s%s%s\n' "$B$CYN" "██║     ██║██║ ╚████║███████╗      ╚██████╔╝" "$R"
  printf '  %s%s%s\n' "$B$CYN" "╚═╝     ╚═╝╚═╝  ╚═══╝╚══════╝       ╚═════╝ " "$R"
  printf '  %sPencarian informasi publik di internet%s\n' "$D" "$R"
  printf '  %s────────────────────────────────────────────%s\n\n' "$D" "$R"
}

# ---------- utilitas ----------
urlenc() { jq -rn --arg s "$1" '$s|@uri'; }

fetch() { curl -fsS --max-time "$CURL_TIMEOUT" --retry 1 -A "$UA" "$@"; }

# Frasa persis dalam tanda kutip (lebih akurat untuk nama orang). Atur lewat EXACT_MATCH.
webq() {
  if [ "$EXACT_MATCH" = "1" ] && [[ $1 == *" "* ]] && [[ $1 != *\"* ]]; then
    printf '"%s"' "$1"
  else
    printf '%s' "$1"
  fi
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
src_gnews() { fetch "https://news.google.com/rss/search?q=$(urlenc "$(webq "$1")")&hl=id&gl=ID&ceid=ID:id" | rss_to_json; }
src_bing()  { fetch "https://www.bing.com/news/search?q=$(urlenc "$(webq "$1")")&format=rss" | rss_to_json; }

src_gdelt() {
  fetch "https://api.gdeltproject.org/api/v2/doc/doc?query=$(urlenc "$(webq "$1")")&mode=artlist&maxrecords=10&format=json&sort=datedesc" \
    | jq '(.articles // []) | map({title, url, snippet:(.domain // ""), date:(.seendate // "")})'
}

# --- Ensiklopedia & data ---
src_wiki() { # $1=query $2=lang
  fetch "https://$2.wikipedia.org/w/api.php?action=query&list=search&srsearch=$(urlenc "$1")&srlimit=8&format=json&origin=*" \
    | jq --arg l "$2" '.query.search | map({
        title, url: ("https://"+$l+".wikipedia.org/wiki/"+(.title|gsub(" ";"_")|@uri)),
        snippet: (.snippet|gsub("<[^>]+>";"")|gsub("&quot;";"\"")), date: .timestamp})'
}

src_wikidata() {
  fetch "https://www.wikidata.org/w/api.php?action=wbsearchentities&search=$(urlenc "$1")&language=id&uselang=id&limit=8&format=json&origin=*" \
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
  fetch "https://www.reddit.com/search.json?q=$(urlenc "$1")&limit=10" \
    | jq '.data.children | map(.data | {title, url:("https://www.reddit.com"+.permalink),
        snippet:("r/"+.subreddit), date:(.created_utc|floor|todate)})'
}

src_hn() {
  fetch "https://hn.algolia.com/api/v1/search?query=$(urlenc "$1")&hitsPerPage=8" \
    | jq '.hits | map({title:(.title // .story_title // "(tanpa judul)"),
        url:(.url // ("https://news.ycombinator.com/item?id="+.objectID)), snippet:"", date:.created_at})'
}

src_github() {
  local h=()
  [ -n "${GITHUB_TOKEN:-}" ] && h=(-H "Authorization: Bearer $GITHUB_TOKEN")
  fetch "${h[@]}" "https://api.github.com/search/repositories?q=$(urlenc "$1")&per_page=8" \
    | jq '.items | map({title:.full_name, url:.html_url, snippet:(.description // ""), date:.pushed_at})'
}

src_osm() {
  fetch "https://nominatim.openstreetmap.org/search?q=$(urlenc "$1")&format=json&limit=5" \
    | jq 'map({title:.display_name, url:("https://www.openstreetmap.org/"+.osm_type+"/"+(.osm_id|tostring)),
        snippet:("lat "+.lat+", lon "+.lon), date:""})'
}

src_openlibrary() {
  fetch "https://openlibrary.org/search.json?q=$(urlenc "$1")&limit=8" \
    | jq '.docs | map({title, url:("https://openlibrary.org"+.key),
        snippet:((.author_name // [])|join(", ")), date:((.first_publish_year // "")|tostring)})'
}

src_crossref() {
  fetch "https://api.crossref.org/works?query=$(urlenc "$1")&rows=8" \
    | jq '.message.items | map({title:((.title // [])[0] // "(tanpa judul)"), url:.URL,
        snippet:((."container-title" // [])[0] // ""), date:(.created."date-time" // "")})'
}

src_openalex() {
  fetch "https://api.openalex.org/works?search=$(urlenc "$1")&per-page=8" \
    | jq '(.results // []) | map({title:(.display_name // "(tanpa judul)"), url:(.doi // .id),
        snippet:(.primary_location.source.display_name // ""), date:((.publication_year // "")|tostring)})'
}

# --- Web umum (butuh key / server sendiri) ---
src_searxng() {
  fetch "${SEARXNG_URL%/}/search?q=$(urlenc "$(webq "$1")")&format=json&language=${SEARXNG_LANG:-all}" \
    | jq '(.results // [])[:15] | map({title, url, snippet:((.content // "")|gsub("<[^>]+>";"")),
        date:(.publishedDate // "")})'
}

src_searxng_files() {
  local q; q="$(webq "$1") (filetype:pdf OR filetype:docx OR filetype:xlsx OR filetype:pptx)"
  fetch "${SEARXNG_URL%/}/search?q=$(urlenc "$q")&format=json&language=${SEARXNG_LANG:-all}" \
    | jq '(.results // [])[:15] | map({title, url, snippet:((.content // "")|gsub("<[^>]+>";"")),
        date:(.publishedDate // "")})'
}

src_tavily() {
  jq -n --arg q "$1" '{query:$q, max_results:10, search_depth:"basic"}' \
    | fetch -X POST -H "Authorization: Bearer $TAVILY_API_KEY" -H "Content-Type: application/json" \
        -d @- "https://api.tavily.com/search" \
    | jq '(.results // []) | map({title, url, snippet:(.content // ""), date:""})'
}

src_brave() {
  fetch -H "X-Subscription-Token: $BRAVE_API_KEY" \
    "https://api.search.brave.com/res/v1/web/search?q=$(urlenc "$(webq "$1")")&count=15" \
    | jq '(.web.results // []) | map({title:(.title|gsub("<[^>]+>";"")), url,
        snippet:((.description // "")|gsub("<[^>]+>";"")), date:(.age // "")})'
}

src_cse() { # $1=query $2=parameter tambahan (mis. &fileType=pdf)
  fetch "https://www.googleapis.com/customsearch/v1?key=$GOOGLE_CSE_KEY&cx=$GOOGLE_CSE_CX&q=$(urlenc "$(webq "$1")")$2" \
    | jq '(.items // []) | map({title, url:.link, snippet:(.snippet // ""), date:""})'
}

# ---------- daftar sumber ----------
# register  nama  kategori  fungsi  argumen-tambahan  variabel-env-yang-dibutuhkan  [tersembunyi]
SRC_NAME=(); SRC_CAT=(); SRC_FN=(); SRC_ARG=(); SRC_REQ=(); SRC_HIDE=()
register() {
  SRC_NAME+=("$1"); SRC_CAT+=("$2"); SRC_FN+=("$3"); SRC_ARG+=("$4"); SRC_REQ+=("$5"); SRC_HIDE+=("${6:-0}")
}
source_active() { # $1 = daftar nama variabel (dipisah spasi); aktif jika semuanya terisi
  local v
  for v in $1; do [ -n "${!v:-}" ] || return 1; done
  return 0
}

register "Google News"        "Berita"            src_gnews       ""  ""
register "Bing News"          "Berita"            src_bing        ""  ""
register "GDELT"              "Berita"            src_gdelt       ""  ""
register "Wikipedia ID"       "Ensiklopedia"      src_wiki        id  ""
register "Wikipedia EN"       "Ensiklopedia"      src_wiki        en  ""
register "Wikidata"           "Ensiklopedia"      src_wikidata    ""  ""
register "Wikimedia Commons"  "Gambar & media"    src_commons     ""  ""
register "Internet Archive"   "File publik"       src_archive     ""  ""
register "Reddit"             "Forum & diskusi"   src_reddit      ""  ""
register "Hacker News"        "Forum & diskusi"   src_hn          ""  ""
register "GitHub"             "Kode & repositori" src_github      ""  ""
register "OpenStreetMap"      "Lokasi"            src_osm         ""  ""
register "Open Library"       "Buku"              src_openlibrary ""  ""
register "Crossref"           "Jurnal ilmiah"     src_crossref    ""  ""
register "OpenAlex"           "Jurnal ilmiah"     src_openalex    ""  ""
register "SearXNG"            "Web"               src_searxng       "" "SEARXNG_URL"
register "SearXNG (file)"     "File publik"       src_searxng_files "" "SEARXNG_URL"
register "Tavily"             "Web"               src_tavily        "" "TAVILY_API_KEY"
register "Brave Search"       "Web"               src_brave         "" "BRAVE_API_KEY"
register "Google CSE (+file)" "Web"               src_cse           "" "GOOGLE_CSE_KEY GOOGLE_CSE_CX"
for _ft in "${FILE_TYPES[@]}"; do
  register "Google .$_ft" "File publik" src_cse "&fileType=$_ft" "GOOGLE_CSE_KEY GOOGLE_CSE_CX" 1
done

# ---------- menjalankan semua sumber aktif secara paralel ----------
TMP=""
SRC_COUNT=0

launch() { # name category fungsi query arg
  local name=$1 cat=$2; shift 2
  SRC_COUNT=$((SRC_COUNT + 1))
  local id; id=$(printf '%02d' "$SRC_COUNT")
  printf '%s|%s' "$name" "$cat" > "$TMP/$id.meta"
  (
    set -o pipefail
    if "$@" > "$TMP/$id.tmp" 2>/dev/null; then mv "$TMP/$id.tmp" "$TMP/$id.json"
    else echo '[]' > "$TMP/$id.json"; : > "$TMP/$id.fail"; fi
    : > "$TMP/$id.done"
  ) &
}

run_scan() { # $1 = query ; hasil JSON di $REPORT
  local q=$1 started i; started=$(date +%s%N)
  TMP=$(mktemp -d); SRC_COUNT=0

  for i in "${!SRC_NAME[@]}"; do
    source_active "${SRC_REQ[i]}" || continue
    launch "${SRC_NAME[i]}" "${SRC_CAT[i]}" "${SRC_FN[i]}" "$q" "${SRC_ARG[i]}"
  done

  # spinner + progres
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏') n=0 done_n=0
  while :; do
    done_n=$(find "$TMP" -name '*.done' | wc -l)
    [ -t 1 ] && printf '\r  %s%s%s Memindai sumber %d/%d  ' "$CYN" "${frames[n % 10]}" "$R" "$done_n" "$SRC_COUNT"
    [ "$done_n" -ge "$SRC_COUNT" ] && break
    n=$((n + 1)); sleep 0.1
  done
  [ -t 1 ] && printf '\r\033[2K'

  # gabungkan: buang duplikat URL, simpan hanya sumber yang punya hasil
  local f id name cat failed_json='[]'
  : > "$TMP/all.ndjson"
  for f in "$TMP"/*.meta; do
    id=$(basename "$f" .meta)
    IFS='|' read -r name cat < "$f"
    jq -c --arg s "$name" --arg c "$cat" '{source:$s, category:$c, items:.}' "$TMP/$id.json" >> "$TMP/all.ndjson" 2>/dev/null
    [ -f "$TMP/$id.fail" ] && failed_json=$(jq -c --arg s "$name" '. + [{source:$s}]' <<< "$failed_json")
  done

  local took=$(( ($(date +%s%N) - started) / 1000000 ))
  REPORT=$(jq -s --arg q "$q" --arg date "$(date -Iseconds)" --argjson took "$took" \
      --argjson tried "$SRC_COUNT" --argjson failed "$failed_json" '
    reduce .[] as $s ({seen:{}, found:[]};
      reduce $s.items[] as $i (. + {cur:[]};
        if ($i.url // "") == "" or .seen[$i.url] then .
        else (.seen[$i.url] = true | .cur += [$i]) end)
      | if (.cur|length) > 0 then .found += [{source:$s.source, category:$s.category, items:.cur}] else . end
      | del(.cur))
    | {query:$q, date:$date, tookMs:$took, sourcesTried:$tried,
       total:([.found[].items|length] | add // 0), found:.found, failed:$failed}' "$TMP/all.ndjson")
  rm -rf "$TMP"; TMP=""
}

# ---------- tampilan hasil ----------
show_report() {
  local total found failed secs
  total=$(jq -r '.total' <<< "$REPORT")
  if [ "$total" -eq 0 ]; then
    printf '  %sTidak ada hasil untuk "%s".%s\n\n' "$YEL" "$QUERY" "$R"; return
  fi
  found=$(jq -r '.found|length' <<< "$REPORT")
  failed=$(jq -r '.failed|length' <<< "$REPORT")
  secs=$(jq -r '(.tookMs/100|floor)/10' <<< "$REPORT")
  printf '  %sDitemukan %s hasil di %s sumber%s  %s(%s dtk)%s\n\n' "$GRN" "$total" "$found" "$R" "$D" "$secs" "$R"

  local width=$(( $(tput cols 2>/dev/null || echo 90) - 10 ))
  jq -r --argjson w "$width" --argjson max "$MAX_PER_SOURCE" \
        --arg B "$B" --arg D "$D" --arg C "$CYN" --arg R "$R" '
    def cut: gsub("\\s+";" ") | if length > $w then .[0:$w-1] + "…" else . end;
    .found[] |
      "  \($C)●\($R) \($B)\(.source)\($R) \($D)· \(.category) · \(.items|length) hasil\($R)",
      (.items[:$max] | to_entries[] |
        "    \($D)\(.key+1).\($R) \(.value.title | cut)",
        "       \($C)\(.value.url)\($R)"),
      (if (.items|length) > $max
         then "    \($D)… +\((.items|length) - $max) lagi, lengkap di file hasil\($R)" else empty end),
      ""' <<< "$REPORT"
  [ "$failed" -gt 0 ] && printf '  %s%s sumber tidak bisa dijangkau saat ini.%s\n\n' "$D" "$failed" "$R"
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
  jq -r '"# Hasil pencarian: \(.query)\n\n\(.total) hasil di \(.found|length) sumber · \(.date)\n",
    (.found[] | "\n## \(.source) · \(.category) (\(.items|length))\n",
      (.items[] | "- [\(.title)](\(.url))" + (if .date != "" then " · \(.date)" else "" end)
                  + (if .snippet != "" then "\n  \(.snippet)" else "" end)))' <<< "$REPORT" > "$dir/$ts.md"
  printf '%s' "${dir/#$PWD\//}/$ts.md"
}

# ---------- status sumber ----------
print_status() {
  local i act=0 total=${#SRC_NAME[@]}
  for i in "${!SRC_NAME[@]}"; do
    source_active "${SRC_REQ[i]}" && act=$((act + 1))
    [ "${SRC_HIDE[i]}" = "1" ] && continue
    if source_active "${SRC_REQ[i]}"; then
      printf '  %s●%s %-20s %s%s%s\n' "$GRN" "$R" "${SRC_NAME[i]}" "$D" "${SRC_CAT[i]}" "$R"
    else
      printf '  %s○%s %-20s %s%s · isi di .env: %s%s\n' "$D" "$R" "${SRC_NAME[i]}" "$D" "${SRC_CAT[i]}" "${SRC_REQ[i]}" "$R"
    fi
  done
  printf '\n  %s%d dari %d sumber aktif%s' "$B" "$act" "$total" "$R"
  printf '  %s(EXACT_MATCH=%s)%s\n' "$D" "$EXACT_MATCH" "$R"
  if [ -f "$BASE/.env" ]; then printf '  %sKonfigurasi: %s%s\n' "$D" "$BASE/.env" "$R"
  else printf '  %sBelum ada .env. Salin .env.example menjadi .env untuk mengaktifkan sumber tambahan.%s\n' "$D" "$R"; fi
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

result_screen() {
  header
  printf '  Hasil untuk: %s%s%s\n\n' "$B" "$QUERY" "$R"
  show_report
  [ -n "$SAVED" ] && printf '  %s✓ Tersimpan:%s %s%s%s\n\n' "$GRN" "$R" "$D" "$SAVED" "$R"
}

search_session() {
  while :; do
    header
    printf '  %sMULAI CARI%s  %s(kosongkan lalu Enter untuk kembali)%s\n\n' "$B" "$R" "$D" "$R"
    printf '  Masukkan nama / lokasi / barang: '
    read -r QUERY || exit 0
    QUERY=$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' <<< "$QUERY")
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
  if [ -t 1 ] && command -v less >/dev/null; then less -R "$1"; else cat "$1"; fi
}

history_session() {
  local dirs d last n q ans i
  while :; do
    header
    printf '  %sRIWAYAT HASIL%s\n\n' "$B" "$R"
    mapfile -t dirs < <(find "$BASE/hasil" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
    if [ "${#dirs[@]}" -eq 0 ]; then
      printf '  Belum ada hasil tersimpan. Lakukan pencarian dulu.\n\n'; pause; return
    fi
    i=1
    for d in "${dirs[@]}"; do
      last=$(find "$d" -name '*.md' | sort | tail -n1)
      n=$(find "$d" -name '*.md' | wc -l)
      q=$(jq -r '.query // empty' "${last%.md}.json" 2>/dev/null); q=${q:-$(basename "$d")}
      printf '  %s[%d]%s %s  %s(%d pencarian, terakhir %s)%s\n' "$B$CYN" "$i" "$R" "$q" "$D" "$n" \
        "$(basename "$last" .md)" "$R"
      i=$((i + 1))
    done
    printf '\n  Nomor untuk membuka hasil terakhir (kosongkan untuk kembali): '
    read -r ans || exit 0
    [ -z "$ans" ] && return
    if [[ $ans =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= ${#dirs[@]} )); then
      view_file "$(find "${dirs[ans-1]}" -name '*.md' | sort | tail -n1)"
    fi
  done
}

status_screen() {
  header
  printf '  %sSTATUS SUMBER%s\n\n' "$B" "$R"
  print_status
  printf '\n'
  pause
}

cleanup() {
  [ -n "$TMP" ] && rm -rf "$TMP"
  kill $(jobs -p) 2>/dev/null
}

usage() {
  cat <<USAGE
FINE-U $VERSION

Pemakaian:
  ./fine-u.sh                 mode interaktif (menu)
  ./fine-u.sh -q "nama"       satu kali cari tanpa menu; hasil disimpan di hasil/
  ./fine-u.sh --status        daftar sumber aktif / nonaktif
  ./fine-u.sh --help          bantuan ini

Konfigurasi lewat file .env (lihat .env.example).
USAGE
}

check_deps() {
  local dep
  for dep in curl jq; do
    command -v "$dep" >/dev/null || { echo "Perlu '$dep'. Install: sudo apt install -y curl jq"; exit 1; }
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
  case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    --status)  check_deps; print_status; exit 0 ;;
    -q|--query)
      shift
      [ -z "${*:-}" ] && { usage; exit 1; }
      check_deps; trap cleanup EXIT; trap 'exit 130' INT TERM
      cli_search "$*"; exit 0 ;;
  esac

  check_deps
  trap cleanup EXIT
  trap 'exit 130' INT TERM
  while :; do
    menu header "Mulai cari" "Riwayat hasil" "Status sumber" "Keluar"
    case "$CHOICE" in
      1) search_session ;;
      2) history_session ;;
      3) status_screen ;;
      4) clear_screen; printf '%sSampai jumpa.%s\n' "$D" "$R"; exit 0 ;;
    esac
  done
}

# Hanya jalan jika dieksekusi langsung (bukan di-source untuk pengujian).
[[ "${BASH_SOURCE[0]}" == "$0" ]] && main "$@"
