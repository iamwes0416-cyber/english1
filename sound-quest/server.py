from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError
import hashlib
import json
import mimetypes
import os
import re


BASE_DIR = Path(__file__).resolve().parent
HTML_FILE = BASE_DIR / "index.html"
CACHE_DIR = BASE_DIR / "audio-cache"
ENV_FILE = BASE_DIR / ".env"


def load_env():
    if not ENV_FILE.exists():
        return

    for line in ENV_FILE.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


def safe_audio_name(text):
    slug = re.sub(r"[^a-z0-9_-]+", "-", text.lower()).strip("-")
    digest = hashlib.sha1(text.encode("utf-8")).hexdigest()[:10]
    return f"{slug or 'word'}-{digest}.mp3"


def openai_tts(text):
    api_key = os.environ.get("OPENAI_API_KEY")
    if not api_key:
        raise RuntimeError("OPENAI_API_KEY is missing. Create outputs/sound-quest/.env first.")

    payload = {
        "model": os.environ.get("OPENAI_TTS_MODEL", "gpt-4o-mini-tts"),
        "voice": os.environ.get("OPENAI_TTS_VOICE", "alloy"),
        "input": text,
        "response_format": "mp3",
    }

    instructions = os.environ.get(
        "OPENAI_TTS_INSTRUCTIONS",
        "Pronounce this as a clear American English phonics word for a second-grade child. "
        "Say only the word, with no extra explanation."
    )
    if instructions:
        payload["instructions"] = instructions

    request = Request(
        "https://api.openai.com/v1/audio/speech",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )

    with urlopen(request, timeout=60) as response:
        return response.read()


class SoundQuestHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        print("%s - %s" % (self.address_string(), format % args))

    def send_bytes(self, status, body, content_type):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store" if status >= 400 else "public, max-age=3600")
        self.end_headers()
        self.wfile.write(body)

    def send_text(self, status, text, content_type="text/plain; charset=utf-8"):
        self.send_bytes(status, text.encode("utf-8"), content_type)

    def do_GET(self):
        parsed = urlparse(self.path)

        if parsed.path in ("/", "/index.html"):
            if not HTML_FILE.exists():
                self.send_text(404, "index.html not found")
                return
            self.send_bytes(200, HTML_FILE.read_bytes(), "text/html; charset=utf-8")
            return

        if parsed.path == "/api/tts":
            query = parse_qs(parsed.query)
            word = (query.get("word") or [""])[0].strip()
            if not re.fullmatch(r"[A-Za-z][A-Za-z'-]{0,30}", word):
                self.send_text(400, "Invalid word")
                return

            CACHE_DIR.mkdir(parents=True, exist_ok=True)
            audio_path = CACHE_DIR / safe_audio_name(word)
            if audio_path.exists():
                self.send_bytes(200, audio_path.read_bytes(), "audio/mpeg")
                return

            try:
                audio = openai_tts(word)
            except HTTPError as error:
                detail = error.read().decode("utf-8", errors="replace")
                self.send_text(error.code, detail)
                return
            except (URLError, RuntimeError, TimeoutError) as error:
                self.send_text(502, str(error))
                return

            audio_path.write_bytes(audio)
            self.send_bytes(200, audio, "audio/mpeg")
            return

        # Serve cached files for debugging if opened directly.
        requested = (BASE_DIR / parsed.path.lstrip("/")).resolve()
        if BASE_DIR in requested.parents and requested.exists() and requested.is_file():
            content_type = mimetypes.guess_type(requested.name)[0] or "application/octet-stream"
            self.send_bytes(200, requested.read_bytes(), content_type)
            return

        self.send_text(404, "Not found")


def main():
    load_env()
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    port = int(os.environ.get("PORT", "8787"))
    server = ThreadingHTTPServer(("127.0.0.1", port), SoundQuestHandler)
    print(f"Sound Quest running at http://127.0.0.1:{port}")
    print("Press Ctrl+C to stop.")
    server.serve_forever()


if __name__ == "__main__":
    main()
