"""
NB Remote Client — runs in WSL on the company NB.
WSL Python handles WebSocket (trusts system CA → passes SSL inspection).
PowerShell/.NET handles screen capture and input injection (Windows desktop).

Usage:
  export NB_REMOTE_RELAY=https://render-ylyt.onrender.com
  export NB_REMOTE_TOKEN=your-token
  python3 nb_client.py
"""

import asyncio
import base64
import json
import os
import ssl
import subprocess
import sys
import time

try:
    import websockets
except ImportError:
    print("pip3 install --break-system-packages websockets")
    sys.exit(1)

RELAY_URL = os.environ.get("NB_REMOTE_RELAY", "").rstrip("/")
AUTH_TOKEN = os.environ.get("NB_REMOTE_TOKEN", "")
FPS = int(os.environ.get("NB_REMOTE_FPS", "3"))
QUALITY = int(os.environ.get("NB_REMOTE_QUALITY", "40"))

if not RELAY_URL:
    print("Set NB_REMOTE_RELAY, e.g.: export NB_REMOTE_RELAY=https://render-ylyt.onrender.com")
    sys.exit(1)
if not AUTH_TOKEN:
    print("Set NB_REMOTE_TOKEN to the token from Render environment variables.")
    sys.exit(1)

# PowerShell script for screen capture — uses .NET System.Drawing
PS_CAPTURE = r'''
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$screens = [System.Windows.Forms.Screen]::AllScreens
$bounds = $screens[0].Bounds
$bmp = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
$g.Dispose()

# Scale down for bandwidth
$newW = [int]($bounds.Width * {scale})
$newH = [int]($bounds.Height * {scale})
$thumb = New-Object System.Drawing.Bitmap($newW, $newH)
$g2 = [System.Drawing.Graphics]::FromImage($thumb)
$g2.InterpolationMode = 'HighQualityBilinear'
$g2.DrawImage($bmp, 0, 0, $newW, $newH)
$g2.Dispose()
$bmp.Dispose()

$ms = New-Object System.IO.MemoryStream
$encoder = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object {{ $_.MimeType -eq 'image/jpeg' }}
$params = New-Object System.Drawing.Imaging.EncoderParameters(1)
$params.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, [long]{quality})
$thumb.Save($ms, $encoder, $params)
$thumb.Dispose()

[Convert]::ToBase64String($ms.ToArray())
$ms.Dispose()
'''

# PowerShell script for screen info
PS_SCREEN_INFO = r'''
Add-Type -AssemblyName System.Windows.Forms
$s = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
Write-Output "$($s.Width)x$($s.Height)"
'''

# PowerShell for mouse/keyboard — using .NET interop
PS_INPUT_INIT = r'''
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class NbInput {
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, int dx, int dy, uint cButtons, uint dwExtraInfo);
    [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, uint dwExtraInfo);
    
    public static void MoveTo(int x, int y) { SetCursorPos(x, y); }
    public static void LeftClick(int x, int y) {
        SetCursorPos(x, y);
        mouse_event(0x0002, 0, 0, 0, 0); // LEFTDOWN
        mouse_event(0x0004, 0, 0, 0, 0); // LEFTUP
    }
    public static void RightClick(int x, int y) {
        SetCursorPos(x, y);
        mouse_event(0x0008, 0, 0, 0, 0); // RIGHTDOWN
        mouse_event(0x0010, 0, 0, 0, 0); // RIGHTUP
    }
    public static void DoubleClick(int x, int y) {
        SetCursorPos(x, y);
        mouse_event(0x0002, 0, 0, 0, 0);
        mouse_event(0x0004, 0, 0, 0, 0);
        System.Threading.Thread.Sleep(50);
        mouse_event(0x0002, 0, 0, 0, 0);
        mouse_event(0x0004, 0, 0, 0, 0);
    }
    public static void Scroll(int clicks) {
        // clicks > 0 = scroll up, clicks < 0 = scroll down
        mouse_event(0x0800, 0, 0, (uint)(clicks * 120), 0); // MOUSEEVENTF_WHEEL
    }
}
"@
'''


def run_ps(script: str, timeout: float = 10) -> str:
    """Run PowerShell script on Windows side, return stdout."""
    try:
        r = subprocess.run(
            ["powershell.exe", "-NoProfile", "-Command", script],
            capture_output=True, text=True, timeout=timeout
        )
        return r.stdout.strip()
    except Exception as e:
        return ""


def capture_screen() -> bytes:
    """Capture screen as JPEG bytes via PowerShell/.NET."""
    scale = 0.5  # 50% resolution to save bandwidth
    script = PS_CAPTURE.format(scale=scale, quality=QUALITY)
    b64 = run_ps(script, timeout=8)
    if b64:
        try:
            return base64.b64decode(b64)
        except Exception:
            pass
    return b""


def get_screen_size() -> tuple:
    """Get primary screen resolution."""
    result = run_ps(PS_SCREEN_INFO, timeout=5)
    if "x" in result:
        w, h = result.split("x")
        return int(w), int(h)
    return 1920, 1080


# Pre-load input type on first use
_input_loaded = False

def ensure_input_loaded():
    global _input_loaded
    if not _input_loaded:
        run_ps(PS_INPUT_INIT, timeout=5)
        _input_loaded = True


# Key name → VK code mapping
VK_MAP = {
    "backspace": 0x08, "tab": 0x09, "enter": 0x0D, "escape": 0x1B,
    "space": 0x20, "delete": 0x2E,
    "left": 0x25, "up": 0x26, "right": 0x27, "down": 0x28,
    "home": 0x24, "end": 0x23, "pageup": 0x21, "pagedown": 0x22,
    "win": 0x5B, "ctrl": 0x11, "alt": 0x12, "shift": 0x10,
    "f1": 0x70, "f2": 0x71, "f3": 0x72, "f4": 0x73, "f5": 0x74,
    "esc": 0x1B,
}


def handle_event(msg: dict):
    """Handle input event from phone."""
    t = msg.get("type")

    if t == "mouse_move":
        run_ps(f"[NbInput]::MoveTo({msg['x']}, {msg['y']})", timeout=3)

    elif t == "mouse_click":
        btn = msg.get("button", "left")
        if btn == "right":
            run_ps(f"[NbInput]::RightClick({msg['x']}, {msg['y']})", timeout=3)
        else:
            run_ps(f"[NbInput]::LeftClick({msg['x']}, {msg['y']})", timeout=3)

    elif t == "mouse_dblclick":
        run_ps(f"[NbInput]::DoubleClick({msg['x']}, {msg['y']})", timeout=3)

    elif t == "mouse_scroll":
        x, y = msg.get("x", 0), msg.get("y", 0)
        dy = msg.get("dy", 0)
        # Move to position, then scroll
        clicks = max(-10, min(10, int(-dy / 30)))  # normalize delta
        if clicks != 0:
            run_ps(f"[NbInput]::MoveTo({x}, {y})", timeout=3)
            run_ps(f"[NbInput]::Scroll({clicks})", timeout=3)

    elif t == "key_char":
        ch = msg.get("char", "")
        if ch:
            # Use SendKeys for regular characters
            # Escape special SendKeys chars
            ch_escaped = ch.replace("{", "{{").replace("}", "}}").replace("+", "{+}").replace("^", "{^}").replace("%", "{%}").replace("~", "{~}")
            run_ps(f'''
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.SendKeys]::SendWait("{ch_escaped}")
''', timeout=3)

    elif t == "key_special":
        key = msg.get("key", "")
        sendkeys_map = {
            "backspace": "{BS}", "delete": "{DEL}", "enter": "~",
            "escape": "{ESC}", "tab": "{TAB}",
            "left": "{LEFT}", "right": "{RIGHT}", "up": "{UP}", "down": "{DOWN}",
            "home": "{HOME}", "end": "{END}", "pageup": "{PGUP}", "pagedown": "{PGDN}",
            "win": "^{ESC}",  # Ctrl+Esc = Start menu
            "f1": "{F1}", "f2": "{F2}", "f3": "{F3}", "f4": "{F4}", "f5": "{F5}",
        }
        sk = sendkeys_map.get(key)
        if sk:
            run_ps(f'''
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.SendKeys]::SendWait("{sk}")
''', timeout=3)

    elif t == "key_combo":
        keys = msg.get("keys", [])
        if keys:
            combo = "".join(keys)
            run_ps(f'''
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.SendKeys]::SendWait("{combo}")
''', timeout=3)


async def run():
    ws_url = RELAY_URL.replace("https://", "wss://").replace("http://", "ws://")
    ws_url = ws_url + "/ws/nb"

    ssl_ctx = ssl.create_default_context()  # WSL trusts system CAs

    # Get screen size once
    sw, sh = get_screen_size()
    print(f"[nb-client] Screen: {sw}x{sh}")

    # Pre-load input type
    ensure_input_loaded()
    print("[nb-client] Input driver loaded")

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
                # Auth
                await ws.send(json.dumps({"type": "auth", "token": AUTH_TOKEN}))
                resp = json.loads(await asyncio.wait_for(ws.recv(), timeout=10))
                if resp.get("type") != "auth_ok":
                    print(f"[nb-client] Auth failed: {resp}")
                    await asyncio.sleep(5)
                    continue

                print("[nb-client] Connected and authenticated!")

                # Send screen info
                await ws.send(json.dumps({
                    "type": "screen_info",
                    "width": sw,
                    "height": sh,
                }))

                async def send_frames():
                    interval = 1.0 / FPS
                    while True:
                        t0 = time.monotonic()
                        try:
                            frame = await asyncio.get_event_loop().run_in_executor(
                                None, capture_screen
                            )
                            if frame:
                                await ws.send(frame)
                        except Exception:
                            break
                        elapsed = time.monotonic() - t0
                        await asyncio.sleep(max(0, interval - elapsed))

                async def recv_events():
                    while True:
                        raw = await ws.recv()
                        if isinstance(raw, str):
                            try:
                                data = json.loads(raw)
                                # Run input handling in executor to not block
                                await asyncio.get_event_loop().run_in_executor(
                                    None, handle_event, data
                                )
                            except Exception as e:
                                print(f"[nb-client] Event error: {e}")

                tasks = [
                    asyncio.create_task(send_frames()),
                    asyncio.create_task(recv_events()),
                ]
                done, pending = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
                for t in pending:
                    t.cancel()

        except Exception as e:
            print(f"[nb-client] Connection error: {e}")

        print("[nb-client] Reconnecting in 5s...")
        await asyncio.sleep(5)


if __name__ == "__main__":
    print("[nb-client] NB Remote Client (WSL + PowerShell)")
    print(f"[nb-client] Relay: {RELAY_URL}")
    print(f"[nb-client] FPS: {FPS}, Quality: {QUALITY}")
    asyncio.run(run())
