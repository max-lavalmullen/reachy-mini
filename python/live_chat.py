"""
live_chat.py — Live voice conversation for Reachy Mini
Supports Gemini Live API and OpenAI Realtime API.

Audio flow:
  Mac default mic  →  [API WebSocket]  →  Reachy USB speaker (auto-detected)

C callback signatures (all called on background thread; ObjC bridge dispatches to main):
  status_cb(const char *msg)           — status string updates
  transcript_cb(const char *text, int is_user)  — 0=assistant, 1=user
  speaking_cb(int speaking)            — 1=robot started speaking, 0=stopped
"""

import asyncio
import threading
import os
import ctypes
import queue as _queue
import json
import numpy as np
import sounddevice as sd

# ── C callback signatures ─────────────────────────────────────────────────────
StatusFn     = ctypes.CFUNCTYPE(None, ctypes.c_char_p)
TranscriptFn = ctypes.CFUNCTYPE(None, ctypes.c_char_p, ctypes.c_int)
SpeakingFn   = ctypes.CFUNCTYPE(None, ctypes.c_int)

# ── Module globals ─────────────────────────────────────────────────────────────
_stop_event      = None
_session_thread  = None
_cb_refs         = []   # keep ctypes callbacks alive

# ── Audio device detection ────────────────────────────────────────────────────
def find_reachy_output_device():
    """Return sounddevice index of Reachy USB speaker, or None for system default."""
    try:
        for i, dev in enumerate(sd.query_devices()):
            name = dev.get('name', '').lower()
            if dev.get('max_output_channels', 0) > 0:
                if any(k in name for k in ('respeaker', 'reachy', 'xmos', 'xvf')):
                    return i
    except Exception:
        pass
    return None   # fall back to Mac default speaker


def find_mac_input_device():
    """Return sounddevice index of the Mac's built-in mic, avoiding the Reachy device.
    Falls back to None (OS default) if not found."""
    try:
        # Prefer built-in Mac microphone; skip Reachy/USB audio interfaces
        reachy_keywords = ('respeaker', 'reachy', 'xmos', 'xvf')
        for i, dev in enumerate(sd.query_devices()):
            name = dev.get('name', '').lower()
            if dev.get('max_input_channels', 0) > 0:
                if any(k in name for k in reachy_keywords):
                    continue  # skip Reachy's broken mic
                if any(k in name for k in ('macbook', 'built-in', 'internal')):
                    return i
        # If no explicit Mac mic found, return the default (which is usually correct)
    except Exception:
        pass
    return None

# ── Public API ────────────────────────────────────────────────────────────────
def start_live_session(config_json: str,
                       status_ptr: int,
                       transcript_ptr: int,
                       speaking_ptr: int) -> str:
    """Start a live session in a background thread. Returns 'ok' or error string."""
    global _stop_event, _session_thread, _cb_refs

    if _session_thread and _session_thread.is_alive():
        stop_live_session()
        _session_thread.join(timeout=2.0)

    config  = json.loads(config_json)
    api     = config.get('api', 'gemini')

    _stop_event = threading.Event()
    cb_status     = StatusFn(status_ptr)
    cb_transcript = TranscriptFn(transcript_ptr)
    cb_speaking   = SpeakingFn(speaking_ptr)
    _cb_refs = [cb_status, cb_transcript, cb_speaking]

    def _run():
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        try:
            coro = (_gemini_session if api == 'gemini' else _openai_session)(
                config, cb_status, cb_transcript, cb_speaking, _stop_event
            )
            loop.run_until_complete(coro)
        except Exception as ex:
            try: cb_status(f"Error: {ex}".encode())
            except Exception: pass
        finally:
            try: cb_speaking(0)
            except Exception: pass
            try: cb_status(b"Disconnected")
            except Exception: pass
            loop.close()

    _session_thread = threading.Thread(target=_run, daemon=True, name="LiveSession")
    _session_thread.start()
    return "ok"


def stop_live_session() -> str:
    """Signal the live session to stop."""
    global _stop_event
    if _stop_event:
        _stop_event.set()
    return "ok"


# ── Gemini Live ───────────────────────────────────────────────────────────────
async def _gemini_session(config, status_cb, transcript_cb, speaking_cb, stop_ev):
    try:
        import google.genai as genai
        from google.genai import types as gt
    except ImportError:
        status_cb(b"Error: google-genai not installed")
        return

    api_key = os.environ.get('GEMINI_API_KEY') or config.get('api_key', '')
    if not api_key:
        status_cb(b"Error: set GEMINI_API_KEY in environment")
        return

    IN_RATE  = 16000
    OUT_RATE = 24000
    CHUNK    = 1024
    out_dev  = find_reachy_output_device()
    in_dev   = find_mac_input_device()

    client = genai.Client(api_key=api_key)
    mic_q  = _queue.Queue(maxsize=100)
    loop   = asyncio.get_event_loop()

    def mic_callback(indata, frames, time, status):
        if not stop_ev.is_set():
            pcm16 = (indata[:, 0] * 32767).astype(np.int16)
            try: mic_q.put_nowait(pcm16.tobytes())
            except _queue.Full: pass

    try:
        lc = gt.LiveConnectConfig(
            response_modalities=["AUDIO"],
            input_audio_transcription=gt.AudioTranscriptionConfig(),
            system_instruction=(
                "You are Reachy, a friendly robot assistant embodied in a Reachy Mini Lite. "
                "Keep responses brief and conversational. "
                "You may include <!-- MOVE: name --> to trigger animations. "
                "Available: happy1, happy2, sad1, surprised1."
            ),
        )
    except Exception:
        # Older google-genai version may not support input_audio_transcription
        lc = gt.LiveConnectConfig(
            response_modalities=["AUDIO"],
            system_instruction=(
                "You are Reachy, a friendly robot assistant embodied in a Reachy Mini Lite. "
                "Keep responses brief and conversational."
            ),
        )

    status_cb(b"Connecting to Gemini Live...")

    async with client.aio.live.connect(model="gemini-2.0-flash-live-001", config=lc) as session:
        status_cb(b"Connected — speak naturally!")

        out_stream = sd.OutputStream(
            samplerate=OUT_RATE, channels=1, dtype='int16',
            device=out_dev, blocksize=4096
        )
        out_stream.start()

        async def _send():
            with sd.InputStream(samplerate=IN_RATE, channels=1, dtype='float32',
                                blocksize=CHUNK, callback=mic_callback, device=in_dev):
                while not stop_ev.is_set():
                    try:
                        raw = await loop.run_in_executor(
                            None, lambda: mic_q.get(timeout=0.05)
                        )
                        await session.send_realtime_input(
                            audio=gt.Blob(data=raw, mime_type="audio/pcm;rate=16000")
                        )
                    except (_queue.Empty, asyncio.CancelledError):
                        continue
                    except Exception:
                        break

        async def _recv():
            async for msg in session.receive():
                if stop_ev.is_set():
                    break
                sc = getattr(msg, 'server_content', None)
                if sc is None:
                    # Some versions put audio directly on msg.data
                    raw = getattr(msg, 'data', None)
                    if raw:
                        speaking_cb(1)
                        out_stream.write(np.frombuffer(raw, dtype=np.int16))
                    continue

                mt = getattr(sc, 'model_turn', None)
                if mt:
                    for part in (getattr(mt, 'parts', None) or []):
                        inline = getattr(part, 'inline_data', None)
                        if inline and getattr(inline, 'data', None):
                            speaking_cb(1)
                            out_stream.write(np.frombuffer(inline.data, dtype=np.int16))
                        txt = getattr(part, 'text', None)
                        if txt:
                            transcript_cb(txt.encode('utf-8', errors='replace'), 0)

                # Input transcription (user speech)
                it = getattr(sc, 'input_transcription', None)
                if it:
                    t = getattr(it, 'text', None)
                    if t:
                        transcript_cb(t.encode('utf-8', errors='replace'), 1)

                if getattr(sc, 'turn_complete', False):
                    speaking_cb(0)

        send_task = asyncio.create_task(_send())
        recv_task = asyncio.create_task(_recv())
        await loop.run_in_executor(None, stop_ev.wait)
        send_task.cancel()
        recv_task.cancel()
        for t in (send_task, recv_task):
            try: await t
            except Exception: pass
        out_stream.stop()
        out_stream.close()


# ── OpenAI Realtime ───────────────────────────────────────────────────────────
async def _openai_session(config, status_cb, transcript_cb, speaking_cb, stop_ev):
    try:
        from openai import AsyncOpenAI
    except ImportError:
        status_cb(b"Error: openai not installed")
        return

    api_key = os.environ.get('OPENAI_API_KEY') or config.get('api_key', '')
    if not api_key:
        status_cb(b"Error: set OPENAI_API_KEY in environment")
        return

    import base64
    RATE    = 24000
    CHUNK   = 4800   # 200 ms
    out_dev = find_reachy_output_device()
    in_dev  = find_mac_input_device()

    client = AsyncOpenAI(api_key=api_key)
    mic_q  = _queue.Queue(maxsize=100)
    loop   = asyncio.get_event_loop()

    def mic_callback(indata, frames, time, status):
        if not stop_ev.is_set():
            pcm16 = (indata[:, 0] * 32767).astype(np.int16)
            try: mic_q.put_nowait(pcm16.tobytes())
            except _queue.Full: pass

    status_cb(b"Connecting to OpenAI Realtime...")

    async with client.beta.realtime.connect(model="gpt-4o-realtime-preview") as conn:
        await conn.session.update(session={
            "modalities": ["audio", "text"],
            "instructions": (
                "You are Reachy, a friendly robot assistant embodied in a Reachy Mini Lite. "
                "Keep responses brief and conversational. "
                "You may include <!-- MOVE: name --> to trigger animations. "
                "Available: happy1, happy2, sad1, surprised1."
            ),
            "voice": "alloy",
            "input_audio_format": "pcm16",
            "output_audio_format": "pcm16",
            "turn_detection": {"type": "server_vad", "threshold": 0.5,
                               "silence_duration_ms": 600},
            "input_audio_transcription": {"model": "whisper-1"},
        })
        status_cb(b"Connected — speak naturally!")

        out_stream = sd.OutputStream(
            samplerate=RATE, channels=1, dtype='int16',
            device=out_dev, blocksize=4096
        )
        out_stream.start()

        async def _send():
            with sd.InputStream(samplerate=RATE, channels=1, dtype='float32',
                                blocksize=CHUNK, callback=mic_callback, device=in_dev):
                while not stop_ev.is_set():
                    try:
                        raw = await loop.run_in_executor(
                            None, lambda: mic_q.get(timeout=0.05)
                        )
                        await conn.input_audio_buffer.append(
                            audio=base64.b64encode(raw).decode()
                        )
                    except (_queue.Empty, asyncio.CancelledError):
                        continue
                    except Exception:
                        break

        async def _recv():
            async for event in conn:
                if stop_ev.is_set():
                    break
                etype = getattr(event, 'type', '')
                if etype == "response.audio.delta":
                    speaking_cb(1)
                    raw = base64.b64decode(event.delta)
                    out_stream.write(np.frombuffer(raw, dtype=np.int16))
                elif etype == "response.audio_transcript.delta":
                    txt = getattr(event, 'delta', '')
                    if txt:
                        transcript_cb(txt.encode('utf-8', errors='replace'), 0)
                elif etype == "conversation.item.input_audio_transcription.completed":
                    txt = getattr(event, 'transcript', '')
                    if txt:
                        transcript_cb(txt.encode('utf-8', errors='replace'), 1)
                elif etype in ("response.done", "response.audio.done"):
                    speaking_cb(0)

        send_task = asyncio.create_task(_send())
        recv_task = asyncio.create_task(_recv())
        await loop.run_in_executor(None, stop_ev.wait)
        send_task.cancel()
        recv_task.cancel()
        for t in (send_task, recv_task):
            try: await t
            except Exception: pass
        out_stream.stop()
        out_stream.close()
