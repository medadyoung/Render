"""
NB Remote Client — runs on the company NB.
Captures the screen, sends frames to the relay server.
Receives mouse/keyboard events from the phone and replays them.

Uses Python's ssl module which trusts the Windows CA store,
so it passes through corporate SSL inspection (Websense).

Dependencies (install once):
  pip install websockets mss Pillow pyautogui
"""

import asyncio
import io
import json
import os
import ssl
import struct
import sys
import time

try:
    import websockets
except ImportError:
    print("Missing: pip install websockets")
    sys.exit(1)

try:
    import mss
except ImportError:
    print("Missing: pip install mss")
    sys.exit(1)

try:
    from PIL import Image
except ImportError:
    print("Missing: pip install Pillow")
    sys.exit(1)

try:
    import pyautogui
    pyautogui.FAILSAFE = False  # Don't abort on corner moves
    pyautogui.PAUSE = 0         # No delay between actions
except ImportError:
    print("Missing: pip install pyautogui")
    sys.exit(1)

# Configuration
RELAY_URL = os.environ.get("NB_REMOTE_RELAY", "").rstrip("/")
AUTH_TOKEN = os.environ.get("NB_REMOTE_TOKEN", "")
FPS = int(os.environ.get("NB_REMOTE_FPS", "5"))
QUALITY = int(os.environ.get("NB_REMOTE_QUALITY", "50"))  # JPEG quality 1-100

if not RELAY_URL:
    print("Set NB_REMOTE_RELAY to your Render URL, e.g.:")
    print("  set NB_REMOTE_RELAY=wss://nb-remote-xxxx.onrender.com")
    sys.exit(1)

if not AUTH_TOKEN:
    print("Set NB_REMOTE_TOKEN to the token from Render environment variables.")
    sys.exit(1)


def capture_screen() -> bytes:
    """Capture primary screen as JPEG bytes."""
    with mss.mss() as sct:
        monitor = sct.monitors[1]  # Primary monitor
        img = sct.grab(monitor)
        # Convert to PIL Image, then JPEG
        pil = Image.frombytes("RGB", img.size, img.bgra, "raw", "BGRX")
        buf = io.BytesIO()
        pil.save(buf, format="JPEG", quality=QUALITY, optimize=True)
        return buf.getvalue()


def handle_event(msg: dict):
    """Handle a mouse/keyboard event from the phone."""
    t = msg.get("type")

    if t == "mouse_move":
        pyautogui.moveTo(msg["x"], msg["y"], _pause=False)

    elif t == "mouse_click":
        btn = msg.get("button", "left")
        pyautogui.click(msg["x"], msg["y"], button=btn, _pause=False)

    elif t == "mouse_dblclick":
        pyautogui.doubleClick(msg["x"], msg["y"], _pause=False)

    elif t == "key_char":
        ch = msg.get("char", "")
        if ch:
            pyautogui.write(ch, interval=0, _pause=False)

    elif t == "key_special":
        key_map = {
            "backspace": "backspace", "delete": "delete",
            "left": "left", "right": "right", "up": "up", "down": "down",
            "enter": "enter", "return": "enter",
            "escape": "esc", "tab": "tab",
            "home": "home", "end": "end",
            "pageup": "pageup", "pagedown": "pagedown",
            "win": "win",
        }
        key = key_map.get(msg.get("key", ""))
        if key:
            pyautogui.press(key, _pause=False)

    elif t == "key_combo":
        # e.g. {"type": "key_combo", "keys": ["ctrl", "c"]}
        keys = msg.get("keys", [])
        if keys:
            pyautogui.hotkey(*keys, _pause=False)


async def run():
    ws_url = RELAY_URL.replace("https://", "wss://").replace("http://", "ws://")
    ws_url = ws_url + "/ws/nb"

    # Use system CA store (trusts Websense's injected CA)
    ssl_ctx = ssl.create_default_context()

    while True:
        try:
            print(f"[nb-client] Connecting to {ws_url} ...")
            async with websockets.connect(
                ws_url,
                ssl=ssl_ctx,
                max_size=10 * 1024 * 1024,
                ping_interval=20,
                ping_timeout=10,
                close_timeout=5,
            ) as ws:
                # Authenticate
                await ws.send(json.dumps({"type": "auth", "token": AUTH_TOKEN}))
                resp = json.loads(await asyncio.wait_for(ws.recv(), timeout=10))
                if resp.get("type") != "auth_ok":
                    print(f"[nb-client] Auth failed: {resp}")
                    await asyncio.sleep(5)
                    continue

                print("[nb-client] Connected and authenticated!")

                # Send screen info
                with mss.mss() as sct:
                    m = sct.monitors[1]
                    await ws.send(json.dumps({
                        "type": "screen_info",
                        "width": m["width"],
                        "height": m["height"],
                    }))

                # Two tasks: send frames + receive events
                async def send_frames():
                    interval = 1.0 / FPS
                    while True:
                        t0 = time.monotonic()
                        try:
                            frame = await asyncio.get_event_loop().run_in_executor(
                                None, capture_screen
                            )
                            await ws.send(frame)
                        except Exception:
                            break
                        elapsed = time.monotonic() - t0
                        await asyncio.sleep(max(0, interval - elapsed))

                async def recv_events():
                    async for msg in ws:
                        if msg.type if hasattr(msg, 'type') else True:
                            try:
                                data = json.loads(msg if isinstance(msg, str) else msg.data if hasattr(msg, 'data') else msg)
                                handle_event(data)
                            except Exception as e:
                                pass

                async def recv_events_v2():
                    while True:
                        raw = await ws.recv()
                        if isinstance(raw, str):
                            try:
                                handle_event(json.loads(raw))
                            except Exception:
                                pass

                tasks = [
                    asyncio.create_task(send_frames()),
                    asyncio.create_task(recv_events_v2()),
                ]
                done, pending = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
                for t in pending:
                    t.cancel()

        except Exception as e:
            print(f"[nb-client] Connection error: {e}")

        print("[nb-client] Reconnecting in 5s...")
        await asyncio.sleep(5)


if __name__ == "__main__":
    print(f"[nb-client] NB Remote Client")
    print(f"[nb-client] Relay: {RELAY_URL}")
    print(f"[nb-client] FPS: {FPS}, Quality: {QUALITY}")
    asyncio.run(run())
