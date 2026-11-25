# -*- coding: utf-8 -*-
"""SMART SOURCE EXTRACTOR — quét, trích xuất và lập chỉ mục thư viện model từ nguồn người dùng nhập (chạy trong tiến trình AI, làn 'crawl').

Phương thức (chỉ cách được phép):
  wp_rest   WordPress REST API công khai: liệt kê toàn bộ bài viết + nội dung + danh mục + ảnh đại diện (đồng bộ theo modified_after).
  sitemap   Web crawler theo sitemap.xml, tuân thủ robots.txt (can_fetch, Crawl-delay), giới hạn số trang mỗi lần, đọc thẻ og:/meta + link tải.
  gdrive    Google Drive API v3 chính thức với API key của người dùng — chỉ thư mục chia sẻ công khai.
  index     Chỉ mục máy tìm kiếm (Brave Search API, key của người dùng) — bài công khai đã được lập chỉ mục (dùng cho Facebook).
Không đăng nhập thay người dùng, không đọc cookie, không vượt CAPTCHA/xác minh, không tải file model khi quét.
"""
import gzip
import hashlib
import json
import os
import re
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
import urllib.robotparser
import xml.etree.ElementTree as ET
from html import unescape
from html.parser import HTMLParser

UA = 'MT-Smart-Library-Pro/1.0 (SketchUp plugin; MT Design; +source-extractor)'
UA_TOKEN = 'MT-Smart-Library-Pro'
MAX_BODY = 6 * 1024 * 1024
FILE_EXT = re.compile(r'\.(skp|zip|rar|7z|glb|gltf|fbx|obj|dae|3ds|kmz|stl|usdz|blend)(\?|$)', re.I)
HOST_KIND = [
    (re.compile(r'(^|\.)drive\.google\.com$|^docs\.google\.com$'), 'gdrive'),
    (re.compile(r'(^|\.)mediafire\.com$'), 'mediafire'),
    (re.compile(r'(^|\.)mega\.(nz|io)$'), 'mega'),
    (re.compile(r'(^|\.)dropbox\.com$'), 'dropbox'),
    (re.compile(r'(^|\.)(onedrive\.live\.com|1drv\.ms|sharepoint\.com)$'), 'onedrive'),
    (re.compile(r'(^|\.)(fshare\.vn|terabox\.com|pixeldrain\.com)$'), 'filehost'),
]
PASS_RX = re.compile(r'(?:pass(?:word)?(?:\s*unzip)?|mật\s*khẩu(?:\s*giải\s*nén)?|mk)\s*[:：]\s*([^\s<>"\']{2,60})', re.I)
URL_RX = re.compile(r'https?://[^\s<>"\'\)\]]+')
SKIP_HOSTS = re.compile(r'(^|\.)(facebook\.com|twitter\.com|x\.com|pinterest\.com|instagram\.com|youtube\.com|google\.com/maps|wa\.me|zalo\.me)$')
ALLOW_HTTP = os.environ.get('MT_TEST_ALLOW_HTTP') == '1'  # chỉ dùng khi kiểm thử với máy chủ cục bộ


class Stop(Exception):
    pass


def fold(s):
    s = unicodedata.normalize('NFD', s or '').replace('đ', 'd').replace('Đ', 'D')
    s = ''.join(c for c in s if unicodedata.category(c) != 'Mn').lower()
    return re.sub(r'\s+', ' ', re.sub(r'[^a-z0-9]+', ' ', s)).strip()


def strip_html(h):
    h = re.sub(r'(?is)<(script|style)[^>]*>.*?</\1>', ' ', h or '')
    h = re.sub(r'(?i)<br\s*/?>|</p>|</div>|</li>', '\n', h)
    return re.sub(r'[ \t]+', ' ', unescape(re.sub(r'<[^>]+>', ' ', h))).strip()


def scheme_ok(url):
    u = urllib.parse.urlparse(url)
    return u.scheme == 'https' or (ALLOW_HTTP and u.scheme == 'http' and u.hostname in ('127.0.0.1', 'localhost'))


class Fetcher:
    """HTTP có giới hạn: User-Agent riêng, giãn cách giữa các yêu cầu cùng host, giới hạn dung lượng, ghi log lỗi."""

    def __init__(self, log, delay=1.0):
        self.log = log
        self.delay = delay
        self.last = {}
        self.count = 0

    def get(self, url, headers=None, accept='*/*'):
        if not scheme_ok(url):
            raise ValueError('chỉ nhận https: %s' % url)
        host = urllib.parse.urlparse(url).netloc
        wait = self.delay - (time.time() - self.last.get(host, 0))
        if wait > 0:
            time.sleep(wait)
        h = {'User-Agent': UA, 'Accept': accept, 'Accept-Encoding': 'gzip'}
        h.update(headers or {})
        req = urllib.request.Request(url, headers=h)
        self.count += 1
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                body = r.read(MAX_BODY + 1)
                if len(body) > MAX_BODY:
                    raise ValueError('trang quá lớn')
                if r.headers.get('Content-Encoding') == 'gzip':
                    body = gzip.decompress(body)
                return r.status, dict(r.headers), body
        except urllib.error.HTTPError as e:
            return e.code, dict(e.headers or {}), e.read(200000) if e.fp else b''
        finally:
            self.last[host] = time.time()

    def json(self, url, headers=None):
        st, _, body = self.get(url, headers, 'application/json')
        if st != 200:
            raise HttpErr(st, url)
        return json.loads(body.decode('utf-8', 'replace'))


class HttpErr(Exception):
    def __init__(self, code, url):
        super().__init__('HTTP %s: %s' % (code, url))
        self.code = code


def classify_link(url, site_host=''):
    u = urllib.parse.urlparse(url)
    h = (u.hostname or '').lower()
    if not h or SKIP_HOSTS.search(h):
        return None
    for rx, kind in HOST_KIND:
        if rx.search(h):
            return kind
    if FILE_EXT.search(u.path):
        return 'direct'
    if h.startswith('link.') or h.startswith('dl.') or h.startswith('download.'):
        return 'short'  # trang rút gọn/trung gian của chính trang nguồn
    return None


def extract_links(html_or_text, site_host=''):
    """Link tải trong nội dung bài: thẻ <a> và URL dạng chữ (nhiều trang ghi “Link download: …”)."""
    seen, out = set(), []
    for m in re.finditer(r'(?is)<a\s[^>]*href=["\']([^"\']+)["\'][^>]*>(.*?)</a>', html_or_text or ''):
        url, text = unescape(m.group(1)).strip(), strip_html(m.group(2))
        k = classify_link(url, site_host)
        if k and url not in seen:
            seen.add(url)
            out.append({'url': url, 'kind': k, 'text': text[:80]})
    for url in URL_RX.findall(strip_html(html_or_text)):
        url = url.rstrip('.,;')
        k = classify_link(url, site_host)
        if k and url not in seen:
            seen.add(url)
            out.append({'url': url, 'kind': k, 'text': ''})
    return out[:12]


def find_password(text):
    m = PASS_RX.search(strip_html(text or ''))
    return m.group(1).strip('.,;') if m else None


class MetaParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.meta, self.title, self._in_title, self.body = {}, '', False, []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == 'meta':
            k = (a.get('property') or a.get('name') or '').lower()
            if k and a.get('content') and k not in self.meta:
                self.meta[k] = a['content']
        elif tag == 'title':
            self._in_title = True

    def handle_endtag(self, tag):
        if tag == 'title':
            self._in_title = False

    def handle_data(self, d):
        if self._in_title:
            self.title += d


def item_from(source, key, title, url, thumb, desc, cats, links, password, downloadable=None):
    host = urllib.parse.urlparse(url).hostname or ''
    text = ' '.join([title or '', desc or '', ' '.join(cats or [])])
    if downloadable is None:
        downloadable = any(l['kind'] in ('direct', 'dropbox') for l in links)
    return {
        'key': '%s:%s' % (source['id'], key), 'source': source['id'], 'source_label': source['name'], 'uid': key,
        'title': (title or '').strip()[:200], 'url': url, 'thumb': thumb, 'thumb_large': thumb, 'author': source['name'],
        'description': (desc or '')[:600], 'categories': cats or [], 'links': links, 'password': password,
        'web_only': True, 'downloadable': bool(downloadable), 'insertable': False,
        'free': source.get('free'), 'format': 'skp' if re.search(r'sketchup|\.skp|\bskp\b', text, re.I) else '',
        'license': source.get('license') or 'Theo điều khoản của trang nguồn', 'host': host,
        'download_note': 'Tải theo link tải đã trích xuất; trang cần đăng nhập/xác minh sẽ mở trên trình duyệt.',
        'hay': fold(text),
    }


# --------------------------------------------------------------------------- Phương thức
def robots_for(f, base):
    u = urllib.parse.urlparse(base)
    rp = urllib.robotparser.RobotFileParser()
    try:
        st, _, body = f.get('%s://%s/robots.txt' % (u.scheme, u.netloc))
        rp.parse(body.decode('utf-8', 'replace').splitlines() if st == 200 else [])
    except Exception:
        rp.parse([])
    return rp


def check(source, f, keys):
    """Kiểm tra kết nối + chọn phương thức thật cho nguồn."""
    t = source['type']
    if t == 'gdrive':
        if not keys.get('google'):
            return {'method': 'gdrive', 'ok': False, 'status': 'need_key', 'note': 'Cần Google API key (Tài khoản thư viện) để đọc thư mục Drive công khai.'}
        fid = drive_folder_id(source['url'])
        if not fid:
            return {'method': 'gdrive', 'ok': False, 'status': 'error', 'note': 'Link không phải thư mục Google Drive.'}
        d = f.json(drive_url('files', {'q': "'%s' in parents and trashed=false" % fid, 'pageSize': 1, 'fields': 'files(id,name)', 'key': keys['google']}))
        return {'method': 'gdrive', 'ok': True, 'status': 'ok', 'note': 'Google Drive API: đọc được thư mục công khai (%d mục mẫu).' % len(d.get('files', []))}
    if t in ('facebook_group', 'facebook_page'):
        provs = providers_for(keys.get('_search') or {}, keys)
        names = ', '.join(SEARCH_INFO[p]['name'] for p in provs)
        if not provs:
            return {'method': 'index', 'ok': False, 'status': 'need_key',
                    'note': 'Chưa bật công cụ tìm kiếm nào. Bật Tavily (không cần key) trong Tài khoản thư viện › Công cụ tìm kiếm.'}
        return {'method': 'index', 'ok': True, 'status': 'ok',
                'note': 'Tìm bài CÔNG KHAI đã được lập chỉ mục qua: %s. Bài trong nhóm kín: mở nhóm bằng “Đăng nhập & lưu bài” rồi lưu bài đang xem.' % names}
    if t != 'website':
        return {'method': 'open_only', 'ok': False, 'status': 'unsupported', 'note': 'Dịch vụ này không có phương thức liệt kê công khai hợp lệ — mở nguồn trên trình duyệt; plugin tự nhận file vừa tải.'}
    base = source['url'].rstrip('/')
    rp = robots_for(f, base)
    rest = base + '/wp-json/wp/v2/posts'
    if rp.can_fetch(UA_TOKEN, rest + '?per_page=1'):
        try:
            d = f.json(rest + '?' + urllib.parse.urlencode({'per_page': 1, '_fields': 'id'}))
            if isinstance(d, list):
                return {'method': 'wp_rest', 'ok': True, 'status': 'ok', 'note': 'WordPress REST API công khai — trích xuất toàn bộ bài viết, danh mục, ảnh, link tải.'}
        except Exception:
            pass
    maps = sitemaps(f, base, rp)
    if maps:
        delay = rp.crawl_delay(UA_TOKEN) or rp.crawl_delay('*') or 1.5
        return {'method': 'sitemap', 'ok': True, 'status': 'ok', 'sitemaps': maps[:5],
                'note': 'Web crawler theo sitemap (tuân thủ robots.txt, giãn cách %.1fs/trang).' % float(delay)}
    if not rp.can_fetch(UA_TOKEN, base + '/'):
        return {'method': 'open_only', 'ok': False, 'status': 'blocked', 'note': 'robots.txt không cho phép truy cập tự động.'}
    return {'method': 'open_only', 'ok': False, 'status': 'no_method', 'note': 'Không có REST API hay sitemap công khai — chưa trích xuất tự động được.'}


def sitemaps(f, base, rp):
    found = list(rp.site_maps() or [])
    if not found:
        for path in ('/sitemap_index.xml', '/wp-sitemap.xml', '/sitemap.xml'):
            try:
                st, _, body = f.get(base + path, accept='application/xml')
                if st == 200 and b'<' in body[:200] and (b'urlset' in body[:2000] or b'sitemapindex' in body[:2000]):
                    found.append(base + path)
                    break
            except Exception:
                continue
    return found


def parse_sitemap(body):
    root = ET.fromstring(body)
    ns = root.tag.split('}')[0] + '}' if root.tag.startswith('{') else ''
    kind = 'index' if root.tag.endswith('sitemapindex') else 'urlset'
    out = []
    for el in root.findall(ns + ('sitemap' if kind == 'index' else 'url')):
        loc = el.find(ns + 'loc')
        lm = el.find(ns + 'lastmod')
        if loc is not None and loc.text:
            out.append((loc.text.strip(), (lm.text or '').strip() if lm is not None else ''))
    return kind, out


# ---- WordPress REST
def run_wp(source, f, st, prog, log, mode, limit):
    base = source['url'].rstrip('/')
    cats = {}
    try:
        page = 1
        while page <= 10:
            d = f.json(base + '/wp-json/wp/v2/categories?' + urllib.parse.urlencode({'per_page': 100, 'page': page, '_fields': 'id,name'}))
            if not d:
                break
            cats.update({c['id']: unescape(c['name']) for c in d})
            if len(d) < 100:
                break
            page += 1
    except Exception as e:
        log('Không đọc được danh mục: %s' % e)
    params = {'per_page': 50, '_fields': 'id,date,modified,title,link,excerpt,content,featured_media,categories', 'orderby': 'modified', 'order': 'desc'}
    if mode == 'sync' and st.get('modified_after'):
        params['modified_after'] = st['modified_after']
    host = urllib.parse.urlparse(base).hostname
    items, page, newest = [], 1, st.get('modified_after')
    while len(items) < limit:
        params['page'] = page
        try:
            posts = f.json(base + '/wp-json/wp/v2/posts?' + urllib.parse.urlencode(params))
        except HttpErr as e:
            if e.code == 400:
                break  # quá trang cuối
            raise
        if not posts:
            break
        media_ids = [p['featured_media'] for p in posts if p.get('featured_media')]
        thumbs = {}
        if media_ids:
            try:
                for m in f.json(base + '/wp-json/wp/v2/media?' + urllib.parse.urlencode({'include': ','.join(map(str, media_ids)), 'per_page': 100, '_fields': 'id,source_url,media_details'})):
                    sizes = (m.get('media_details') or {}).get('sizes') or {}
                    pick = next((sizes[k]['source_url'] for k in ('medium_large', 'medium', 'large') if k in sizes), m.get('source_url'))
                    thumbs[m['id']] = pick
            except Exception as e:
                log('Không đọc được ảnh trang %d: %s' % (page, e))
        for p in posts:
            content = (p.get('content') or {}).get('rendered', '')
            title = strip_html((p.get('title') or {}).get('rendered', ''))
            title = re.sub(r'^\d{3,6}\.\s*', '', title)
            desc = strip_html((p.get('excerpt') or {}).get('rendered', '')) or strip_html(content)[:400]
            links = extract_links(content, host)
            items.append(item_from(source, 'p%s' % p['id'], title, p.get('link'), thumbs.get(p.get('featured_media')), desc,
                                   [cats.get(c) for c in p.get('categories', []) if cats.get(c)], links, find_password(content)))
            if p.get('modified') and (not newest or p['modified'] > newest):
                newest = p['modified']
        prog({'phase': 'Đang trích xuất bài viết', 'done': len(items), 'total': limit})
        yield items
        items = []
        if len(posts) < params['per_page']:
            break
        page += 1
    st['modified_after'] = newest


# ---- Sitemap crawler
def run_sitemap(source, f, st, prog, log, mode, limit):
    base = source['url'].rstrip('/')
    rp = robots_for(f, base)
    f.delay = max(f.delay, float(rp.crawl_delay(UA_TOKEN) or rp.crawl_delay('*') or 1.5))
    queue = sitemaps(f, base, rp)
    pages, seen_maps = [], set()
    while queue and len(pages) < 20000 and len(seen_maps) < 60:
        sm = queue.pop(0)
        if sm in seen_maps:
            continue
        seen_maps.add(sm)
        try:
            stc, _, body = f.get(sm, accept='application/xml')
            if stc != 200:
                log('Sitemap %s → HTTP %s' % (sm, stc))
                continue
            if sm.endswith('.gz'):
                body = gzip.decompress(body)
            kind, entries = parse_sitemap(body)
        except Exception as e:
            log('Sitemap lỗi %s: %s' % (sm, e))
            continue
        if kind == 'index':
            # ưu tiên sitemap bài viết/sản phẩm
            entries.sort(key=lambda x: 0 if re.search(r'post|product|model|download', x[0]) else 1)
            queue.extend(u for u, _ in entries)
        else:
            pages.extend(entries)
    known = st.get('seen', {})
    bhost = urllib.parse.urlparse(base).netloc
    todo = [(u, lm) for u, lm in pages if urllib.parse.urlparse(u).netloc == bhost and (mode == 'full' or known.get(u) != lm)]
    todo = [(u, lm) for u, lm in todo if rp.can_fetch(UA_TOKEN, u)][:limit]
    host = urllib.parse.urlparse(base).hostname
    batch = []
    for n, (url, lm) in enumerate(todo):
        prog({'phase': 'Đang quét trang (%.1fs/trang theo robots.txt)' % f.delay, 'done': n, 'total': len(todo)})
        try:
            stc, hdr, body = f.get(url, accept='text/html')
            if stc != 200 or 'html' not in (hdr.get('Content-Type') or hdr.get('content-type') or 'text/html'):
                log('Bỏ qua %s (HTTP %s)' % (url, stc))
                continue
            html = body.decode('utf-8', 'replace')
            mp = MetaParser()
            mp.feed(html[:400000])
            m = mp.meta
            title = m.get('og:title') or mp.title
            thumb = m.get('og:image') or m.get('twitter:image')
            if not title or not thumb:
                continue  # không phải trang model (không có tiêu đề/ảnh xem trước)
            thumb = urllib.parse.urljoin(url, thumb)
            cats = [c for c in (m.get('article:section'), m.get('og:type') if m.get('og:type') not in ('article', 'website') else None) if c]
            links = extract_links(html, host)
            batch.append(item_from(source, hashlib.sha1(url.encode()).hexdigest()[:16], strip_html(title), url, thumb,
                                   strip_html(m.get('og:description') or m.get('description') or ''), cats, links, find_password(html)))
            known[url] = lm
        except Stop:
            raise
        except Exception as e:
            log('Trang lỗi %s: %s' % (url, e))
        if len(batch) >= 20:
            yield batch
            batch = []
    if batch:
        yield batch
    st['seen'] = known


# ---- Google Drive (API chính thức + API key)
DRIVE = os.environ.get('MT_TEST_GDRIVE_BASE', 'https://www.googleapis.com/drive/v3/')


def drive_url(path, params):
    return DRIVE + path + '?' + urllib.parse.urlencode(params)


def drive_folder_id(url):
    m = re.search(r'/folders/([A-Za-z0-9_-]{10,})', url) or re.search(r'[?&]id=([A-Za-z0-9_-]{10,})', url)
    return m.group(1) if m else None


def run_gdrive(source, f, st, prog, log, mode, limit, keys):
    key = keys.get('google')
    if not key:
        raise ValueError('Cần Google API key.')
    root = drive_folder_id(source['url'])
    queue, done = [(root, [])], 0
    while queue and done < limit:
        fid, path = queue.pop(0)
        token, files = None, []
        while True:
            p = {'q': "'%s' in parents and trashed=false" % fid, 'pageSize': 200, 'key': key,
                 'fields': 'nextPageToken,files(id,name,mimeType,size,thumbnailLink,webViewLink,modifiedTime)'}
            if token:
                p['pageToken'] = token
            d = f.json(drive_url('files', p))
            files += d.get('files', [])
            token = d.get('nextPageToken')
            if not token:
                break
        images = {os.path.splitext(x['name'])[0].lower(): x for x in files if (x.get('mimeType') or '').startswith('image/')}
        batch = []
        for x in files:
            if x.get('mimeType') == 'application/vnd.google-apps.folder':
                if len(path) < 4:
                    queue.append((x['id'], path + [x['name']]))
                continue
            if not FILE_EXT.search(x['name']):
                continue
            img = images.get(os.path.splitext(x['name'])[0].lower())
            thumb = (img or {}).get('thumbnailLink') or x.get('thumbnailLink')
            dl = drive_url('files/' + x['id'], {'alt': 'media', 'key': '{GOOGLE_KEY}'})  # key thật thêm lúc tải, không lưu
            it = item_from(source, x['id'], os.path.splitext(x['name'])[0], x.get('webViewLink') or 'https://drive.google.com/file/d/%s/view' % x['id'],
                           thumb, ' / '.join(path), path[-1:] or [], [{'url': dl, 'kind': 'gdrive_api', 'text': x['name']}], None, True)
            it['size'] = int(x.get('size') or 0)
            batch.append(it)
            done += 1
        prog({'phase': 'Đang đọc thư mục Drive', 'done': done, 'total': limit})
        if batch:
            yield batch


# ---- Chỉ mục máy tìm kiếm — NHIỀU nhà cung cấp (thử lần lượt; một nhà cung cấp lỗi/hết hạn mức → chuyển sang cái tiếp theo)
# Chỉ dùng API chính thức của từng dịch vụ. Không đọc trang Facebook trực tiếp (robots.txt của Facebook cấm truy cập tự động).
def _env_base(name, default):
    return os.environ.get('MT_TEST_%s_BASE' % name.upper(), default)


SEARCH_INFO = {
    'tavily': {'name': 'Tavily', 'key': 'optional', 'free': 'Không cần key (giới hạn tốc độ); key miễn phí 1.000 lượt/tháng',
               'signup': 'https://app.tavily.com', 'site_op': False},
    'serper': {'name': 'Serper (Google)', 'key': 'required', 'free': '2.500 lượt miễn phí khi đăng ký, không cần thẻ',
               'signup': 'https://serper.dev', 'site_op': True},
    'serpapi': {'name': 'SerpApi (Google)', 'key': 'required', 'free': '250 lượt/tháng miễn phí',
                'signup': 'https://serpapi.com/users/sign_up', 'site_op': True},
    'brave': {'name': 'Brave Search', 'key': 'required', 'free': 'Tín dụng 5 USD/tháng (~1.000 lượt), cần thẻ',
              'signup': 'https://api-dashboard.search.brave.com', 'site_op': True},
    'searxng': {'name': 'SearXNG (máy chủ riêng)', 'key': 'none', 'free': 'Miễn phí — địa chỉ máy chủ SearXNG của bạn (bật định dạng JSON)',
                'signup': 'https://docs.searxng.org', 'site_op': True},
}
QUERIES = ['sketchup', 'skp', 'model 3d', 'sofa', 'ghế', 'bàn', 'giường', 'tủ', 'đèn', 'cây', 'nội thất', 'ngoại thất', 'link tải',
           'free download']


class QuotaErr(Exception):
    pass


def _post_json(f, url, body, headers):
    if not scheme_ok(url):
        raise ValueError('chỉ nhận https')
    host = urllib.parse.urlparse(url).netloc
    wait = f.delay - (time.time() - f.last.get(host, 0))
    if wait > 0:
        time.sleep(wait)
    h = {'User-Agent': UA, 'Content-Type': 'application/json', 'Accept': 'application/json'}
    h.update(headers)
    req = urllib.request.Request(url, data=json.dumps(body).encode('utf-8'), headers=h, method='POST')
    f.count += 1
    try:
        with urllib.request.urlopen(req, timeout=25) as r:
            return json.loads(r.read(MAX_BODY).decode('utf-8', 'replace'))
    except urllib.error.HTTPError as e:
        raise HttpErr(e.code, url)
    finally:
        f.last[host] = time.time()


def search_web(provider, q, scope_domain, keys, f, cfg, count=20):
    """→ [{url, title, snippet, thumb}] từ một nhà cung cấp. Ném QuotaErr khi key sai/hết hạn mức (chuyển nhà cung cấp khác)."""
    site_q = 'site:%s %s' % (scope_domain, q) if scope_domain else q
    try:
        if provider == 'tavily':
            key = keys.get('tavily')
            hdr = {'Authorization': 'Bearer %s' % key} if key else {'X-Tavily-Access-Mode': 'keyless'}
            body = {'query': q, 'max_results': min(count, 20), 'include_images': True}
            if scope_domain:
                body['include_domains'] = [scope_domain.split('/')[0]]
            d = _post_json(f, _env_base('tavily', 'https://api.tavily.com') + '/search', body, hdr)
            out = []
            for r in d.get('results') or []:
                imgs = r.get('images') or []
                th = imgs[0].get('url') if imgs and isinstance(imgs[0], dict) else (imgs[0] if imgs else None)
                out.append({'url': r.get('url'), 'title': r.get('title'), 'snippet': r.get('content') or '', 'thumb': th})
            return out
        if provider == 'serper':
            if not keys.get('serper'):
                raise QuotaErr('chưa có key')
            d = _post_json(f, _env_base('serper', 'https://google.serper.dev') + '/search', {'q': site_q, 'num': min(count, 20)},
                           {'X-API-KEY': keys['serper']})
            return [{'url': r.get('link'), 'title': r.get('title'), 'snippet': r.get('snippet') or '', 'thumb': r.get('imageUrl')}
                    for r in d.get('organic') or []]
        if provider == 'serpapi':
            if not keys.get('serpapi'):
                raise QuotaErr('chưa có key')
            d = f.json(_env_base('serpapi', 'https://serpapi.com') + '/search.json?' + urllib.parse.urlencode(
                {'engine': 'google', 'q': site_q, 'num': min(count, 20), 'api_key': keys['serpapi']}))
            if d.get('error') and not d.get('organic_results'):
                if 'hasn' in d['error'] and 'results' in d['error']:
                    return []
                raise QuotaErr(d['error'])
            return [{'url': r.get('link'), 'title': r.get('title'), 'snippet': r.get('snippet') or '', 'thumb': r.get('thumbnail')}
                    for r in d.get('organic_results') or []]
        if provider == 'brave':
            if not keys.get('brave'):
                raise QuotaErr('chưa có key')
            d = f.json(_env_base('brave', 'https://api.search.brave.com/res/v1/web/search') + '?' + urllib.parse.urlencode(
                {'q': site_q, 'count': min(count, 20)}), headers={'X-Subscription-Token': keys['brave']})
            out = []
            for r in (d.get('web') or {}).get('results', []):
                desc = strip_html(r.get('description', '')) + ' ' + ' '.join(strip_html(x) for x in r.get('extra_snippets', []) or [])
                th = (r.get('thumbnail') or {}).get('src') or (r.get('thumbnail') or {}).get('original')
                out.append({'url': r.get('url'), 'title': strip_html(r.get('title', '')), 'snippet': desc.strip(), 'thumb': th})
            return out
        if provider == 'searxng':
            base = (cfg.get('searxng_url') or '').rstrip('/')
            if not base:
                raise QuotaErr('chưa nhập địa chỉ máy chủ SearXNG')
            d = f.json(base + '/search?' + urllib.parse.urlencode({'q': site_q, 'format': 'json'}))
            return [{'url': r.get('url'), 'title': r.get('title'), 'snippet': r.get('content') or '',
                     'thumb': r.get('thumbnail') or r.get('img_src')} for r in d.get('results') or []]
    except HttpErr as e:
        if e.code in (401, 402, 403, 429, 432, 433):
            raise QuotaErr('HTTP %s (key sai, hết hạn mức hoặc bị giới hạn tốc độ)' % e.code)
        raise
    raise ValueError('nhà cung cấp không hỗ trợ: %s' % provider)


def providers_for(cfg, keys):
    order = cfg.get('order') or ['tavily', 'serper', 'serpapi', 'brave', 'searxng']
    en = cfg.get('enabled') or {}
    out = []
    for p in order:
        if p not in SEARCH_INFO or en.get(p) is False:
            continue
        info = SEARCH_INFO[p]
        if info['key'] == 'required' and not keys.get(p):
            continue
        if p == 'searxng' and not cfg.get('searxng_url'):
            continue
        out.append(p)
    return out


def search_test(provider, keys, cfg, log):
    f = Fetcher(log, delay=0.2)
    t0 = time.time()
    try:
        res = search_web(provider, 'sketchup sofa model', '', keys, f, cfg, count=5)
        return {'ok': True, 'provider': provider, 'count': len(res), 'ms': int((time.time() - t0) * 1000),
                'sample': [r.get('title') for r in res[:3]]}
    except QuotaErr as e:
        return {'ok': False, 'provider': provider, 'error': str(e)}
    except Exception as e:
        return {'ok': False, 'provider': provider, 'error': 'Không kết nối được: %s' % e}


FB_TITLE = re.compile(r'\s*[|\-–]\s*Facebook\s*$', re.I)


def fb_scope(url):
    """URL nhóm/trang Facebook → (miền tìm kiếm 'facebook.com/groups/<id>', mã nhóm)."""
    u = urllib.parse.urlparse(url)
    parts = [x for x in u.path.split('/') if x]
    if len(parts) >= 2 and parts[0] == 'groups':
        return 'facebook.com/groups/%s' % parts[1], parts[1]
    if parts:
        return 'facebook.com/%s' % parts[0], parts[0]
    return 'facebook.com', ''


def in_scope(url, gid, is_fb):
    if not url:
        return False
    if not is_fb:
        return True
    u = urllib.parse.urlparse(url)
    if not re.search(r'(^|\.)facebook\.com$', (u.hostname or '').lower()):
        return False
    return not gid or ('/%s/' % gid.lower()) in (u.path.lower() + '/') or ('/%s' % gid.lower()) in u.path.lower()


def group_name_from(results, gid):
    """Tên thật của nhóm từ tiêu đề kết quả tìm kiếm (“Tên nhóm | Facebook”) — chỉ khi kết quả là trang gốc của nhóm."""
    for r in results:
        u = urllib.parse.urlparse(r.get('url') or '')
        parts = [x for x in u.path.split('/') if x]
        if gid and len(parts) == 2 and parts[0] == 'groups' and parts[1].lower() == gid.lower():
            t = FB_TITLE.sub('', strip_html(r.get('title') or '')).strip()
            if t and t.lower() not in ('facebook', 'log in or sign up to view', 'đăng nhập facebook'):
                return t[:120]
    return None


def post_title(title, snippet):
    t = FB_TITLE.sub('', strip_html(title or '')).strip()
    if not t or len(t) < 4 or re.match(r'^(facebook|đăng nhập|log in)', t, re.I):
        t = (snippet or '').strip().split('\n')[0][:120]
    return t[:200]


def run_index(source, f, st, prog, log, mode, limit, keys):
    cfg = keys.get('_search') or {}
    provs = providers_for(cfg, keys)
    if not provs:
        raise ValueError('Chưa bật công cụ tìm kiếm nào (Cài đặt › Tài khoản thư viện › Công cụ tìm kiếm). Tavily dùng được không cần key.')
    is_fb = source['type'].startswith('facebook')
    scope, gid = fb_scope(source['url']) if is_fb else ((urllib.parse.urlparse(source['url']).netloc + urllib.parse.urlparse(source['url']).path).rstrip('/'), '')
    f.delay = max(f.delay, 1.1)
    dead, total, seen = set(), 0, set(st.get('seen', []))
    per = {p: 0 for p in provs}
    terms = QUERIES if not gid else [gid] + QUERIES
    for n, q in enumerate(terms):
        if total >= limit:
            break
        prog({'phase': 'Đang tìm bài công khai đã được lập chỉ mục', 'done': n, 'total': len(terms)})
        res = None
        for p in provs:
            if p in dead:
                continue
            try:
                query = q if SEARCH_INFO[p]['site_op'] else ('facebook group %s %s' % (gid, q) if is_fb else '%s %s' % (scope, q))
                res = search_web(p, query, scope, keys, f, cfg)
                per[p] += 1
                break
            except QuotaErr as e:
                log('%s: %s — chuyển sang công cụ tìm kiếm khác' % (SEARCH_INFO[p]['name'], e))
                dead.add(p)
            except Exception as e:
                log('%s lỗi với “%s”: %s' % (SEARCH_INFO[p]['name'], q, e))
                break
        if res is None:
            if len(dead) == len(provs):
                log('Tất cả công cụ tìm kiếm đều không dùng được (key/hạn mức).')
                break
            continue
        if is_fb and not st.get('group_name'):
            name = group_name_from(res, gid)
            if name:
                st['group_name'] = name
                log('Tên nhóm: %s' % name)
        batch = []
        for r in res:
            url = (r.get('url') or '').split('#')[0]
            if not in_scope(url, gid, is_fb) or url in seen:
                continue
            u = urllib.parse.urlparse(url)
            if is_fb and len([x for x in u.path.split('/') if x]) <= 2:  # trang gốc của nhóm, không phải bài viết
                continue
            seen.add(url)
            desc = strip_html(r.get('snippet') or '')
            th = r.get('thumb') if isinstance(r.get('thumb'), str) and r.get('thumb', '').startswith('https://') else None
            batch.append(item_from(source, hashlib.sha1(url.encode()).hexdigest()[:16], post_title(r.get('title'), desc), url, th,
                                   desc, [], extract_links(desc), find_password(desc)))
        total += len(batch)
        if batch:
            yield batch
    st['seen'] = list(seen)[-5000:]
    st['providers_used'] = {SEARCH_INFO[p]['name']: c for p, c in per.items() if c}
    log('Công cụ tìm kiếm đã dùng: %s' % (', '.join('%s (%d lượt)' % (k, v) for k, v in st['providers_used'].items()) or 'không có'))


FB_BOILER = re.compile(r'^(link|lin|mk|pass|tải|download)\b.{0,30}(bình luận|cmt|comment|dưới|ib|inbox)|^(xem thêm|see more)', re.I)


def fb_title(text):
    """Tên model từ nội dung bài: câu đầu có nghĩa (bỏ “Link ở bình luận…”, dòng quá ngắn, link)."""
    parts = [x.strip(' .,-–:!') for x in re.split(r'[\n]|(?<=[.!?])\s+', text or '') if x.strip(' .,-–:!')]
    good = [x for x in parts if len(x) >= 12 and not URL_RX.match(x) and not FB_BOILER.search(x)]
    t = (good or parts or ['Bài viết Facebook'])[0]
    t = re.sub(r'^(quá đẹp|đẹp quá)\s+(anh em|ae)\s*ạ?\s*,?\s*', '', t, flags=re.I) or t
    return t[:120]


# ---- Facebook: bài viết NGƯỜI DÙNG tự lưu khi đang xem nhóm (đã đăng nhập thủ công trong cửa sổ plugin)
def fb_items(source, posts):
    out = []
    for p in posts[:200]:
        text = (p.get('text') or '').strip()
        url = (p.get('url') or '').split('?')[0]
        if not url.startswith('https://') or not text and not p.get('images'):
            continue
        links = []
        seen = set()
        for l in list(p.get('links') or []) + [m.group(0) for m in URL_RX.finditer(text)]:
            l = l.rstrip('.,;)')
            k = classify_link(l)
            if k and l not in seen:
                seen.add(l)
                links.append({'url': l, 'kind': k, 'text': ''})
        text = re.sub(r'\s*…\s*(Xem thêm|See more)\s*$', '…', text)
        title = fb_title(text)
        imgs = [i for i in (p.get('images') or []) if isinstance(i, str) and i.startswith('https://')]
        key = hashlib.sha1(url.encode()).hexdigest()[:16]
        it = item_from(source, key, title, url, imgs[0] if imgs else None, text, [], links, find_password(text))
        it['images'] = imgs[:6]
        out.append(it)
    return out


METHODS = {'wp_rest': run_wp, 'sitemap': run_sitemap}
KEYED = {'gdrive': run_gdrive, 'index': run_index}


def crawl(source, mode, limit, keys, prog, log, state_path, store):
    """Chạy trích xuất; store(items) lưu vào kho dữ liệu. Trả thống kê."""
    st = json.load(open(state_path, encoding='utf-8')) if os.path.exists(state_path) else {}
    if mode == 'full':
        st = {}
    f = Fetcher(log, delay=0.6 if source.get('method') in ('wp_rest', 'gdrive') else 1.5)
    method = source.get('method')
    if method not in METHODS and method not in KEYED:
        chk = check(source, f, keys)
        method = chk['method']
        if not chk['ok']:
            raise ValueError(chk['note'])
    gen = METHODS[method](source, f, st, prog, log, mode, limit) if method in METHODS else KEYED[method](source, f, st, prog, log, mode, limit, keys)
    found = links = 0
    for batch in gen:
        store(batch)
        found += len(batch)
        links += sum(1 for it in batch if it['links'])
        prog({'found': found, 'with_links': links})
    st['last_sync'] = int(time.time())
    st['method'] = method
    tmp = state_path + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as fp:
        json.dump(st, fp)
    os.replace(tmp, state_path)
    return {'method': method, 'found': found, 'with_links': links, 'requests': f.count, 'last_sync': st['last_sync'],
            'group_name': st.get('group_name'), 'providers_used': st.get('providers_used')}
