"""Open WebUI v0.11.4 boundary. No Hermes safety files are modified.

Source references refer to the SHA-pinned wheel files in deploy/owui-bijlagen/source.json.
"""
import asyncio
import base64
import copy
import contextvars
import io
import json
import os
import threading
from pathlib import Path
import urllib.error
import urllib.request

MAX_BYTES = 25 * 1024 * 1024
MAX_TEXT = 200_000
MAX_PIXELS = 50_000_000      # phone cameras (48 MP); the decompression-bomb guard stays: checked on the header, before any decode
PHOTO_MAX_SIDE = 2400        # long side of a photo sent to the vision model; qwen3-vl sees the same 4072 image tokens at 2400 and 3200 (VALIDATION.md)
MAX_PDF_PAGES = 40           # 40 scanned pages took 21.9 s through Vision plus 4 model pages (VALIDATION.md); pages beyond the deadline get a marker
FILE_WAIT_S = 240            # a chat message waits this long for a family member's file to finish processing
FILE_POLL_S = 1.0
MAX_DECODES = 2              # image decodes at once in this process (memory, Argus C3)
DECODE_SLOTS = threading.BoundedSemaphore(MAX_DECODES)
GROUPS = {'owui-profiel-1', 'owui-profiel-2', 'owui-profiel-3', 'owui-profiel-4'}

UPLOAD_USER = contextvars.ContextVar('attachment_upload_user', default=None)

WAT_WERKT = "Een foto (JPEG of PNG) of een PDF tot %d pagina's werkt wel." % MAX_PDF_PAGES
MELDINGEN = {
    'heic': "Deze foto is in het iPhone-formaat HEIC en dat kan ik nog niet lezen. Maak een schermafbeelding van de foto, of kies op de iPhone bij Instellingen, Camera, Formaten 'Meest compatibel' voor nieuwe foto's.",
    'attachment_size': 'Dit bestand is te groot (meer dan 25 MB). ' + WAT_WERKT,
    'page_limit': "Deze PDF heeft te veel pagina's. Een PDF tot %d pagina's werkt wel." % MAX_PDF_PAGES,
    'vision_busy': 'Het lezen van bijlagen is nu druk. Probeer het over een minuut nog eens.',
    'vision_down': 'Het lezen van de bijlage lukt nu niet. Probeer het over een paar minuten nog eens.',
    'unreadable': 'De tekst op deze foto of pagina is niet goed te lezen. Probeer een scherpere foto met goed licht. ' + WAT_WERKT,
    'file_wait': 'Het bestand wordt nog gelezen. Wacht even en stuur je bericht daarna opnieuw.',
    'file_failed': 'Het bestand kon niet worden gelezen. ' + WAT_WERKT,
}
STANDAARD_MELDING = 'Dit bestand kan ik niet lezen. ' + WAT_WERKT


class Weigering(ValueError):
    """A refusal the user can act on. args[0] is the internal code; str() and .detail are the Dutch sentence.

    Open WebUI shows HTTPException.detail from the upload route and str(e) from background processing, and replaces
    every other exception by 'Error uploading file'; this class is converted to an HTTPException where the route needs it.
    """
    def __init__(self, code):
        super().__init__(code)
        self.code = code
        self.detail = MELDINGEN.get(code, STANDAARD_MELDING)

    def __str__(self):
        return self.detail


def http_fout(error):
    from fastapi import HTTPException
    return HTTPException(status_code=400, detail=error.detail)


async def familie(user_id, db=None):
    from open_webui.models.groups import Groups
    return any(g.name in GROUPS for g in await Groups.get_groups_by_member_id(user_id, db=db))


async def scoped(user_id, db=None):
    from open_webui.models.groups import Groups
    # Explicit per-group activation keeps the image rollout itself from enabling
    # all four profiles before the canary. Global defaults are not changed/read.
    try:
        groups = await Groups.get_groups_by_member_id(user_id, db=db)
    except Exception:
        # Argus S1 (N4, second half): a lookup failure means "not activated" - no transcription, and the upload still
        # works; prepare_upload already treats the uploader as family, so storage stays sanitized.
        return False
    return any(g.name in GROUPS and ((g.permissions or {}).get('chat') or {}).get('file_upload') is True
               for g in groups)


IMAGE_SUFFIXES = {'.jpg', '.jpeg', '.png', '.webp', '.gif', '.heic', '.heif', '.tif', '.tiff', '.bmp'}
HEIF_BRANDS = {b'heic', b'heix', b'heim', b'heis', b'hevc', b'hevx', b'mif1', b'msf1'}


def is_heif(data):
    """HEIC/HEIF by its container header, never by name; only used to refuse it."""
    return data[4:8] == b'ftyp' and data[8:12] in HEIF_BRANDS


def looks_like_image(data):
    from PIL import Image, UnidentifiedImageError
    if is_heif(data):
        return True
    try:
        with Image.open(io.BytesIO(data)):
            return True
    except UnidentifiedImageError:
        return False


def sanitize(data, filename='', max_side=None):
    """Decode pixels and create a fresh image; retain neither EXIF nor PNG text/XMP/ICC.

    storage/provider.py:65-76 writes bytes directly. Hook BEFORE this write, including
    process=false uploads and Capture's base64 -> upload_file_handler path.
    HEIC/HEIF is refused with its own sentence (no native decoder in this process). With max_side the long side is reduced to it
    (never enlarged); a photo from a phone camera (up to MAX_PIXELS) is accepted instead of refused.
    """
    from PIL import Image, ImageOps, UnidentifiedImageError
    if not 0 < len(data) <= MAX_BYTES:
        raise Weigering('attachment_size')
    if is_heif(data):
        # Argus 17-11 (C1): no native HEIC parser inside the open-webui process; phase 2 is separate (Studio, sandboxed).
        raise Weigering('heic')
    try:
        raw = Image.open(io.BytesIO(data))
    except UnidentifiedImageError:
        if Path(filename).suffix.lower() in IMAGE_SUFFIXES:
            raise Weigering('invalid_image')
        return data
    with raw:
        if raw.width * raw.height > MAX_PIXELS or (raw.format != 'MPO' and getattr(raw, 'n_frames', 1) != 1):
            raise Weigering('image_limit')
        fmt = 'JPEG' if raw.format == 'MPO' else raw.format
        raw.seek(0)
        if fmt not in {'JPEG', 'PNG', 'WEBP', 'GIF', 'TIFF', 'BMP'}:
            raise Weigering('image_format')
        with DECODE_SLOTS:   # Argus 17-11 (C3): a 50 MP decode peaks at 590 to 760 MiB; at most MAX_DECODES at once
            if max_side and fmt == 'JPEG':
                raw.draft('RGB', (max_side, max_side))   # the decoder itself skips to 1/2, 1/4, 1/8: far less memory for 48 MP
            image = ImageOps.exif_transpose(raw).convert('RGB')
            if max_side:
                image.thumbnail((max_side, max_side), Image.LANCZOS)
            clean = Image.new('RGB', image.size)
            clean.paste(image)
            del image
            out = io.BytesIO()
            clean.save(out, format=fmt, **({'quality': 90} if fmt == 'JPEG' else {}))
    return out.getvalue()


WORKER_REASONS = {'page_limit', 'unreadable', 'invalid_image', 'image_limit', 'image_format', 'heic', 'attachment_size'}


def worker_reason(error):
    """The worker's refusal code. It travels in the X-Bijlage-Reden header and in the JSON body, never in the HTTP reason
    phrase: Caddy rewrites that (Argus 17-11, C2). 503 is the busy queue. Anything else is 'vision_down'."""
    if error.code == 503:
        return 'vision_busy'
    code = (error.headers.get('X-Bijlage-Reden') if error.headers else None) or ''
    if not code:
        try:
            code = json.loads(error.read(2048)).get('reden', '')
        except Exception:
            code = ''
    return code if isinstance(code, str) and code in WORKER_REASONS else 'vision_down'


def vision(data):
    """Explicit backend setting; no automatic cloud fallback or arbitrary image URL fetch.

    local-studio speaks the authenticated transcription service in server.py, which
    uses StudioReader and its existing vision.lock. It is the ONLY backend (Argus C2, chg-2026-10-20-010): any other
    value raises, so a cloud OCR path for children's photos needs a code change and its own review, never a setting.
    The worker sits behind the Studio's Caddy on 443, so the URL must be https (Argus C3).
    """
    backend = os.environ.get('OWUI_ATTACHMENT_VISION_BACKEND', 'local-studio')
    if backend != 'local-studio':
        raise ValueError('vision_backend')
    url = os.environ['OWUI_ATTACHMENT_VISION_URL']
    token = os.environ['OWUI_ATTACHMENT_VISION_TOKEN']
    if not token or not url.startswith('https://'):
        raise ValueError('vision_config')
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *args, **kwargs):
            raise ValueError('vision_redirect')
    http = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    req = urllib.request.Request(url, data=data, headers={'Authorization': 'Bearer ' + token,
                                                        'Content-Type': 'application/octet-stream'})
    try:
        with http.open(req, timeout=300) as response:   # Argus C3/R1: 20 pages x ~11.5 s fits, still under 600
            result = json.loads(response.read(MAX_TEXT * 6 + 1024))
    except urllib.error.HTTPError as error:
        raise Weigering(worker_reason(error))
    except OSError:   # connection refused, reset, timeout
        raise Weigering('vision_down')
    text = result.get('text')
    if not isinstance(text, str) or not text.strip() or len(text) > MAX_TEXT:
        raise ValueError('vision_incomplete')
    return text


async def prepare_upload(file, user, metadata):
    """Image -> plain text before OWUI stores anything; documents use OWUI extraction.

    routers/files.py:127-195 extracts documents; :374-416 stores raw bytes first.
    Replace image uploads for the four profiles with transcription .txt, so both
    new uploads and Attach Files use document context rather than Hermes file parts.
    """
    UPLOAD_USER.set(None)
    try:
        fam = await familie(user.id)
    except Exception:
        # Argus N4: a group lookup failure must not break every upload; treat the user as family, so the storage
        # wrapper sanitizes (privacy-safe) and non-family uploads still work apart from the image edge cases.
        fam = True
    if fam:
        UPLOAD_USER.set(user.id)
    if not await scoped(user.id):
        return
    data = await file.read(MAX_BYTES + 1)
    try:
        clean = await asyncio.to_thread(sanitize, data, file.filename or '', PHOTO_MAX_SIDE)
        if not looks_like_image(clean):
            await file.seek(0)
            return
        text = await asyncio.to_thread(vision, clean)
    except Weigering as error:
        raise http_fout(error)
    file.file = io.BytesIO(text.encode())
    file.filename = Path(file.filename or 'capture').stem + '.txt'
    # Starlette UploadFile.content_type is derived from immutable Headers.
    from starlette.datastructures import Headers
    file.headers = Headers({'content-type': 'text/plain'})
    file.size = len(text.encode())
    metadata.pop('file_hash', None)
    return True


def text_only(messages, read_image=None):
    """Flatten multimodal parts into user text; reject every unknown/file part.

    utils/middleware.py:2457-2484 restores DB image parts on replay, and
    :3237-3240 applies retrieved sources. Run AFTER both, before gateway send.
    No attachment content is moved to system: Hermes' pre_llm_call gezin hook
    sees the transcription as user text through its live keyword layer.
    """
    read_image = read_image or vision
    result = copy.deepcopy(messages)
    for message in result:
        content = message.get('content')
        if isinstance(content, list):
            parts = []
            for part in content:
                if part.get('type') == 'text' and isinstance(part.get('text'), str):
                    parts.append(part['text'])
                elif part.get('type') == 'image_url':
                    url = part.get('image_url', {})
                    url = url.get('url', '') if isinstance(url, dict) else url
                    if not isinstance(url, str) or not url.startswith('data:image/') or ';base64,' not in url:
                        raise ValueError('image_must_be_resolved')
                    if len(url) > MAX_BYTES * 4 // 3 + 256:
                        raise ValueError('attachment_size')
                    data = base64.b64decode(url.split(',', 1)[1], validate=True)
                    parts.append('Bijlage (brontekst):\n' + read_image(sanitize(data, '', PHOTO_MAX_SIDE)))
                else:
                    raise ValueError('unsupported_attachment_part')
            message['content'] = '\n\n'.join(parts)
        if not isinstance(message.get('content'), (str, type(None))):
            raise ValueError('unsupported_content')
        if len(message.get('content') or '') > MAX_TEXT:
            raise ValueError('attachment_text_limit')
        message.pop('files', None)
    return result


async def finish_payload(request, form_data, user):
    if await scoped(user.id):
        form_data['messages'] = await asyncio.to_thread(text_only, form_data['messages'])
        form_data.pop('files', None)
        # A site RAG template must not silently omit the uploaded document body.
        extracted = getattr(request.state, 'attachment_text', [])
        last = next((m for m in reversed(form_data['messages']) if m.get('role') == 'user'), None)
        if extracted and last is None:
            raise ValueError('user_message_missing')
        for text in extracted:
            if text not in (last.get('content') or ''):
                last['content'] = (last.get('content') or '') + '\n\nBijlage (brontekst):\n' + text
        if last and len(last.get('content') or '') > MAX_TEXT:
            raise ValueError('attachment_text_limit')
    return form_data


async def ready_file(Files, file_id, user_id, deadline=None):
    """The file record of a family member's attachment, once its processing has finished.

    The browser sends the chat message as soon as the upload call returns, while a PDF or a photo is still being read
    (Atlas 17-11: 3 x 400 file_not_ready_or_not_owned in 4 days, status poll only 3 times). The message now waits for
    it here, up to FILE_WAIT_S, which stays inside the worker's own queue limit; a failed file ends the wait at once.
    """
    loop = asyncio.get_running_loop()
    deadline = deadline or loop.time() + FILE_WAIT_S   # one budget per chat message, shared by all its files

    async def poll():
        while True:
            f = await Files.get_file_by_id(file_id)
            if not f or f.user_id != user_id:
                raise ValueError('file_not_ready_or_not_owned')
            status = (f.data or {}).get('status')
            if status == 'completed':
                return f
            if status == 'failed':
                raise Weigering('file_failed')
            await asyncio.sleep(FILE_POLL_S)
    try:   # the limit covers a stalled database lookup too
        return await asyncio.wait_for(poll(), max(deadline - loop.time(), 0.001))
    except asyncio.TimeoutError:
        raise Weigering('file_wait')


async def prepare_payload(request, form_data, metadata, user):
    if not await scoped(user.id):
        return
    request.state.attachment_user_context = True
    deadline = asyncio.get_running_loop().time() + FILE_WAIT_S
    # Force legacy per request, even if the client overrides saved model params.
    # middleware.py:2606-2628 and :2811: native only offers knowledge as tools.
    metadata.setdefault('params', {})['function_calling'] = 'legacy'
    from open_webui.models.files import Files
    from open_webui.models.knowledge import Knowledges
    remaining, extracted = [], []
    for item in metadata.get('files') or []:
        if item.get('type') == 'collection':
            kb = await Knowledges.get_knowledge_by_id(item.get('id'))
            if not kb or kb.user_id != user.id:
                raise ValueError('knowledge_owner_only')
        elif item.get('type') == 'file':
            f = await ready_file(Files, item.get('id'), user.id, deadline)
            # Do not trust client-supplied file.data.content; retrieval/utils.py:1507.
            item.pop('file', None)
            item['context'] = 'full'
            if not (f.data or {}).get('content', '').strip():
                raise ValueError('file_extraction_empty')
            extracted.append((f.data or {})['content'])
            continue
        remaining.append(item)
    metadata['files'] = remaining
    request.state.attachment_text = extracted
    # Resolve only OWUI-owned image URLs through its permission-checked resolver.
    from open_webui.utils.files import get_image_base64_from_url
    for message in form_data.get('messages', []):
        if isinstance(message.get('content'), list):
            for part in message['content']:
                if part.get('type') == 'image_url':
                    url = part.get('image_url', {})
                    url = url.get('url', '') if isinstance(url, dict) else url
                    if not url.startswith('data:image/'):
                        import re
                        if not re.fullmatch(r'/api/v1/files/[A-Za-z0-9-]+/content', url):
                            raise ValueError('external_image_denied')
                        # The browser may retain image type after the upload was
                        # converted to .txt. Resolve that transcription as text.
                        saved = await Files.get_file_by_id(url.split('/')[-2])
                        if not saved or saved.user_id != user.id:
                            raise ValueError('image_not_owned')
                        if (saved.data or {}).get('status') == 'completed' and saved.filename.endswith('.txt'):
                            content = (saved.data or {}).get('content', '')
                            if not content.strip():
                                raise ValueError('image_extraction_empty')
                            part.clear()
                            part.update(type='text', text='Bijlage (brontekst):\n' + content)
                            continue
                        url = await get_image_base64_from_url(url, user=user)
                        if not url:
                            raise ValueError('image_not_accessible')
                        part['image_url'] = {'url': url}
    # DB replay preserves attachment references, not our transient enriched text.
    # Rehydrate owned documents before discarding the transport-only files field.
    replay = []
    for index, message in enumerate(form_data.get('messages', [])):
        if message.get('role') != 'user':
            continue
        for item in message.get('files') or []:
            if item.get('type') != 'file':
                continue
            try:
                saved = await ready_file(Files, item.get('id'), user.id, deadline)
            except ValueError as error:
                if isinstance(error, Weigering):
                    raise
                raise ValueError('replay_file_not_ready_or_not_owned')
            text = (saved.data or {}).get('content', '')
            if not text.strip():
                raise ValueError('replay_file_extraction_empty')
            replay.append((index, text))
    form_data['messages'] = await asyncio.to_thread(text_only, form_data['messages'])
    last_user = next((i for i in reversed(range(len(form_data['messages'])))
                      if form_data['messages'][i].get('role') == 'user'), None)
    for index, text in replay:
        message = form_data['messages'][index]
        if text not in (message.get('content') or ''):
            message['content'] = (message.get('content') or '') + '\n\nBijlage (brontekst):\n' + text
        if len(message['content']) > MAX_TEXT:
            raise ValueError('attachment_text_limit')
        if index == last_user and text not in extracted:
            extracted.append(text)
    if extracted:
        last = next((m for m in reversed(form_data['messages']) if m.get('role') == 'user'), None)
        if last is None:
            raise ValueError('user_message_missing')
        missing = [text for text in extracted if text not in (last.get('content') or '')]
        if missing:
            last['content'] = (last.get('content') or '') + '\n\nBijlagen (brontekst):\n' + '\n\n'.join(missing)
        if len(last['content']) > MAX_TEXT:
            raise ValueError('attachment_text_limit')


def wrap_storage(storage):
    """Cover all storage providers and base64/capture uploads, before durable write."""
    original = storage.upload_file
    def upload(file, filename, tags):
        user_id = UPLOAD_USER.get()
        if user_id is None or user_id != tags.get('OpenWebUI-User-Id'):
            return original(file, filename, tags)
        start = file.tell()
        data = file.read(MAX_BYTES + 1)
        try:
            if not looks_like_image(data):
                if Path(filename).suffix.lower() in IMAGE_SUFFIXES:
                    raise Weigering('invalid_image')
                # Leave document storage/size policy unchanged.
                file.seek(start)
                return original(file, filename, tags)
            return original(io.BytesIO(sanitize(data, filename)), filename, tags)
        except Weigering as error:
            raise http_fout(error)
    storage.upload_file = upload
    return storage


async def extract_documents(request, loader_config, file, path, user, build_loader):
    """Per-user local OWUI extraction, without changing global RAG configuration.

    routers/retrieval.py:2025-2038 normally uses the global extraction engine.
    loaders/main.py:713-719 selects its PDFLoader; loaders/pdf.py:22-56 extracts
    page text. Blank/scanned pages use the same configured vision backend.
    """
    from langchain_core.documents import Document
    if not await scoped(user.id):
        loader = build_loader(request, loader_config)
    else:
        from open_webui.retrieval.loaders.main import Loader
        loader = Loader(engine='', PDF_EXTRACT_IMAGES=False)
    loader.user = user
    loader.metadata = {'file_id': file.id, 'file_name': file.filename,
                       'file_content_type': file.meta.get('content_type')}
    docs = await loader.aload(file.filename, file.meta.get('content_type'), path)
    if await scoped(user.id) and Path(file.filename).suffix.lower() == '.pdf' and (
            not docs or any(not doc.page_content.strip() for doc in docs)):
        with open(path, 'rb') as stream:
            data = stream.read(MAX_BYTES + 1)
        if not 0 < len(data) <= MAX_BYTES:
            raise Weigering('attachment_size')
        try:
            from pypdf import PdfReader
            pages = len(PdfReader(io.BytesIO(data)).pages)
        except Exception:
            pages = 1   # unreadable here: the worker decides
        if pages > MAX_PDF_PAGES:
            raise Weigering('page_limit')
        text = await asyncio.to_thread(vision, data)
        docs = [Document(page_content=text, metadata={'source': file.filename})]
    if await scoped(user.id) and (not docs or not any(doc.page_content.strip() for doc in docs)):
        raise ValueError('file_extraction_empty')
    return docs
