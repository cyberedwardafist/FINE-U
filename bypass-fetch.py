import sys
import json
import os
import urllib.parse
import urllib.request
from seleniumbase import SB

def get_system_wordlist():
    """
    Mencari wordlist bawaan dari tool populer seperti dirsearch, 
    gobuster, atau seclists yang ada di sistem (misal: Kali Linux).
    """
    possible_paths = [
        "/usr/share/dirsearch/db/dicc.txt",
        "/usr/share/wordlists/dirsearch/dicc.txt",
        "/usr/share/wordlists/dirbuster/directory-list-2.3-small.txt",
        "/usr/share/wordlists/seclists/Discovery/Web-Content/common.txt",
        "/usr/share/wordlists/gobuster/common.txt"
    ]
    
    for path in possible_paths:
        if os.path.exists(path):
            print(f"[*] Menggunakan wordlist sistem: {path}", file=sys.stderr)
            try:
                with open(path, "r", encoding="utf-8", errors="ignore") as f:
                    # Ambil maksimal 500 baris teratas agar proses tetap cepat dan tidak terlalu berat
                    words = [line.strip() for line in f if line.strip() and not line.startswith("#")]
                    return words[:500] 
            except Exception:
                continue
                
    # Fallback jika tidak ada wordlist sistem yang ditemukan
    print("[*] Wordlist sistem tidak ditemukan, menggunakan wordlist cadangan...", file=sys.stderr)
    return [
        "mahasiswa", "student", "portal", "akademik", "login", "admin", "dashboard",
        "api", "v1", "v2", "data", "users", "profil", "pendaftaran", "pengumuman",
        "backup.zip", "backup.tar.gz", "db.sql", "dump.sql", "data.bak", "old.zip",
        "config.env", ".env", "config.json", "settings.json", "storage", "uploads",
        "secret", "config", "database", "sql", "bak", "zip", "tar", "gz"
    ]

def enumerate_paths(base_url):
    """
    Melakukan URL enumeration menggunakan wordlist dari sistem (dirsearch/gobuster/seclists).
    """
    print(f"[*] Memulai Path Enumeration pada domain: {base_url}", file=sys.stderr)
    parsed_url = urllib.parse.urlparse(base_url)
    root = f"{parsed_url.scheme}://{parsed_url.netloc}"
    
    found_paths = []
    wordlist = get_system_wordlist()
    
    headers = {
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
    }

    # Batasi iterasi pengecekan agar tetap efisien
    for word in wordlist:
        # Bersihkan kata jika ada awalan garis miring
        word = word.lstrip("/")
        target = f"{root}/{word}"
        try:
            req = urllib.request.Request(target, headers=headers, method="GET")
            with urllib.request.urlopen(req, timeout=2) as response:
                status = response.code
                if status in [200, 301, 302, 403]:
                    found_paths.append({
                        "path": f"/{word}",
                        "url": target,
                        "status": status
                    })
                    print(f"    [+] Ditemukan: /{word} (Status: {status})", file=sys.stderr)
        except urllib.error.HTTPError as e:
            if e.code == 403:
                found_paths.append({
                    "path": f"/{word}",
                    "url": target,
                    "status": 403
                })
                print(f"    [+] Ditemukan (Forbidden): /{word} (Status: 403)", file=sys.stderr)
        except Exception:
            pass
            
    return found_paths

def fetch_protected_page(url):
    print(f"[*] Mengakses URL dengan mode Stealth: {url}", file=sys.stderr)
    
    # Jalankan enumerasi dengan wordlist otomatis dari sistem
    discovered_dirs = enumerate_paths(url)
    
    with SB(uc=True, headless=True) as sb:
        try:
            sb.uc_open_with_reconnect(url, reconnect_time=5)
            
            if sb.is_element_visible('iframe[src*="challenges.cloudflare.com"]'):
                print("[*] Mendeteksi Cloudflare, mencoba melewati...", file=sys.stderr)
                sb.uc_gui_click_captcha()
                sb.sleep(4)
            
            title = sb.get_title()
            page_source = sb.get_page_source()
            
            result = {
                "url": url,
                "title": title,
                "status": "success",
                "content_length": len(page_source),
                "html": page_source,
                "enumerated_paths": discovered_dirs
            }
            print(json.dumps(result))
            
        except Exception as e:
            error_result = {
                "url": url,
                "status": "error",
                "message": str(e),
                "enumerated_paths": discovered_dirs
            }
            print(json.dumps(error_result))
            sys.exit(1)

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 bypass-fetch.py <URL_TARGET>")
        sys.exit(1)
    
    target_url = sys.argv[1]
    fetch_protected_page(target_url)