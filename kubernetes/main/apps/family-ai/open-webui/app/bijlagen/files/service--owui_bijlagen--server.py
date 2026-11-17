"""Studio-only authenticated OCR worker. Run as python -m service.owui_bijlagen.server.

Bind address is an explicit deployment setting; Ollama itself stays on loopback.
No request/image logs, no upload persistence. Reader uses the shared vision lock.
"""
import hmac
import threading
import time
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from service.studiemateriaal.core import StudioReader
from service.owui_bijlagen import MAX_BYTES, MAX_PDF_PAGES, MAX_TEXT, PHOTO_MAX_SIDE, Weigering, sanitize

SECONDS_PER_PAGE = 2     # a page read by Apple Vision, rendering included: measured (VALIDATION.md); pages that need the model are bounded by the deadline below
CLIENT_BUDGET = 280      # Open WebUI gives up at 300 s
DEADLINE_MARGIN = 10     # the reader stops starting model pages this long before the client gives up
KEEP_ALIVE = '20m'       # the vision model stays loaded this long after a page; '0' unloads at once (the old behaviour)
OCR_MODEL = 'glm-ocr:latest'   # used for pages Apple Vision cannot read, when installed; else the vision model


def reason(error):
    """Refusal code for the overlay (WORKER_REASONS there). Sent in a header and in the body, not in the reason phrase."""
    code = error.args[0] if isinstance(error, ValueError) and error.args else ''
    if code == 'page_limit':
        return 'page_limit'
    if code == 'ocr_incomplete':
        return 'unreadable'
    if isinstance(error, Weigering) or code in ('invalid_image', 'image_limit', 'image_format', 'attachment_size'):
        return code if code in ('invalid_image', 'image_limit', 'image_format', 'heic', 'attachment_size') else 'invalid_image'
    return 'failed'


def refuse(handler, error):
    code = reason(error)
    body = json.dumps({'reden': code}).encode()
    handler.send_response(422, 'Unprocessable Entity')
    handler.send_header('X-Bijlage-Reden', code)
    handler.send_header('Content-Type', 'application/json')
    handler.send_header('Content-Length', str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


MARK_TOO_LONG = '[pagina %d: niet meer gelezen, het bestand is te lang]'
TEXT_RESERVE = 5_000     # room left in the 200,000 character message limit for the question and the attachment heading


def join_pages(pages, limit=MAX_TEXT - TEXT_RESERVE):
    """Join the page texts; when they would pass the text limit, cut on a page boundary and say from which page on
    (Argus L3/N1: 40 dense pages are about 240,000 characters). A first page that alone is too long stays an error."""
    out, size = [], 0
    for i, page in enumerate(pages):
        marker = MARK_TOO_LONG % (i + 1)
        if size + len(page) + 2 + len(marker) > limit and (i > 0 or len(page) + len(marker) > limit):
            if i == 0:
                break
            out.append(marker)
            return '\n\n'.join(out)
        out.append(page); size += len(page) + 2
    return '\n\n'.join(out)


def handler(reader, token, inflight=1, waiters=3, wait_s=240):
    if not token:
        raise ValueError('missing_token')
    # Argus R1, bounded: one transcription at a time; at most `waiters` requests wait (each up to `wait_s`, below the
    # client's 300 s), anything beyond that answers 503 at once. Open WebUI processes a PDF in the background while a
    # photo is transcribed synchronously, so a strict "busy -> 503" failed a normal PDF + photo upload (canary p3,
    # 13-11). Threads stay bounded: inflight + waiters.
    slots = threading.BoundedSemaphore(inflight)
    queue = threading.BoundedSemaphore(inflight + waiters)

    class Handler(BaseHTTPRequestHandler):
        timeout = 30   # Argus C3: a slow client cannot hold a thread

        def log_message(self, *args):
            pass

        def do_POST(self):
            if self.path != '/transcribe' or not hmac.compare_digest(
                    self.headers.get('Authorization', ''), 'Bearer ' + token):
                self.send_error(403); return
            started = time.monotonic()
            if not queue.acquire(blocking=False):
                self.send_error(503, 'Busy'); return
            if not slots.acquire(timeout=wait_s):
                queue.release()
                self.send_error(503, 'Busy'); return
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
                        pages = len(doc)
                        if not 1 <= pages <= MAX_PDF_PAGES:
                            raise ValueError('page_limit')
                    finally:
                        doc.close()
                else:
                    pages = 1
                # Argus B1: never start a job whose answer would arrive after the client gave up
                if time.monotonic() - started + SECONDS_PER_PAGE * pages > CLIENT_BUDGET:
                    self.send_error(503, 'Busy'); return
                clean = data if ext == '.pdf' else sanitize(data, 'image.png', PHOTO_MAX_SIDE)
                text = join_pages(reader.read(clean, ext, deadline=started + CLIENT_BUDGET - DEADLINE_MARGIN))
                if not text.strip() or len(text) > MAX_TEXT:
                    raise ValueError('text')
                body = json.dumps({'text': text}).encode()
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers(); self.wfile.write(body)
            except Exception as error:
                refuse(self, error)
            finally:
                slots.release()
                queue.release()
    return Handler


def read_token():
    """Argus S2: the token comes from a 0600 file named in the environment, never through argv."""
    path = os.environ['OWUI_ATTACHMENT_VISION_TOKEN_FILE']
    if os.stat(path).st_mode & 0o077:
        raise ValueError('token_file_mode')
    with open(path) as f:
        return f.read().strip()


def main():
    reader = StudioReader(os.environ['OWUI_ATTACHMENT_VISION_STATE'],
                          os.environ.get('OWUI_ATTACHMENT_VISION_MODEL', 'qwen3-vl:8b'),
                          keep_alive=os.environ.get('OWUI_ATTACHMENT_KEEP_ALIVE', KEEP_ALIVE),
                          ocr_model=os.environ.get('OWUI_ATTACHMENT_OCR_MODEL', OCR_MODEL),
                          vocr=os.environ.get('OWUI_ATTACHMENT_VOCR') or os.path.join(os.environ['OWUI_ATTACHMENT_VISION_STATE'], 'vocr'))
    server = ThreadingHTTPServer((os.environ['OWUI_ATTACHMENT_BIND'],
                                 int(os.environ.get('OWUI_ATTACHMENT_PORT', '8099'))),
                                handler(reader, read_token()))
    server.serve_forever()


if __name__ == '__main__':
    main()
