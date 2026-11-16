"""
NB-Remote Relay Server v1.2
Runs on Render.com (free tier). Bridges NB ↔ Phone/PC via WebSocket.

Key design: non-blocking frame forwarding. If a phone client is slow,
frames are dropped rather than blocking the NB connection.
"""

import asyncio
import json
import os
import time
from pathlib import Path

from aiohttp import web

nb_ws = None
phone_clients = set()
AUTH_TOKEN = os.environ.get("NB_REMOTE_TOKEN", "change-me-to-a-secret")

# Latest frame — phones grab this on their own pace
latest_frame = None
frame_counter = 0
nb_connect_time = 0


async def index(request):
    html = (Path(__file__).parent / "static" / "index.html").read_text()
    return web.Response(text=html, content_type="text/html")


async def health(request):
    uptime = int(time.time() - nb_connect_time) if nb_ws else 0
    return web.json_response({
        "status": "ok",
        "nb_connected": nb_ws is not None,
        "nb_uptime_s": uptime,
        "nb_frames": frame_counter,
        "phone_clients": len(phone_clients),
    })


async def ws_nb(request):
    """WebSocket endpoint for the NB client."""
    global nb_ws, latest_frame, frame_counter, nb_connect_time

    ws = web.WebSocketResponse(
        max_msg_size=10 * 1024 * 1024,
        heartbeat=20.0,  # server sends ping every 20s, expects pong
    )
    await ws.prepare(request)

    # Auth
    try:
        msg = await asyncio.wait_for(ws.receive_json(), timeout=10)
        if msg.get("type") != "auth" or msg.get("token") != AUTH_TOKEN:
            await ws.send_json({"type": "error", "msg": "bad token"})
            await ws.close()
            return ws
    except Exception:
        await ws.close()
        return ws

    await ws.send_json({"type": "auth_ok"})

    # Close previous NB connection if exists
    if nb_ws is not None:
        try:
            await nb_ws.close()
        except Exception:
            pass
    nb_ws = ws
    frame_counter = 0
    nb_connect_time = time.time()
    print("[relay] NB connected")

    for pc in list(phone_clients):
        try:
            await pc.send_json({"type": "nb_status", "connected": True})
        except Exception:
            pass

    try:
        async for msg in ws:
            if msg.type == web.WSMsgType.TEXT:
                try:
                    data = json.loads(msg.data)
                    if data.get("type") == "frame":
                        latest_frame = msg.data
                        frame_counter += 1
                    else:
                        for pc in list(phone_clients):
                            try:
                                await pc.send_str(msg.data)
                            except Exception:
                                phone_clients.discard(pc)
                except Exception:
                    pass
            elif msg.type == web.WSMsgType.BINARY:
                latest_frame = msg.data
                frame_counter += 1
            elif msg.type in (web.WSMsgType.CLOSE, web.WSMsgType.CLOSING, web.WSMsgType.CLOSED):
                print(f"[relay] NB received close msg type={msg.type}")
                break
            elif msg.type == web.WSMsgType.ERROR:
                print(f"[relay] NB ws error: {ws.exception()}")
                break
    except Exception as e:
        print(f"[relay] NB handler exception: {e}")
    finally:
        elapsed = int(time.time() - nb_connect_time)
        print(f"[relay] NB disconnected after {elapsed}s, {frame_counter} frames")
        nb_ws = None
        latest_frame = None
        for pc in list(phone_clients):
            try:
                await pc.send_json({"type": "nb_status", "connected": False})
            except Exception:
                pass

    return ws


async def ws_phone(request):
    """WebSocket endpoint for phone/PC browsers."""
    global nb_ws, latest_frame

    ws = web.WebSocketResponse(heartbeat=20.0)
    await ws.prepare(request)
    phone_clients.add(ws)
    print(f"[relay] Browser connected (total: {len(phone_clients)})")

    await ws.send_json({"type": "nb_status", "connected": nb_ws is not None})

    async def push_frames():
        """Send latest frame to this phone client at its own pace."""
        last_sent = None
        while not ws.closed:
            frame = latest_frame
            if frame is not None and frame is not last_sent:
                try:
                    if isinstance(frame, bytes):
                        await ws.send_bytes(frame)
                    else:
                        await ws.send_str(frame)
                    last_sent = frame
                except Exception:
                    break
            await asyncio.sleep(0.3)

    async def recv_input():
        """Receive mouse/keyboard events from phone → forward to NB."""
        try:
            async for msg in ws:
                if msg.type == web.WSMsgType.TEXT:
                    if nb_ws is not None:
                        try:
                            await nb_ws.send_str(msg.data)
                        except Exception:
                            pass
                elif msg.type in (web.WSMsgType.CLOSE, web.WSMsgType.CLOSING,
                                  web.WSMsgType.CLOSED, web.WSMsgType.ERROR):
                    break
        except Exception:
            pass

    try:
        await asyncio.gather(push_frames(), recv_input())
    except Exception:
        pass
    finally:
        phone_clients.discard(ws)
        print(f"[relay] Browser disconnected (total: {len(phone_clients)})")

    return ws


app = web.Application()
app.router.add_get("/", index)
app.router.add_get("/health", health)
app.router.add_get("/ws/nb", ws_nb)
app.router.add_get("/ws/phone", ws_phone)
app.router.add_static("/static", Path(__file__).parent / "static")

if __name__ == "__main__":
    port = int(os.environ.get("PORT", 10000))
    print(f"[relay] Starting on port {port}")
    web.run_app(app, host="0.0.0.0", port=port)
