"""
NB-Remote Relay Server v1.1
Runs on Render.com (free tier). Bridges NB ↔ Phone/PC via WebSocket.

Key design: non-blocking frame forwarding. If a phone client is slow,
frames are dropped rather than blocking the NB connection.
"""

import asyncio
import json
import os
from pathlib import Path

from aiohttp import web

nb_ws = None
phone_clients = set()
AUTH_TOKEN = os.environ.get("NB_REMOTE_TOKEN", "change-me-to-a-secret")

# Latest frame — phones grab this on their own pace
latest_frame = None


async def index(request):
    html = (Path(__file__).parent / "static" / "index.html").read_text()
    return web.Response(text=html, content_type="text/html")


async def health(request):
    return web.json_response({
        "status": "ok",
        "nb_connected": nb_ws is not None,
        "phone_clients": len(phone_clients),
    })


async def ws_nb(request):
    """WebSocket endpoint for the NB client."""
    global nb_ws, latest_frame

    ws = web.WebSocketResponse(max_msg_size=10 * 1024 * 1024)
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
    print("[relay] NB connected")

    for pc in list(phone_clients):
        try:
            await pc.send_json({"type": "nb_status", "connected": True})
        except Exception:
            pass

    try:
        async for msg in ws:
            if msg.type == web.WSMsgType.TEXT:
                # Store latest frame or forward control messages
                try:
                    data = json.loads(msg.data)
                    if data.get("type") == "frame":
                        # Just store it — phone clients will pick it up
                        latest_frame = msg.data
                    else:
                        # Control messages (screen_info etc.) — forward immediately
                        for pc in list(phone_clients):
                            try:
                                await pc.send_str(msg.data)
                            except Exception:
                                phone_clients.discard(pc)
                except (json.JSONDecodeError, Exception):
                    pass
            elif msg.type == web.WSMsgType.BINARY:
                latest_frame = msg.data
    finally:
        nb_ws = None
        latest_frame = None
        print("[relay] NB disconnected")
        for pc in list(phone_clients):
            try:
                await pc.send_json({"type": "nb_status", "connected": False})
            except Exception:
                pass

    return ws


async def ws_phone(request):
    """WebSocket endpoint for phone/PC browsers."""
    global nb_ws, latest_frame

    ws = web.WebSocketResponse()
    await ws.prepare(request)
    phone_clients.add(ws)
    print(f"[relay] Browser connected (total: {len(phone_clients)})")

    await ws.send_json({"type": "nb_status", "connected": nb_ws is not None})

    # Two tasks: push frames to phone + receive input from phone

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
            await asyncio.sleep(0.3)  # ~3 FPS max to phone

    async def recv_input():
        """Receive mouse/keyboard events from phone → forward to NB."""
        async for msg in ws:
            if msg.type == web.WSMsgType.TEXT:
                if nb_ws is not None:
                    try:
                        await nb_ws.send_str(msg.data)
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
