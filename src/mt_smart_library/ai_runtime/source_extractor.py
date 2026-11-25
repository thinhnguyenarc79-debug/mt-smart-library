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
        if not keys.get('brave'):
            return {'method': 'index', 'ok': False, 'status': 'need_key',
                    'note': 'Facebook không cho truy cập tự động (Groups API đã gỡ). Có thể tìm bài CÔNG KHAI đã được máy tìm kiếm lập chỉ mục — cần Brave Search API key.'}
        return {'method': 'index', 'ok': True, 'status': 'ok', 'note': 'Tìm bài công khai đã được Brave Search lập chỉ mục (không đọc được bài riêng tư trong nhóm).'}
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


# ---- Chỉ mục máy tìm kiếm (Brave Search API) — bài công khai đã được lập chỉ mục
BRAVE = os.environ.get('MT_TEST_BRAVE_BASE', 'https://api.search.brave.com/res/v1/web/search')
QUERIES = ['sketchup', 'skp model', 'sofa sketchup', 'ghế sketchup', 'bàn sketchup', 'giường sketchup', 'tủ sketchup',
           'đèn sketchup', 'cây sketchup', 'nội thất sketchup', 'ngoại thất sketchup', 'model 3d free']


def run_index(source, f, st, prog, log, mode, limit, keys):
    key = keys.get('brave')
    if not key:
        raise ValueError('Cần Brave Search API key.')
    f.delay = max(f.delay, 1.1)  # gói miễn phí: 1 yêu cầu/giây
    u = urllib.parse.urlparse(source['url'])
    scope = (u.netloc + u.path).rstrip('/')
    total = 0
    for n, q in enumerate(QUERIES):
        if total >= limit:
            break
        prog({'phase': 'Đang tìm bài công khai đã được lập chỉ mục', 'done': n, 'total': len(QUERIES)})
        try:
            d = f.json(BRAVE + '?' + urllib.parse.urlencode({'q': 'site:%s %s' % (scope, q), 'count': 20}),
                       headers={'X-Subscription-Token': key})
        except HttpErr as e:
            log('Brave Search HTTP %s cho “%s”' % (e.code, q))
            if e.code in (401, 403, 429):
                break
            continue
        batch = []
        for r in (d.get('web') or {}).get('results', []):
            url = r.get('url') or ''
            if scope.split('/')[0] not in url:
                continue
            desc = strip_html(r.get('description', '')) + ' ' + ' '.join(strip_html(x) for x in r.get('extra_snippets', []) or [])
            thumb = (r.get('thumbnail') or {}).get('src') or (r.get('thumbnail') or {}).get('original')
            batch.append(item_from(source, hashlib.sha1(url.encode()).hexdigest()[:16], strip_html(r.get('title', '')), url, thumb,
                                   desc.strip(), [], extract_links(desc), find_password(desc)))
        total += len(batch)
        if batch:
            yield batch


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
    st['last_sync'] = int(time.time())
    st['method'] = method
    tmp = state_path + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as fp:
        json.dump(st, fp)
    os.replace(tmp, state_path)
    return {'method': method, 'found': found, 'with_links': links, 'requests': f.count, 'last_sync': st['last_sync']}
