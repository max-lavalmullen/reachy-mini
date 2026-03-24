"""
bridge.py — Reachy Mini Python bridge
Loaded by PythonBridge.m via embedded CPython.

Provides:
  start_daemon()          — starts the reachy-mini HTTP daemon in a background thread
  stop_daemon()           — stops the daemon gracefully
  start_camera(fn_ptr)    — starts camera loop, calls C callback with JPEG frames
  stop_camera()           — stops camera loop
  sdk_call(json_str)      — generic SDK call, returns JSON string result
"""

import sys
import os
import json
import threading
import logging
from pathlib import Path
from types import SimpleNamespace

logging.basicConfig(level=logging.INFO, format="[bridge] %(levelname)s %(message)s")
log = logging.getLogger(__name__)

# ── State ─────────────────────────────────────────────────────────────────────
_daemon_thread: threading.Thread | None = None
_daemon_server = None
_camera_thread: threading.Thread | None = None
_camera_running = False
_daemon_running = False
_rubik_thread: threading.Thread | None = None
_rubik_stop_event: threading.Event | None = None
_rubik_running = False
_rubik_state = {
    "state": "stopped",
    "last_error": None,
    "url": None,
    "port": None,
    "app_root": None,
}


def _env_flag(name: str, default: bool = False) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    value = raw.strip().lower()
    if value in {"1", "true", "yes", "on"}:
        return True
    if value in {"0", "false", "no", "off"}:
        return False
    return default


def _rubik_port() -> int:
    try:
        return int(os.getenv("REACHY_RUBIK_COACH_PORT", "7861"))
    except ValueError:
        return 7861


def _rubik_app_root() -> Path | None:
    current_dir = Path(__file__).resolve().parent
    candidates = [
        os.getenv("REACHY_RUBIK_COACH_APP"),
        str(current_dir / "apps" / "reachy_mini_rubik_coach_app"),
        str(current_dir.parent / "apps" / "reachy_mini_rubik_coach_app"),
    ]
    for candidate in candidates:
        if not candidate:
            continue
        root = Path(candidate).expanduser().resolve()
        if (root / "src" / "reachy_mini_rubik_coach_app").is_dir():
            return root
    return None


def _rubik_instance_path() -> Path:
    override = os.getenv("REACHY_RUBIK_COACH_INSTANCE_PATH")
    if override:
        target = Path(override).expanduser()
    else:
        target = Path.home() / "Library" / "Application Support" / "ReachyControl" / "rubik-coach"
    target.mkdir(parents=True, exist_ok=True)
    return target


def _purge_rubik_modules() -> None:
    for name in list(sys.modules):
        if name == "reachy_mini_rubik_coach_app" or name.startswith("reachy_mini_rubik_coach_app."):
            sys.modules.pop(name, None)


def start_rubik_coach(config_json: str = "{}") -> str:
    """Start the Rubik coach app in a background thread."""
    global _rubik_thread, _rubik_stop_event, _rubik_running, _rubik_state

    if _rubik_thread is not None and _rubik_thread.is_alive():
        return "already_running"

    settings = {}
    if config_json:
        try:
            settings = json.loads(config_json)
        except json.JSONDecodeError:
            settings = {}

    app_root = _rubik_app_root()
    if app_root is None:
        return "error:Rubik coach app source not found"

    port = _rubik_port()
    os.environ["GRADIO_SERVER_NAME"] = "127.0.0.1"
    os.environ["GRADIO_SERVER_PORT"] = str(port)
    os.environ["GRADIO_ANALYTICS_ENABLED"] = "false"

    source_root = app_root / "src"
    if str(source_root) not in sys.path:
        sys.path.insert(0, str(source_root))

    stop_event = threading.Event()
    instance_path = _rubik_instance_path()

    _rubik_state.update({
        "state": "starting",
        "last_error": None,
        "url": f"http://127.0.0.1:{port}/",
        "port": port,
        "app_root": str(app_root),
        "profile": settings.get("profile") or "rubiks_cube_coach",
        "unlocked": bool(settings.get("unlocked", False)),
    })

    def _run() -> None:
        global _rubik_thread, _rubik_stop_event, _rubik_running, _rubik_state
        _rubik_running = True
        _rubik_stop_event = stop_event

        try:
            unlocked = bool(settings.get("unlocked", False))
            selected_profile = settings.get("profile")
            if unlocked:
                os.environ["REACHY_MINI_UNLOCKED"] = "1"
            else:
                os.environ.pop("REACHY_MINI_UNLOCKED", None)

            if selected_profile:
                os.environ["REACHY_MINI_CUSTOM_PROFILE"] = str(selected_profile)
            else:
                os.environ.pop("REACHY_MINI_CUSTOM_PROFILE", None)

            _purge_rubik_modules()
            from reachy_mini_rubik_coach_app.main import run

            args = SimpleNamespace(
                head_tracker=settings.get("head_tracker") or os.getenv("REACHY_MINI_HEAD_TRACKER", "rubiks_cube"),
                no_camera=bool(settings.get("no_camera", _env_flag("REACHY_RUBIK_COACH_NO_CAMERA", False))),
                local_vision=bool(settings.get("local_vision", _env_flag("REACHY_RUBIK_COACH_LOCAL_VISION", False))),
                gradio=True,
                debug=bool(settings.get("debug", _env_flag("REACHY_RUBIK_COACH_DEBUG", False))),
                robot_name=settings.get("robot_name") or os.getenv("REACHY_ROBOT_NAME"),
            )
            _rubik_state["state"] = "booting"
            run(args, robot=None, app_stop_event=stop_event, settings_app=None, instance_path=str(instance_path))
            _rubik_state["state"] = "stopped"
        except SystemExit as e:
            _rubik_state["state"] = "error"
            _rubik_state["last_error"] = f"Rubik coach exited during startup: {e}"
            log.error(_rubik_state["last_error"])
        except Exception as e:
            _rubik_state["state"] = "error"
            _rubik_state["last_error"] = f"Rubik coach failed: {type(e).__name__}: {e}"
            log.exception("Rubik coach startup failed")
        finally:
            _rubik_running = False
            _rubik_stop_event = None
            _rubik_thread = None

    _rubik_thread = threading.Thread(target=_run, name="reachy-rubik-coach", daemon=True)
    _rubik_thread.start()
    return "ok"


def stop_rubik_coach() -> str:
    """Signal the Rubik coach app to stop."""
    global _rubik_thread, _rubik_stop_event, _rubik_running, _rubik_state

    if _rubik_stop_event is not None:
        _rubik_stop_event.set()

    thread = _rubik_thread
    if thread is not None and thread.is_alive():
        thread.join(timeout=5.0)

    if thread is not None and thread.is_alive():
        _rubik_state["state"] = "stopping"
        return "timeout"

    _rubik_thread = None
    _rubik_stop_event = None
    _rubik_running = False
    if _rubik_state.get("state") != "error":
        _rubik_state["state"] = "stopped"
    return "ok"


def rubik_coach_status() -> str:
    """Return JSON status for the Rubik coach worker."""
    payload = dict(_rubik_state)
    payload["thread_alive"] = bool(_rubik_thread and _rubik_thread.is_alive())
    payload["running"] = _rubik_running
    return json.dumps(payload)

# ── Daemon ────────────────────────────────────────────────────────────────────

def start_daemon() -> str:
    """Start the reachy-mini HTTP daemon in a background thread. Returns 'ok' or error."""
    global _daemon_thread, _daemon_running, _daemon_server
    if _daemon_running:
        return "already_running"

    try:
        log.info("Importing reachy_mini daemon ...")
        from reachy_mini.daemon.app.main import Args, create_app
        import uvicorn

        args = Args(
            desktop_app_daemon=True,
            localhost_only=True,
            fastapi_host="127.0.0.1",
            fastapi_port=8000,
            autostart=False,           # match desktop app flow: UI starts robot explicitly
            wake_up_on_start=False,    # user presses Wake Up manually
            use_audio=False,           # GStreamer unavailable; audio via live_chat.py
        )
        app = create_app(args)
        config = uvicorn.Config(
            app,
            host=args.fastapi_host,
            port=args.fastapi_port,
            log_level="warning",
            access_log=False,
        )
        server = uvicorn.Server(config)

        def _run():
            global _daemon_running, _daemon_server
            _daemon_running = True
            _daemon_server = server
            try:
                server.run()
            except Exception as e:
                log.error(f"Daemon error: {e}")
            finally:
                _daemon_server = None
                _daemon_running = False

        _daemon_thread = threading.Thread(target=_run, name="reachy-daemon", daemon=True)
        _daemon_thread.start()
        return "ok"

    except Exception as e:
        log.error(f"start_daemon failed: {e}")
        return f"error:{e}"


def stop_daemon() -> str:
    """Signal daemon to stop."""
    global _daemon_running, _daemon_server, _daemon_thread

    server = _daemon_server
    if server is not None:
        server.should_exit = True

    thread = _daemon_thread
    if thread is not None and thread.is_alive():
        thread.join(timeout=3.0)

    _daemon_server = None
    _daemon_thread = None
    _daemon_running = False
    return "ok"


# ── Camera ────────────────────────────────────────────────────────────────────

def start_camera(callback_ptr: int) -> str:
    """
    Start camera frame loop.
    callback_ptr is a C function pointer: void (*)(const char *jpeg_bytes, int len)
    """
    global _camera_thread, _camera_running
    if _camera_running:
        return "already_running"

    import ctypes
    # Signature: void callback(const char* data, int length)
    FRAME_CB = ctypes.CFUNCTYPE(None, ctypes.c_char_p, ctypes.c_int)
    cb = FRAME_CB(callback_ptr)

    def _camera_loop():
        global _camera_running
        _camera_running = True
        log.info("Camera loop starting ...")

        try:
            # Try to use reachy_mini camera API
            _run_reachy_camera(cb)
        except Exception as e:
            log.warning(f"reachy camera failed ({e}), falling back to HTTP MJPEG")
            try:
                _run_http_camera(cb)
            except Exception as e2:
                log.error(f"Camera loop error: {e2}")
        finally:
            _camera_running = False
            log.info("Camera loop stopped")

    _camera_thread = threading.Thread(target=_camera_loop, name="reachy-camera", daemon=True)
    _camera_thread.start()
    return "ok"


def _run_reachy_camera(cb):
    """Pull frames from reachy_mini SDK camera stream."""
    global _camera_running
    import io

    # Try different import paths based on SDK version
    camera = None
    try:
        from reachy_mini.device.camera import Camera
        camera = Camera()
    except ImportError:
        try:
            import reachy_mini
            r = reachy_mini.ReachyMini()
            camera = r.camera
        except Exception:
            raise ImportError("Could not find camera in reachy_mini SDK")

    try:
        import PIL.Image
        while _camera_running:
            try:
                frame = camera.get_frame()  # returns numpy array or PIL image
                if frame is None:
                    import time; time.sleep(0.033)
                    continue
                # Convert to JPEG bytes
                if hasattr(frame, 'tobytes'):
                    # numpy array — convert via PIL
                    img = PIL.Image.fromarray(frame)
                else:
                    img = frame
                buf = io.BytesIO()
                img.save(buf, format="JPEG", quality=75)
                jpeg = buf.getvalue()
                cb(jpeg, len(jpeg))
            except Exception as e:
                log.warning(f"Camera frame error: {e}")
                import time; time.sleep(0.1)
    finally:
        try:
            camera.close()
        except Exception:
            pass


def _run_http_camera(cb):
    """Pull MJPEG from daemon's /api/camera/stream endpoint."""
    global _camera_running
    import urllib.request
    import time

    url = "http://127.0.0.1:8000/api/camera/stream"
    log.info(f"HTTP camera: {url}")

    boundary = None
    buf = b""

    try:
        req = urllib.request.urlopen(url, timeout=10)
        content_type = req.headers.get("Content-Type", "")
        # Extract boundary from multipart/x-mixed-replace; boundary=xxx
        for part in content_type.split(";"):
            part = part.strip()
            if part.startswith("boundary="):
                boundary = ("--" + part[9:]).encode()
                break

        while _camera_running:
            chunk = req.read(4096)
            if not chunk:
                break
            buf += chunk

            if boundary is None:
                # Try to find boundary in stream
                if b"--" in buf:
                    idx = buf.index(b"--")
                    end = buf.find(b"\r\n", idx)
                    if end > 0:
                        boundary = buf[idx:end]

            if boundary and boundary in buf:
                parts = buf.split(boundary)
                for part in parts[:-1]:
                    # Find JPEG data after headers
                    header_end = part.find(b"\r\n\r\n")
                    if header_end >= 0:
                        jpeg = part[header_end + 4:].strip()
                        if jpeg.startswith(b"\xff\xd8"):  # JPEG SOI marker
                            cb(jpeg, len(jpeg))
                buf = parts[-1]

    except Exception as e:
        if _camera_running:
            raise


def stop_camera() -> str:
    """Stop the camera loop."""
    global _camera_running
    _camera_running = False
    return "ok"


# ── Generic SDK call ───────────────────────────────────────────────────────────

def sdk_call(json_str: str) -> str:
    """
    Generic SDK call. json_str is a JSON object with 'method' and 'params'.
    Returns a JSON string result.
    """
    try:
        req = json.loads(json_str)
        method = req.get("method", "")
        params = req.get("params", {})

        result = {"ok": False, "error": "unknown method"}

        if method == "ping":
            result = {"ok": True, "pong": True}

        elif method == "get_status":
            result = {"ok": True, "daemon_running": _daemon_running,
                      "camera_running": _camera_running}

        return json.dumps(result)
    except Exception as e:
        return json.dumps({"ok": False, "error": str(e)})


# ── Live conversation (Gemini Live / OpenAI Realtime) ─────────────────────────

def start_live_session(config_json: str, status_ptr: int,
                       transcript_ptr: int, speaking_ptr: int) -> str:
    """Start a live voice session. Delegates to live_chat.py."""
    try:
        from live_chat import start_live_session as _start
        return _start(config_json, status_ptr, transcript_ptr, speaking_ptr)
    except Exception as e:
        log.error(f"start_live_session failed: {e}")
        return f"error:{e}"


def stop_live_session() -> str:
    """Stop the running live session."""
    try:
        from live_chat import stop_live_session as _stop
        return _stop()
    except Exception as e:
        return f"error:{e}"


# ── Init (called when module is imported) ──────────────────────────────────────

def _add_venv_to_path():
    """Add the bundled venv site-packages to sys.path if running inside .app."""
    # Check for venv next to this script (bundle layout: Resources/venv)
    script_dir = os.path.dirname(os.path.abspath(__file__))
    venv_candidates = [
        os.path.join(script_dir, "venv"),               # bundle: Resources/venv
        os.path.join(script_dir, "../python/.venv"),    # dev: python/.venv
        os.environ.get("REACHY_VENV", ""),
    ]
    for venv in venv_candidates:
        if not venv:
            continue
        site = os.path.join(venv, "lib",
                            f"python{sys.version_info.major}.{sys.version_info.minor}",
                            "site-packages")
        if os.path.isdir(site) and site not in sys.path:
            sys.path.insert(0, site)
            log.info(f"Added to sys.path: {site}")
            return site
    return None

_add_venv_to_path()
log.info(f"bridge.py loaded (Python {sys.version})")
