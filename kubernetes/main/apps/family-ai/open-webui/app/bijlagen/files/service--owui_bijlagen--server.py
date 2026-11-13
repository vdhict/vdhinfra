"""Studio-only authenticated OCR worker. Run as python -m service.owui_bijlagen.server.

Bind address is an explicit deployment setting; Ollama itself stays on loopback.
No request/image logs, no upload persistence. Reader uses the shared vision lock.
"""
import hmac
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from service.studiemateriaal.core import StudioReader
from service.owui_bijlagen import MAX_BYTES, MAX_TEXT, sanitize

MAX_PDF_PAGES = 20


def handler(reader, token):
    if not token:
        raise ValueError('missing_token')
    class Handler(BaseHTTPRequestHandler):
        timeout = 30   # Argus C3: a slow client cannot hold a thread

        def log_message(self, *args):
            pass

        def do_POST(self):
            if self.path != '/transcribe' or not hmac.compare_digest(
                    self.headers.get('Authorization', ''), 'Bearer ' + token):
                self.send_error(403); return
            try:
                n = int(self.headers.get('Content-Length', '0'))
                if not 0 < n <= MAX_BYTES:
                    raise ValueError('size')
                data = self.rfile.read(n)
                if len(data) != n:
                    raise ValueError('short_read')
                ext = '.pdf' if data.startswith(b'%PDF-') else '.png'
                if ext == '.pdf':   # Argus C3: interactive page cap
                    import pypdfium2 as pdfium
                    doc = pdfium.PdfDocument(data)
                    try:
                        if not 1 <= len(doc) <= MAX_PDF_PAGES:
                            raise ValueError('page_limit')
                    finally:
                        doc.close()
                clean = data if ext == '.pdf' else sanitize(data, 'image.png')
                text = '\n\n'.join(reader.read(clean, ext))
                if not text.strip() or len(text) > MAX_TEXT:
                    raise ValueError('text')
                body = json.dumps({'text': text}).encode()
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers(); self.wfile.write(body)
            except Exception:
                self.send_error(422, 'Transcription failed')
    return Handler


def main():
    reader = StudioReader(os.environ['OWUI_ATTACHMENT_VISION_STATE'],
                          os.environ.get('OWUI_ATTACHMENT_VISION_MODEL', 'qwen3-vl:8b'))
    server = ThreadingHTTPServer((os.environ['OWUI_ATTACHMENT_BIND'],
                                 int(os.environ.get('OWUI_ATTACHMENT_PORT', '8099'))),
                                handler(reader, os.environ['OWUI_ATTACHMENT_VISION_TOKEN']))
    server.serve_forever()


if __name__ == '__main__':
    main()
