# -*- coding: utf-8 -*-

import json
import os
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
import webbrowser
from pathlib import Path


PLUGIN_DIR = Path(__file__).resolve().parent
SERVICE_FILE = PLUGIN_DIR / "player_service.py"
ICON = "Images/app.svg"
HOST = "127.0.0.1"
PORT = 48971
BASE_URL = f"http://{HOST}:{PORT}"


def app_data_dir():
    base = os.environ.get("APPDATA") or os.environ.get("XDG_DATA_HOME") or str(Path.home())
    path = Path(base) / "MetroTubeFlow"
    path.mkdir(parents=True, exist_ok=True)
    return path


DATA_DIR = app_data_dir()
LAST_SEARCH_FILE = DATA_DIR / "last_search.json"


def load_json(path, default):
    try:
        if path.exists():
            return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        pass
    return default


def save_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")


def result(title, subtitle, method=None, parameters=None, context=None):
    item = {
        "Title": title,
        "SubTitle": subtitle,
        "IcoPath": ICON,
    }
    if method:
        item["JsonRPCAction"] = {
            "method": method,
            "parameters": parameters or [],
        }
    if context is not None:
        item["ContextData"] = context
    return item


def flow_api(method, parameters=None):
    print(json.dumps({"method": method, "parameters": parameters or []}))


def show_msg(title, subtitle):
    flow_api("Flow.Launcher.ShowMsg", [title, subtitle, ICON])


def post_json(path, payload=None, timeout=6):
    data = json.dumps(payload or {}).encode("utf-8")
    req = urllib.request.Request(
        f"{BASE_URL}{path}",
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def get_json(path, timeout=2):
    with urllib.request.urlopen(f"{BASE_URL}{path}", timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def is_service_alive():
    try:
        data = get_json("/api/ping", timeout=0.5)
        return data.get("ok") is True
    except Exception:
        return False


def start_service():
    if is_service_alive():
        return True

    kwargs = {
        "cwd": str(PLUGIN_DIR),
        "stdin": subprocess.DEVNULL,
        "stdout": subprocess.DEVNULL,
        "stderr": subprocess.DEVNULL,
        "close_fds": True,
    }
    if os.name == "nt":
        kwargs["creationflags"] = (
            getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
            | getattr(subprocess, "DETACHED_PROCESS", 0)
        )

    subprocess.Popen([sys.executable, str(SERVICE_FILE)], **kwargs)

    for _ in range(30):
        if is_service_alive():
            return True
        time.sleep(0.1)
    return False


def run_resolver(mode, **kwargs):
    script = PLUGIN_DIR / "yt_resolver.ps1"
    executables = ["powershell.exe", "powershell", "pwsh.exe", "pwsh"]
    base_args = ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(script), "-Mode", mode]
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
                timeout=25,
            )
        except FileNotFoundError:
            continue
        except Exception as exc:
            last_error = str(exc)
            continue

        if completed.returncode != 0:
            last_error = (completed.stderr or completed.stdout or "").strip()
            continue

        try:
            return json.loads(completed.stdout)
        except json.JSONDecodeError:
            last_error = completed.stdout.strip()[:500]

    return {"ok": False, "error": last_error or "PowerShell was not found."}


def command_results():
    status = {}
    if is_service_alive():
        try:
            status = get_json("/api/state")
        except Exception:
            status = {}

    current = status.get("current") or {}
    now_playing = current.get("title") or "Nothing playing"
    artist = current.get("artist") or "Search a song name to start"

    return [
        result("Play / pause", f"{now_playing} - {artist}", "control", ["toggle"]),
        result("Next song", "Skip to the next queued or suggested track", "control", ["next"]),
        result("Previous song", "Go back in the queue", "control", ["previous"]),
        result("Open player", "Show the local MetroTube player window", "open_player"),
        result("Favorites", "Show locally saved favorites", "show_favorites"),
    ]


def query(search_text):
    text = (search_text or "").strip()
    lower = text.lower()

    if not text:
        return command_results()

    if lower in ("play", "pause", "toggle"):
        return [result("Play / pause", "Toggle the current player", "control", ["toggle"])]
    if lower in ("next", "n"):
        return [result("Next song", "Skip to the next track", "control", ["next"])]
    if lower in ("previous", "prev", "back", "p"):
        return [result("Previous song", "Return to the previous track", "control", ["previous"])]
    if lower in ("open", "player"):
        return [result("Open player", "Show the local MetroTube player window", "open_player")]
    if lower in ("fav", "favorite", "favorites"):
        return show_favorites()

    search = run_resolver("search", Query=text, Limit=8)
    if not search.get("ok"):
        return [
            result(
                "Search failed",
                search.get("error") or "YouTube Music could not be reached.",
                "open_player",
            )
        ]

    songs = search.get("items") or []
    if not songs:
        return [result("No songs found", "Try a different query")]

    save_json(LAST_SEARCH_FILE, {"query": text, "items": songs})

    items = []
    for index, song in enumerate(songs):
        title = song.get("title") or "Untitled"
        artist = song.get("artist") or "Unknown artist"
        duration = song.get("durationText") or ""
        subtitle = " - ".join(part for part in (artist, duration) if part)
        items.append(
            result(
                title,
                subtitle,
                "play_song",
                [song, index],
                {"song": song, "index": index},
            )
        )
    return items


def context_menu(data):
    song = (data or {}).get("song") if isinstance(data, dict) else None
    if not song:
        return []
    return [
        result(song.get("title", "Song"), "Add to favorites", "favorite_song", [song]),
        result(song.get("title", "Song"), "Play from here", "play_song", [song, (data or {}).get("index", 0)]),
    ]


def play_song(song, index=0):
    if not start_service():
        show_msg("MetroTube Flow", "Could not start the local player service.")
        return
    queue = load_json(LAST_SEARCH_FILE, {"items": [song]}).get("items") or [song]
    if not any(item.get("id") == song.get("id") for item in queue):
        queue = [song]
        index = 0
    response = post_json("/api/play", {"song": song, "queue": queue or [song], "index": index}, timeout=30)
    if response.get("ok"):
        webbrowser.open(BASE_URL)
        show_msg("MetroTube Flow", f"Playing {song.get('title', 'song')}")
    else:
        show_msg("MetroTube Flow", response.get("error") or "Playback failed.")


def control(command):
    if not start_service():
        show_msg("MetroTube Flow", "Could not start the local player service.")
        return
    response = post_json("/api/control", {"command": command}, timeout=30)
    if response.get("ok") and command in ("next", "previous"):
        webbrowser.open(BASE_URL)
    if not response.get("ok"):
        show_msg("MetroTube Flow", response.get("error") or "Command failed.")


def open_player():
    if start_service():
        webbrowser.open(BASE_URL)
    else:
        show_msg("MetroTube Flow", "Could not start the local player service.")


def favorite_song(song):
    if not start_service():
        show_msg("MetroTube Flow", "Could not start the local player service.")
        return
    response = post_json("/api/favorite", {"song": song}, timeout=10)
    show_msg("MetroTube Flow", response.get("message") or "Favorite updated.")


def show_favorites():
    if not start_service():
        return [result("Favorites unavailable", "Could not start the local player service.")]
    try:
        data = get_json("/api/favorites")
    except Exception as exc:
        return [result("Favorites unavailable", str(exc))]

    songs = data.get("items") or []
    if not songs:
        return [result("No favorites yet", "Search a song, then use the context menu to save it.")]

    return [
        result(
            song.get("title") or "Untitled",
            song.get("artist") or "Unknown artist",
            "play_song",
            [song, index],
            {"song": song, "index": index},
        )
        for index, song in enumerate(songs[:20])
    ]


def dispatch():
    request = {"method": "query", "parameters": [""]}
    if len(sys.argv) > 1:
        request = json.loads(sys.argv[1])

    method = request.get("method", "query")
    params = request.get("parameters", [])
    functions = {
        "query": query,
        "context_menu": context_menu,
        "play_song": play_song,
        "control": control,
        "open_player": open_player,
        "favorite_song": favorite_song,
        "show_favorites": show_favorites,
    }

    output = functions[method](*params)
    if method in ("query", "context_menu"):
        print(json.dumps({"result": output or [], "debugMessage": ""}))


if __name__ == "__main__":
    try:
        dispatch()
    except (socket.timeout, urllib.error.URLError) as exc:
        show_msg("MetroTube Flow", str(exc))
    except Exception as exc:
        if len(sys.argv) > 1 and json.loads(sys.argv[1]).get("method") in ("query", "context_menu"):
            print(json.dumps({"result": [result("MetroTube Flow crashed", str(exc))], "debugMessage": str(exc)}))
        else:
            show_msg("MetroTube Flow", str(exc))
