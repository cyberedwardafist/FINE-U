#!/usr/bin/env bash
# FINE-U: pencarian informasi publik di internet dari terminal.
# Butuh: bash, curl, jq, awk.
#
#   ./fine-u.sh                  mode interaktif (menu)
#   ./fine-u.sh -q "nama"        satu kali cari tanpa menu, hasil disimpan
#   ./fine-u.sh --status         daftar sumber aktif / nonaktif
#   ./fine-u.sh --help

umask 077   # file .env dan folder hasil/ hanya bisa dibaca pemilik

BASE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
VERSION="1.3.0"
UA="FINE-U/$VERSION (personal research tool)"

# ---------- warna ----------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; D=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'
  CYN=$'\033[36m'; YEL=$'\033[33m'; R=$'\033[0m'
else
  B=""; D=""; RED=""; GRN=""; CYN=""; YEL=""; R=""
fi

# ---------- konfigurasi (.env) ----------
# .env dibaca baris per baris sebagai data (TIDAK di-source), dan hanya
# kunci yang dikenal yang dipakai. Isi .env tidak pernah dieksekusi.
ENV_KEYS=(SEARXNG_URL TAVILY_API_KEY BRAVE_API_KEY GOOGLE_CSE_KEY GOOGLE_CSE_CX
          YOUTUBE_API_KEY GITHUB_TOKEN SEARCH_MODE EXACT_MATCH MAX_PER_SOURCE
          SEARXNG_LANG SEARXNG_PAGES SOCIAL_SEARCH SOCIAL_BACKEND
          SOCIAL_GROUP_SIZE CURL_TIMEOUT)

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
    elif [[ $v =~ $sq ]]; then v=${BASH_REMATCH[1]}; fi
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
urldec() { local s=${1//+/ }; printf '%b' "${s//%/\\x}"; }

fetch() { curl -fsS --compressed --max-time "$CURL_TIMEOUT" --retry 1 -A "$UA" "$@"; }

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
  jq -n --arg q "$(webq "$1")" '{query:$q, max_results:15, search_depth:"basic"}' \
    | fetch -X POST -H "Authorization: Bearer $TAVILY_API_KEY" -H "Content-Type: application/json" \
        -d @- "https://api.tavily.com/search" \
    | jq '(.results // []) | map({title, url, snippet:(.content // ""), date:""})'
}

src_brave() {
  fetch -H "X-Subscription-Token: $BRAVE_API_KEY" -H "Accept: application/json" \
    "https://api.search.brave.com/res/v1/web/search?q=$(urlenc "$(webq "$1")")&count=20" \
    | jq '(.web.results // []) | map({title:(.title|gsub("<[^>]+>";"")), url,
        snippet:((.description // "")|gsub("<[^>]+>";"")), date:(.age // "")})'
}

src_cse() { # $1=query $2=parameter tambahan (mis. &fileType=pdf)
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
    tavily)  [ -n "${TAVILY_API_KEY:-}" ] ;;
    brave)   [ -n "${BRAVE_API_KEY:-}" ] ;;
    cse)     [ -n "${GOOGLE_CSE_KEY:-}" ] && [ -n "${GOOGLE_CSE_CX:-}" ] ;;
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
    if [ -f "$TMP/$id.fail" ]; then echo "$name" >> "$TMP/fails"; else echo "$name" >> "$TMP/oks"; fi
  done
  # gagal hanya jika semua varian sumber itu gagal
  failed_json=$(sort -u "$TMP/fails" | grep -vxFf "$TMP/oks" | jq -R -s -c 'split("\n") | map(select(length>0) | {source:.})')
  [ -z "$failed_json" ] && failed_json='[]'
  tried=$(cat "$TMP"/*.meta 2>/dev/null | tr -s '|' '\n' | awk 'NR % 4 == 1' | sort -u | wc -l)

  case "$SEARCH_MODE" in akurat) min=2 ;; luas) min=0 ;; *) min=1 ;; esac
  local took=$(( ($(date +%s%N) - started) / 1000000 ))

  REPORT=$(jq -s --arg q "$q" --arg date "$(date -Iseconds)" --arg mode "$SEARCH_MODE" \
      --argjson min "$min" --argjson took "$took" --argjson tried "$tried" --argjson failed "$failed_json" '
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
    | {query:$q, date:$date, mode:$mode, tookMs:$took, sourcesTried:$tried, found:., failed:$failed}
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
    printf '\n'; return
  fi
  found=$(jq -r '.found|length' <<< "$REPORT")
  failed=$(jq -r '.failed|length' <<< "$REPORT")
  secs=$(jq -r '(.tookMs/100|floor)/10' <<< "$REPORT")
  printf '  %sDitemukan %s hasil di %s sumber%s  %s(mode %s, %s dtk)%s\n\n' "$GRN" "$total" "$found" "$R" "$D" "$SEARCH_MODE" "$secs" "$R"

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
  printf '\n'
  if [ -f "$BASE/.env" ]; then printf '  %sKonfigurasi: %s%s\n' "$D" "$BASE/.env" "$R"
  else printf '  %sBelum ada .env. Buka menu Setting untuk mengisi API yang kamu punya.%s\n' "$D" "$R"; fi
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
  local f lines rows; f=$(mktemp)
  { printf '  %sSTATUS SUMBER%s\n\n' "$B" "$R"; print_status; } > "$f"
  lines=$(wc -l < "$f"); rows=$(tput lines 2>/dev/null || echo 24)
  if [ -t 1 ] && [ "$lines" -gt $((rows - 6)) ] && command -v less >/dev/null; then
    less -R -P 'Status sumber  (panah atas/bawah untuk gulir, q untuk kembali)' "$f"
  else
    header; cat "$f"; printf '\n'; pause
  fi
  rm -f "$f"
}

# ---------- setting ----------
# kunci | label | tipe (secret|text|num|bool|choice) | pilihan | petunjuk
SET_KEY=(SEARXNG_URL TAVILY_API_KEY BRAVE_API_KEY GOOGLE_CSE_KEY GOOGLE_CSE_CX YOUTUBE_API_KEY GITHUB_TOKEN
         SEARCH_MODE MAX_PER_SOURCE SEARXNG_LANG SOCIAL_SEARCH SOCIAL_BACKEND)
SET_LABEL=("SearXNG (alamat URL)" "Tavily (API key)" "Brave Search (API key)" "Google CSE (API key)"
           "Google CSE (cx)" "YouTube Data API (key)" "GitHub (token)"
           "Mode pencarian" "Hasil per sumber di layar" "Bahasa SearXNG" "Cari di media sosial" "Mesin web media sosial")
SET_TYPE=(text secret secret secret text secret secret choice num text bool choice)
SET_OPTS=("" "" "" "" "" "" "" "akurat seimbang luas" "" "" "" "auto searxng brave tavily cse")
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
)

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
    SOCIAL_SEARCH) echo 1 ;; SOCIAL_BACKEND) echo auto ;;
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
      printf '  Nilai baru (Enter = batal, "-" = hapus / kembali ke bawaan): '
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
    SEARXNG_LANG) if [ -n "$new" ] && [[ ! $new =~ ^(all|[a-z]{2,3}([-_][A-Za-z]{2,4})?)$ ]]; then
                   SET_NOTICE="Contoh yang valid: all, id, en, en-US"; SET_NOTICE_OK=0; return; fi ;;
  esac

  set_env "$k" "$new" || { SET_NOTICE="Gagal menulis .env."; SET_NOTICE_OK=0; return; }
  export "$k=$new"; apply_defaults
  if [ -z "$new" ]; then SET_NOTICE="${SET_LABEL[i]} dihapus."; else SET_NOTICE="${SET_LABEL[i]} tersimpan di .env."; fi
}

settings_screen() {
  local i k t v dot n=${#SET_KEY[@]} ans
  SET_NOTICE=""
  while :; do
    header
    printf '  %sSETTING%s  %s(isi / ubah API dan preferensi, tersimpan di .env)%s\n\n' "$B" "$R" "$D" "$R"
    env_git_warning
    printf '  %sKunci & alamat API%s\n' "$B" "$R"
    for ((i = 0; i < n; i++)); do
      k=${SET_KEY[i]}; t=${SET_TYPE[i]}; v="${!k:-}"
      if [ "$i" -eq 7 ]; then printf '\n  %sPreferensi%s\n' "$B" "$R"; fi
      if [ "$i" -lt 7 ]; then
        if [ -n "$v" ]; then dot="${GRN}●${R}"; else dot="${D}○${R}"; fi
        printf '  %s[%2d]%s %-26s %s %s\n' "$B$CYN" "$((i + 1))" "$R" "${SET_LABEL[i]}" "$dot" "$(mask_value "$v" "$t")"
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
    printf '  Nomor yang ingin diubah (Enter = kembali): '
    read -r ans || exit 0
    [ -z "$ans" ] && return
    if [[ $ans =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= n )); then
      edit_setting $((ans - 1))
    else
      SET_NOTICE="Pilihan tidak valid. Ketik angka 1 sampai $n."; SET_NOTICE_OK=0
    fi
  done
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

API dan preferensi diatur lewat menu Setting (disimpan di .env, tidak ikut Git).
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
    menu header "Mulai cari" "Riwayat hasil" "Status sumber" "Setting" "Keluar"
    case "$CHOICE" in
      1) search_session ;;
      2) history_session ;;
      3) status_screen ;;
      4) settings_screen ;;
      5) clear_screen; printf '%sSampai jumpa.%s\n' "$D" "$R"; exit 0 ;;
    esac
  done
}

# Hanya jalan jika dieksekusi langsung (bukan di-source untuk pengujian).
[[ "${BASH_SOURCE[0]}" == "$0" ]] && main "$@"
