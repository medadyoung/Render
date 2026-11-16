"""
NB-Remote Relay Server
Runs on Render (free tier). Bridges NB ↔ Phone via WebSocket.

Architecture:
  Phone (Chrome) ──WSS──▶ This server ◀──WSS── NB (Python client)
  
The NB client captures screenshots and sends them here.
The phone browser displays them and sends back mouse/keyboard events.
"""

import asyncio
import json
import os
import secrets
from pathlib import Path

from aiohttp import web

# Shared state
nb_ws = None          # WebSocket connection from NB client
phone_clients = set() # WebSocket connections from phone browsers
AUTH_TOKEN = os.environ.get("NB_REMOTE_TOKEN", "change-me-to-a-secret")


async def index(request):
    """Serve the phone UI."""
    html = (Path(__file__).parent / "static" / "index.html").read_text()
    return web.Response(text=html, content_type="text/html")


async def health(request):
    """Health check for Render."""
    return web.json_response({
        "status": "ok",
        "nb_connected": nb_ws is not None,
        "phone_clients": len(phone_clients),
    })


async def ws_nb(request):
    """WebSocket endpoint for the NB client."""
    global nb_ws

    ws = web.WebSocketResponse(max_msg_size=10 * 1024 * 1024)  # 10MB for screenshots
    await ws.prepare(request)

    # Auth check
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
    nb_ws = ws
    print("[relay] NB connected")

    # Notify phone clients
    for pc in list(phone_clients):
        try:
            await pc.send_json({"type": "nb_status", "connected": True})
        except Exception:
            pass

    try:
        async for msg in ws:
            if msg.type == web.WSMsgType.BINARY:
                # Screenshot frame from NB (binary) → broadcast to phone clients
                for pc in list(phone_clients):
                    try:
                        await pc.send_bytes(msg.data)
                    except Exception:
                        phone_clients.discard(pc)
            elif msg.type == web.WSMsgType.TEXT:
                # Could be a base64 frame or a JSON control message
                # Forward as-is to all phone clients — browser will decode
                for pc in list(phone_clients):
                    try:
                        await pc.send_str(msg.data)
                    except Exception:
                        phone_clients.discard(pc)
    finally:
        nb_ws = None
        print("[relay] NB disconnected")
        for pc in list(phone_clients):
            try:
                await pc.send_json({"type": "nb_status", "connected": False})
            except Exception:
                pass

    return ws


async def ws_phone(request):
    """WebSocket endpoint for phone browsers."""
    global nb_ws

    ws = web.WebSocketResponse()
    await ws.prepare(request)
    phone_clients.add(ws)
    print(f"[relay] Phone connected (total: {len(phone_clients)})")

    # Tell phone whether NB is connected
    await ws.send_json({"type": "nb_status", "connected": nb_ws is not None})

    try:
        async for msg in ws:
            if msg.type == web.WSMsgType.TEXT:
                # Mouse/keyboard events from phone → forward to NB
                if nb_ws is not None:
                    try:
                        await nb_ws.send_str(msg.data)
                    except Exception:
                        pass
    finally:
        phone_clients.discard(ws)
        print(f"[relay] Phone disconnected (total: {len(phone_clients)})")

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
