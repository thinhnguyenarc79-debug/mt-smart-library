# -*- coding: utf-8 -*-
"""Máy chủ cục bộ cho kiểm thử bộ trích xuất (không có mạng ra ngoài trong máy test).
Mô phỏng ĐÚNG giao thức thật đã kiểm chứng: WordPress REST API (/wp-json/wp/v2/posts|categories|media, modified_after, 400 khi quá trang),
robots.txt + sitemap index/urlset, Google Drive API v3 files.list, Brave Search API (web.results). Nội dung bài viết là dữ liệu kiểm thử."""
import io
import json
import sys
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from PIL import Image, ImageDraw

PORT = int(sys.argv[1])
BASE = 'http://127.0.0.1:%d' % PORT


def png(color, shape):
    im = Image.new('RGB', (300, 300), 'white')
    d = ImageDraw.Draw(im)
    (d.ellipse if shape == 'circle' else d.rectangle)((40, 40, 260, 260) if shape == 'circle' else (20, 110, 280, 190), fill=color)
    b = io.BytesIO()
    im.save(b, 'PNG')
    return b.getvalue()


IMGS = {'/img/1.png': png('red', 'circle'), '/img/2.png': png('blue', 'rect'), '/img/3.png': png('green', 'circle')}
POSTS = [
    {'id': 101, 'date': '2026-11-20T10:00:00', 'modified': '2026-11-20T10:00:00', 'title': {'rendered': '21805. Classic Tufted Chesterfield Sofa 3D Model SketchUp Download'},
     'link': BASE + '/21805-chesterfield-sofa/', 'featured_media': 11, 'categories': [3],
     'excerpt': {'rendered': '<p>Free Sketchup sofa model.</p>'},
     'content': {'rendered': '<p>Link download: Copy and paste link to web browser &#8211; Pass unzip: sketchup.cgtips.org</p><p>https://link.example.org/5RkcdHPqxe</p>'}},
    {'id': 102, 'date': '2026-11-21T10:00:00', 'modified': '2026-11-24T08:00:00', 'title': {'rendered': 'Bàn ăn gỗ óc chó 6 ghế &#8211; SketchUp'},
     'link': BASE + '/ban-an-go/', 'featured_media': 12, 'categories': [4],
     'excerpt': {'rendered': '<p>Bàn ăn hiện đại.</p>'},
     'content': {'rendered': '<p><a href="https://www.dropbox.com/s/abc123/ban-an.skp?dl=0">Tải về</a> <a href="https://www.facebook.com/share">Chia sẻ</a></p>'}},
]


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, body, ctype='application/json'):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        elif isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = dict(urllib.parse.parse_qsl(u.query))
        p = u.path
        if p == '/robots.txt':
            return self.send(200, 'User-agent: *\nDisallow: /wp-admin/\nDisallow: /private/\nCrawl-delay: 0.05\nSitemap: %s/sitemap.xml\n' % BASE, 'text/plain')
        if p in IMGS:
            return self.send(200, IMGS[p], 'image/png')
        # ---- WordPress REST
        if p == '/wp-json/wp/v2/categories':
            return self.send(200, [{'id': 3, 'name': 'Sofa'}, {'id': 4, 'name': 'Bàn ăn'}])
        if p == '/wp-json/wp/v2/media':
            ids = q.get('include', '').split(',')
            return self.send(200, [{'id': int(i), 'source_url': BASE + '/img/%d.png' % (int(i) - 10), 'media_details': {}} for i in ids if i])
        if p == '/wp-json/wp/v2/posts':
            if int(q.get('page', 1)) > 1:
                return self.send(400, {'code': 'rest_post_invalid_page_number'})
            posts = [x for x in POSTS if 'modified_after' not in q or x['modified'] > q['modified_after']]
            if 'per_page' in q and q['per_page'] == '1':
                posts = posts[:1]
            return self.send(200, [{k: v for k, v in x.items()} for x in posts])
        # ---- sitemap site
        if p == '/sitemap.xml':
            return self.send(200, '<?xml version="1.0"?><sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">'
                                  '<sitemap><loc>%s/page-sitemap.xml</loc></sitemap><sitemap><loc>%s/model-sitemap.xml</loc></sitemap></sitemapindex>' % (BASE, BASE), 'application/xml')
        if p == '/model-sitemap.xml':
            urls = ['/model/den-tha.html', '/model/khong-anh.html', '/private/an.html'] + ['/model/m%d.html' % i for i in range(int(q.get('n', 0)))]
            body = ''.join('<url><loc>%s%s</loc><lastmod>2026-11-2%d</lastmod></url>' % (BASE, x, i % 9) for i, x in enumerate(urls))
            return self.send(200, '<?xml version="1.0"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">%s</urlset>' % body, 'application/xml')
        if p == '/page-sitemap.xml':
            return self.send(200, '<?xml version="1.0"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"><url><loc>%s/gioi-thieu.html</loc></url></urlset>' % BASE, 'application/xml')
        if p == '/model/den-tha.html':
            return self.send(200, '<html><head><title>x</title><meta property="og:title" content="Đèn thả đồng Bắc Âu - SketchUp">'
                                  '<meta property="og:image" content="/img/3.png"><meta property="og:description" content="Model đèn thả miễn phí.">'
                                  '<meta property="article:section" content="Đèn"></head><body><a href="https://cdn.example.net/files/den-tha.zip">Download SKP</a>'
                                  '<p>Mật khẩu: mtdesign</p></body></html>', 'text/html; charset=utf-8')
        if p.startswith('/model/'):
            return self.send(200, '<html><head><title>Không có ảnh</title></head><body>…</body></html>', 'text/html')
        if p in ('/gioi-thieu.html', '/private/an.html'):
            return self.send(200, '<html><head><meta property="og:title" content="Giới thiệu"><meta property="og:image" content="/img/2.png"></head></html>', 'text/html')
        # ---- Google Drive API v3 (files.list)
        if p == '/drive/v3/files':
            if q.get('key') != 'GKEY':
                return self.send(403, {'error': {'code': 403, 'message': 'API key not valid'}})
            parent = q['q'].split("'")[1]
            if parent == 'ROOTFOLDER1234':
                return self.send(200, {'files': [
                    {'id': 'SUBFOLDER12345', 'name': 'Sofa', 'mimeType': 'application/vnd.google-apps.folder'},
                    {'id': 'FILE1', 'name': 'Tủ áo gỗ.skp', 'mimeType': 'application/octet-stream', 'size': '1234',
                     'webViewLink': 'https://drive.google.com/file/d/FILE1/view'},
                    {'id': 'IMG1', 'name': 'Tủ áo gỗ.jpg', 'mimeType': 'image/jpeg', 'thumbnailLink': BASE + '/img/2.png'},
                    {'id': 'DOC1', 'name': 'readme.txt', 'mimeType': 'text/plain'}]})
            if parent == 'SUBFOLDER12345':
                return self.send(200, {'files': [{'id': 'FILE2', 'name': 'Sofa góc L.zip', 'mimeType': 'application/zip', 'size': '999',
                                                  'thumbnailLink': BASE + '/img/1.png'}]})
            return self.send(404, {'error': {'code': 404}})
        # ---- Brave Search API
        if p == '/brave':
            if self.headers.get('X-Subscription-Token') != 'BKEY':
                return self.send(401, {'type': 'ErrorResponse'})
            if 'sketchup' in q.get('q', '') and q['q'].startswith('site:www.facebook.com/groups/thuvien3d'):
                return self.send(200, {'web': {'results': [
                    {'url': 'https://www.facebook.com/groups/thuvien3d/posts/111', 'title': 'Chia sẻ model giường ngủ SketchUp miễn phí',
                     'description': 'Link tải: https://www.mediafire.com/file/abc/giuong.zip/file', 'thumbnail': {'src': BASE + '/img/1.png'}},
                    {'url': 'https://www.example.com/not-facebook', 'title': 'Ngoài phạm vi'}]}})
            return self.send(200, {'web': {'results': []}})
        self.send(404, 'not found', 'text/plain')


srv = ThreadingHTTPServer(('127.0.0.1', PORT), H)
print('READY', flush=True)
srv.serve_forever()
