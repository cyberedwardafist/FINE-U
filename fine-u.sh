#!/usr/bin/env bash
# FINE-U: pencarian informasi publik di internet dari terminal.
# Butuh: bash, curl, jq.   Jalankan: ./fine-u.sh

BASE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
UA="FINE-U/1.0 (personal research tool)"
MAX_PER_SOURCE=5        # jumlah hasil per sumber yang ditampilkan di layar
CURL_TIMEOUT=10
FILE_TYPES=(pdf docx xlsx pptx csv)

# ---------- warna ----------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; D=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'
  CYN=$'\033[36m'; YEL=$'\033[33m'; R=$'\033[0m'
else
  B=""; D=""; RED=""; GRN=""; CYN=""; YEL=""; R=""
fi

[ -f "$BASE/.env" ] && { set -a; . "$BASE/.env"; set +a; }

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

fetch() { curl -fsS --max-time "$CURL_TIMEOUT" -A "$UA" "$@"; }

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
src_gnews()  { fetch "https://news.google.com/rss/search?q=$(urlenc "$1")&hl=id&gl=ID&ceid=ID:id" | rss_to_json; }
src_bing()   { fetch "https://www.bing.com/news/search?q=$(urlenc "$1")&format=rss" | rss_to_json; }

src_wiki() { # $1=query $2=lang
  fetch "https://$2.wikipedia.org/w/api.php?action=query&list=search&srsearch=$(urlenc "$1")&srlimit=8&format=json&origin=*" \
    | jq --arg l "$2" '.query.search | map({
        title, url: ("https://"+$l+".wikipedia.org/wiki/"+(.title|gsub(" ";"_")|@uri)),
        snippet: (.snippet|gsub("<[^>]+>";"")|gsub("&quot;";"\"")), date: .timestamp})'
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

src_brave() {
  fetch -H "X-Subscription-Token: $BRAVE_API_KEY" \
    "https://api.search.brave.com/res/v1/web/search?q=$(urlenc "$1")&count=15" \
    | jq '(.web.results // []) | map({title:(.title|gsub("<[^>]+>";"")), url,
        snippet:((.description // "")|gsub("<[^>]+>";"")), date:(.age // "")})'
}

src_cse() { # $1=query $2=extra param (mis. &fileType=pdf)
  fetch "https://www.googleapis.com/customsearch/v1?key=$GOOGLE_CSE_KEY&cx=$GOOGLE_CSE_CX&q=$(urlenc "$1")$2" \
    | jq '(.items // []) | map({title, url:.link, snippet:(.snippet // ""), date:""})'
}

# ---------- menjalankan semua sumber paralel ----------
TMP=""
SRC_COUNT=0

launch() { # name category fungsi args...
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
  local q=$1 started; started=$(date +%s%N)
  TMP=$(mktemp -d); SRC_COUNT=0

  launch "Google News"       "Berita"            src_gnews "$q"
  launch "Bing News"         "Berita"            src_bing "$q"
  launch "Wikipedia ID"      "Ensiklopedia"      src_wiki "$q" id
  launch "Wikipedia EN"      "Ensiklopedia"      src_wiki "$q" en
  launch "Wikimedia Commons" "Gambar & media"    src_commons "$q"
  launch "Internet Archive"  "File publik"       src_archive "$q"
  launch "Reddit"            "Forum & diskusi"   src_reddit "$q"
  launch "Hacker News"       "Forum & diskusi"   src_hn "$q"
  launch "GitHub"            "Kode & repositori" src_github "$q"
  launch "OpenStreetMap"     "Lokasi"            src_osm "$q"
  launch "Open Library"      "Buku"              src_openlibrary "$q"
  launch "Crossref"          "Jurnal ilmiah"     src_crossref "$q"
  [ -n "${BRAVE_API_KEY:-}" ] && launch "Brave Search" "Web" src_brave "$q"
  if [ -n "${GOOGLE_CSE_KEY:-}" ] && [ -n "${GOOGLE_CSE_CX:-}" ]; then
    launch "Google Web" "Web" src_cse "$q" ""
    for ft in "${FILE_TYPES[@]}"; do launch "Google .$ft" "File publik" src_cse "$q" "&fileType=$ft"; done
  fi

  # spinner + progres
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏') i=0 done_n=0
  while :; do
    done_n=$(find "$TMP" -name '*.done' | wc -l)
    [ -t 1 ] && printf '\r  %s%s%s Memindai sumber %d/%d  ' "$CYN" "${frames[i % 10]}" "$R" "$done_n" "$SRC_COUNT"
    [ "$done_n" -ge "$SRC_COUNT" ] && break
    i=$((i + 1)); sleep 0.1
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

# ---------- menu ----------
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

cleanup() {
  [ -n "$TMP" ] && rm -rf "$TMP"
  kill $(jobs -p) 2>/dev/null
}

main() {
  for dep in curl jq; do
    command -v "$dep" >/dev/null || { echo "Perlu '$dep'. Install: sudo apt install -y curl jq"; exit 1; }
  done
  trap cleanup EXIT
  trap 'exit 130' INT TERM
  while :; do
    menu header "Mulai cari" "Keluar"
    if [ "$CHOICE" -eq 2 ]; then clear_screen; printf '%sSampai jumpa.%s\n' "$D" "$R"; exit 0; fi
    search_session
  done
}

# Hanya jalan jika dieksekusi langsung (bukan di-source untuk pengujian).
[[ "${BASH_SOURCE[0]}" == "$0" ]] && main "$@"
