import sys
import json
from seleniumbase import SB

def fetch_protected_page(url):
    """
    Fungsi untuk mengambil konten dari halaman web yang diproteksi 
    Cloudflare, CAPTCHA, atau membutuhkan rendering JavaScript berat.
    """
    print(f"[*] Mengakses URL dengan mode Stealth: {url}", file=sys.stderr)
    
    # Menggunakan Undetected-Chromedriver (UC Mode) dari SeleniumBase
    with SB(uc=True, headless=True) as sb:
        try:
            # Membuka halaman dan otomatis menangani recheck/reconnect
            sb.uc_open_with_reconnect(url, reconnect_time=5)
            
            # Jika muncul tantangan Cloudflare Turnstile / CAPTCHA klik otomatis
            if sb.is_element_visible('iframe[src*="challenges.cloudflare.com"]'):
                print("[*] Mendeteksi Cloudflare, mencoba melewati...", file=sys.stderr)
                sb.uc_gui_click_captcha()
                sb.sleep(4)
            
            # Ambil title dan seluruh source HTML halaman
            title = sb.get_title()
            page_source = sb.get_page_source()
            
            # Kembalikan data dalam format JSON standar ke terminal
            result = {
                "url": url,
                "title": title,
                "status": "success",
                "content_length": len(page_source),
                "html": page_source
            }
            print(json.dumps(result))
            
        except Exception as e:
            error_result = {
                "url": url,
                "status": "error",
                "message": str(e)
            }
            print(json.dumps(error_result))
            sys.exit(1)

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 bypass-fetch.py <URL_TARGET>")
        sys.exit(1)
    
    target_url = sys.argv[1]
    fetch_protected_page(target_url)