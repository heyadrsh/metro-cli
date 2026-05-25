# -*- coding: utf-8 -*-

import json
import os
import subprocess
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


HOST = "127.0.0.1"
PORT = 48971
PLUGIN_DIR = Path(__file__).resolve().parent
RESOLVER = PLUGIN_DIR / "yt_resolver.ps1"


def app_data_dir():
    base = os.environ.get("APPDATA") or os.environ.get("XDG_DATA_HOME") or str(Path.home())
    path = Path(base) / "MetroTubeFlow"
    path.mkdir(parents=True, exist_ok=True)
    return path


DATA_DIR = app_data_dir()
STATE_FILE = DATA_DIR / "state.json"
FAVORITES_FILE = DATA_DIR / "favorites.json"
LOG_FILE = DATA_DIR / "player.log"


def log(message):
    try:
        with LOG_FILE.open("a", encoding="utf-8") as handle:
            handle.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {message}\n")
    except Exception:
        pass


def load_json(path, default):
    try:
        if path.exists():
            return json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        log(f"Could not read {path}: {exc}")
    return default


def save_json(path, value):
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(path)


def run_resolver(mode, **kwargs):
    executables = ["powershell.exe", "powershell", "pwsh.exe", "pwsh"]
    base_args = ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(RESOLVER), "-Mode", mode]
    for key, value in kwargs.items():
        if value is not None:
            base_args.extend([f"-{key}", str(value)])

    last_error = ""
    for executable in executables:
        try:
            completed = subprocess.run(
                [executable] + base_args,
                cwd=str(PLUGIN_DIR),
                capture_output=True,
                text=True,
                timeout=35,
            )
        except FileNotFoundError:
            continue
        except Exception as exc:
            last_error = str(exc)
            continue

        if completed.returncode != 0:
            last_error = (completed.stderr or completed.stdout or "").strip()
            log(f"Resolver {mode} failed: {last_error}")
            continue

        try:
            return json.loads(completed.stdout)
        except json.JSONDecodeError as exc:
            last_error = f"Invalid JSON: {exc}: {completed.stdout[:500]}"
            log(last_error)

    return {"ok": False, "error": last_error or "PowerShell was not found."}


class PlayerState:
    def __init__(self):
        persisted = load_json(STATE_FILE, {})
        self.lock = threading.RLock()
        self.queue = persisted.get("queue") or []
        self.index = int(persisted.get("index") or 0)
        self.current = persisted.get("current")
        self.stream = persisted.get("stream")
        self.command = {"seq": 0, "name": "none"}
        self.stream_cache = {}

    def snapshot(self):
        with self.lock:
            return {
                "ok": True,
                "queue": self.queue,
                "index": self.index,
                "current": self.current,
                "streamUrl": (self.stream or {}).get("url"),
                "streamClient": (self.stream or {}).get("clientName"),
                "command": self.command,
            }

    def persist(self):
        with self.lock:
            save_json(
                STATE_FILE,
                {
                    "queue": self.queue,
                    "index": self.index,
                    "current": self.current,
                    "stream": self.stream,
                },
            )

    def set_command(self, name):
        with self.lock:
            self.command = {"seq": self.command.get("seq", 0) + 1, "name": name}

    def resolve_stream(self, song):
        video_id = song.get("id")
        if not video_id:
            return {"ok": False, "error": "Song has no video id."}
        cached = self.stream_cache.get(video_id)
        if cached:
            return {"ok": True, "stream": cached}
        resolved = run_resolver("stream", VideoId=video_id)
        if not resolved.get("ok"):
            return resolved
        stream = resolved.get("stream") or {}
        self.stream_cache[video_id] = stream
        return {"ok": True, "stream": stream}

    def play(self, song, queue=None, index=0):
        with self.lock:
            self.queue = queue or [song]
            self.index = max(0, min(int(index or 0), len(self.queue) - 1))
            self.current = self.queue[self.index]

        resolved = self.resolve_stream(self.current)
        if not resolved.get("ok"):
            return resolved

        with self.lock:
            self.stream = resolved["stream"]
            self.set_command("play")
            self.persist()

        self.preload_next()
        return {"ok": True, "current": self.current}

    def move(self, direction):
        with self.lock:
            if not self.queue:
                return {"ok": False, "error": "Queue is empty."}
            next_index = self.index + direction
            if next_index >= len(self.queue):
                related = self.related_for_current()
                if related:
                    self.queue.extend(related)
            next_index = max(0, min(next_index, len(self.queue) - 1))
            self.index = next_index
            self.current = self.queue[self.index]

        resolved = self.resolve_stream(self.current)
        if not resolved.get("ok"):
            return resolved

        with self.lock:
            self.stream = resolved["stream"]
            self.set_command("play")
            self.persist()

        self.preload_next()
        return {"ok": True, "current": self.current}

    def related_for_current(self):
        current = self.current or {}
        video_id = current.get("id")
        if not video_id:
            return []
        related = run_resolver("related", VideoId=video_id, Limit=8)
        if not related.get("ok"):
            return []
        existing = {song.get("id") for song in self.queue}
        return [song for song in related.get("items", []) if song.get("id") not in existing]

    def preload_next(self):
        def worker():
            with self.lock:
                if self.index + 1 >= len(self.queue):
                    return
                song = self.queue[self.index + 1]
            try:
                self.resolve_stream(song)
            except Exception as exc:
                log(f"Preload failed: {exc}")

        threading.Thread(target=worker, daemon=True).start()


STATE = PlayerState()


HTML = """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>MetroTube Flow</title>
  <style>
    :root { color-scheme: dark; font-family: "Segoe UI", Arial, sans-serif; background: #0f172a; color: #e5e7eb; }
    body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: linear-gradient(135deg, #111827, #0f172a 42%, #164e63); }
    main { width: min(720px, calc(100vw - 32px)); }
    h1 { margin: 0 0 8px; font-size: 28px; font-weight: 700; letter-spacing: 0; }
    p { margin: 0 0 20px; color: #a5b4fc; }
    audio { width: 100%; margin: 20px 0; }
    .controls { display: flex; gap: 10px; flex-wrap: wrap; }
    button { border: 0; border-radius: 8px; padding: 11px 14px; background: #38bdf8; color: #082f49; font-weight: 700; cursor: pointer; }
    button.secondary { background: #1f2937; color: #e5e7eb; }
    ol { margin-top: 24px; padding-left: 22px; color: #cbd5e1; }
    li.active { color: #67e8f9; font-weight: 700; }
    .status { min-height: 20px; color: #fca5a5; }
  </style>
</head>
<body>
  <main>
    <h1 id="title">MetroTube Flow</h1>
    <p id="artist">Ready</p>
    <audio id="audio" controls preload="auto"></audio>
    <div class="controls">
      <button onclick="toggle()">Play / pause</button>
      <button class="secondary" onclick="command('previous')">Previous</button>
      <button class="secondary" onclick="command('next')">Next</button>
      <button class="secondary" onclick="favorite()">Favorite</button>
    </div>
    <p class="status" id="status"></p>
    <ol id="queue"></ol>
  </main>
  <script>
    const audio = document.getElementById('audio');
    let lastUrl = '';
    let lastSeq = 0;

    async function post(path, body) {
      const response = await fetch(path, {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(body || {})});
      return await response.json();
    }

    async function command(name) {
      document.getElementById('status').textContent = '';
      const response = await post('/api/control', {command: name});
      if (!response.ok) document.getElementById('status').textContent = response.error || 'Command failed';
      await sync();
    }

    async function favorite() {
      const state = await (await fetch('/api/state')).json();
      if (state.current) await post('/api/favorite', {song: state.current});
    }

    function toggle() {
      if (audio.paused) audio.play().catch(() => {});
      else audio.pause();
    }

    async function sync() {
      const state = await (await fetch('/api/state')).json();
      const current = state.current || {};
      document.getElementById('title').textContent = current.title || 'MetroTube Flow';
      document.getElementById('artist').textContent = [current.artist, state.streamClient].filter(Boolean).join(' - ') || 'Ready';

      const queue = document.getElementById('queue');
      queue.innerHTML = '';
      (state.queue || []).slice(0, 20).forEach((song, index) => {
        const li = document.createElement('li');
        li.textContent = `${song.title || 'Untitled'} - ${song.artist || 'Unknown artist'}`;
        if (index === state.index) li.className = 'active';
        queue.appendChild(li);
      });

      if (state.streamUrl && state.streamUrl !== lastUrl) {
        lastUrl = state.streamUrl;
        audio.src = '/stream/current?ts=' + Date.now();
        audio.play().catch(() => {
          document.getElementById('status').textContent = 'Press play to start audio.';
        });
      }

      const cmd = state.command || {};
      if (cmd.seq && cmd.seq !== lastSeq) {
        lastSeq = cmd.seq;
        if (cmd.name === 'play') audio.play().catch(() => {});
        if (cmd.name === 'toggle') toggle();
      }
    }

    audio.addEventListener('ended', () => command('next'));
    sync();
    setInterval(sync, 1000);
  </script>
</body>
</html>
"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        log(fmt % args)

    def send_json(self, value, status=200):
        data = json.dumps(value, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def read_json(self):
        length = int(self.headers.get("Content-Length") or "0")
        if length <= 0:
            return {}
        return json.loads(self.rfile.read(length).decode("utf-8"))

    def do_HEAD(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/stream/current":
            stream_url = (STATE.stream or {}).get("url")
            if stream_url:
                self.send_response(302)
                self.send_header("Location", stream_url)
                self.end_headers()
                return
        self.send_response(404)
        self.end_headers()

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/":
            data = HTML.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if parsed.path == "/api/ping":
            self.send_json({"ok": True})
            return
        if parsed.path == "/api/state":
            self.send_json(STATE.snapshot())
            return
        if parsed.path == "/api/favorites":
            self.send_json({"ok": True, "items": load_json(FAVORITES_FILE, {"songs": []}).get("songs", [])})
            return
        if parsed.path == "/stream/current":
            stream_url = (STATE.stream or {}).get("url")
            if not stream_url:
                self.send_json({"ok": False, "error": "No stream loaded."}, 404)
                return
            self.send_response(302)
            self.send_header("Location", stream_url)
            self.end_headers()
            return
        self.send_json({"ok": False, "error": "Not found."}, 404)

    def do_POST(self):
        try:
            payload = self.read_json()
            if self.path == "/api/play":
                self.send_json(STATE.play(payload.get("song") or {}, payload.get("queue") or [], payload.get("index") or 0))
                return
            if self.path == "/api/control":
                command = payload.get("command")
                if command == "next":
                    self.send_json(STATE.move(1))
                    return
                if command == "previous":
                    self.send_json(STATE.move(-1))
                    return
                if command == "toggle":
                    STATE.set_command("toggle")
                    self.send_json({"ok": True})
                    return
                self.send_json({"ok": False, "error": "Unknown command."}, 400)
                return
            if self.path == "/api/favorite":
                song = payload.get("song") or {}
                favorites = load_json(FAVORITES_FILE, {"songs": []})
                songs = [item for item in favorites.get("songs", []) if item.get("id") != song.get("id")]
                songs.insert(0, song)
                save_json(FAVORITES_FILE, {"songs": songs[:250]})
                self.send_json({"ok": True, "message": "Added to favorites."})
                return
            self.send_json({"ok": False, "error": "Not found."}, 404)
        except Exception as exc:
            log(f"POST {self.path} failed: {exc}")
            self.send_json({"ok": False, "error": str(exc)}, 500)


def main():
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    log(f"MetroTube Flow player listening on http://{HOST}:{PORT}")
    server.serve_forever()


if __name__ == "__main__":
    main()
