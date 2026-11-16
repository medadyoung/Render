<#
.SYNOPSIS
  NB Remote Client — pure PowerShell/.NET
  Connects to relay via WebSocket (auto NTLM proxy auth).
  Captures screen → sends JPEG frames to relay.
  Receives mouse/keyboard events from relay → replays on desktop.

.USAGE
  Double-click start.bat, or:
    powershell -ExecutionPolicy Bypass -File nb_client.ps1 `
      -Relay "https://render-ylyt.onrender.com" `
      -Token "your-token"
#>

param(
    [string]$Relay = $env:NB_REMOTE_RELAY,
    [string]$Token = $env:NB_REMOTE_TOKEN,
    [int]$FPS     = $(if ($env:NB_REMOTE_FPS)     { [int]$env:NB_REMOTE_FPS }     else { 2 }),
    [int]$Quality = $(if ($env:NB_REMOTE_QUALITY)  { [int]$env:NB_REMOTE_QUALITY } else { 40 }),
    [double]$Scale = 0.5
)

if (-not $Relay) { Write-Host "[nb] ERROR: -Relay or `$env:NB_REMOTE_RELAY required" -ForegroundColor Red; exit 1 }
if (-not $Token) { Write-Host "[nb] ERROR: -Token or `$env:NB_REMOTE_TOKEN required" -ForegroundColor Red; exit 1 }

# ── Assemblies ──
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class NbInput {
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, int dx, int dy, uint d, uint x);
    public static void MoveTo(int x, int y) { SetCursorPos(x, y); }
    public static void LeftClick(int x, int y) {
        SetCursorPos(x, y); mouse_event(0x0002,0,0,0,0); mouse_event(0x0004,0,0,0,0);
    }
    public static void RightClick(int x, int y) {
        SetCursorPos(x, y); mouse_event(0x0008,0,0,0,0); mouse_event(0x0010,0,0,0,0);
    }
    public static void DoubleClick(int x, int y) {
        SetCursorPos(x, y);
        mouse_event(0x0002,0,0,0,0); mouse_event(0x0004,0,0,0,0);
        System.Threading.Thread.Sleep(60);
        mouse_event(0x0002,0,0,0,0); mouse_event(0x0004,0,0,0,0);
    }
    public static void Scroll(int clicks) {
        mouse_event(0x0800, 0, 0, (uint)(clicks * 120), 0);
    }
}
"@

# ── Screen capture ──
$script:jpegEncoder = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
    Where-Object { $_.MimeType -eq 'image/jpeg' }
$script:jpegParams = New-Object System.Drawing.Imaging.EncoderParameters(1)
$script:jpegParams.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter(
    [System.Drawing.Imaging.Encoder]::Quality, [long]$Quality)

function Get-ScreenJpeg {
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bmp = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
    $g.Dispose()

    $w = [int]($bounds.Width  * $Scale)
    $h = [int]($bounds.Height * $Scale)
    $thumb = New-Object System.Drawing.Bitmap($w, $h)
    $g2 = [System.Drawing.Graphics]::FromImage($thumb)
    $g2.InterpolationMode = 'HighQualityBilinear'
    $g2.DrawImage($bmp, 0, 0, $w, $h)
    $g2.Dispose(); $bmp.Dispose()

    $ms = New-Object System.IO.MemoryStream
    $thumb.Save($ms, $script:jpegEncoder, $script:jpegParams)
    $thumb.Dispose()
    $bytes = $ms.ToArray(); $ms.Dispose()
    return ,$bytes
}

# ── Input handler ──
$script:sendKeysMap = @{
    "backspace"="{BS}"; "delete"="{DEL}"; "enter"="~"
    "escape"="{ESC}"; "tab"="{TAB}"
    "left"="{LEFT}"; "right"="{RIGHT}"; "up"="{UP}"; "down"="{DOWN}"
    "home"="{HOME}"; "end"="{END}"; "pageup"="{PGUP}"; "pagedown"="{PGDN}"
    "win"="^{ESC}"
    "f1"="{F1}"; "f2"="{F2}"; "f3"="{F3}"; "f4"="{F4}"; "f5"="{F5}"
}

function Handle-Event($msg) {
    switch ($msg.type) {
        "mouse_move"    { [NbInput]::MoveTo($msg.x, $msg.y) }
        "mouse_click"   {
            if ($msg.button -eq "right") { [NbInput]::RightClick($msg.x, $msg.y) }
            else                         { [NbInput]::LeftClick($msg.x, $msg.y) }
        }
        "mouse_dblclick" { [NbInput]::DoubleClick($msg.x, $msg.y) }
        "mouse_scroll"  {
            $c = [Math]::Max(-10, [Math]::Min(10, [int](-$msg.dy / 30)))
            if ($c -ne 0) { [NbInput]::MoveTo($msg.x, $msg.y); [NbInput]::Scroll($c) }
        }
        "key_char" {
            $ch = $msg.char
            if ($ch) {
                $e = $ch.Replace("{","{{").Replace("}","}}").Replace("+","{+}").Replace("^","{^}").Replace("%","{%}").Replace("~","{~}")
                [System.Windows.Forms.SendKeys]::SendWait($e)
            }
        }
        "key_special" {
            $sk = $script:sendKeysMap[$msg.key]
            if ($sk) { [System.Windows.Forms.SendKeys]::SendWait($sk) }
        }
        "key_combo" {
            $prefix = ""
            $main   = ""
            foreach ($k in $msg.keys) {
                switch ($k) {
                    "ctrl"  { $prefix += "^" }
                    "alt"   { $prefix += "%" }
                    "shift" { $prefix += "+" }
                    default { $main = $k }
                }
            }
            if ($main) { [System.Windows.Forms.SendKeys]::SendWait("$prefix$main") }
        }
    }
}

# ── WebSocket helpers ──
function WS-Send([System.Net.WebSockets.ClientWebSocket]$ws, [byte[]]$data, [string]$type = "Binary") {
    $seg = New-Object System.ArraySegment[byte](,$data)
    $msgType = if ($type -eq "Text") {
        [System.Net.WebSockets.WebSocketMessageType]::Text
    } else {
        [System.Net.WebSockets.WebSocketMessageType]::Binary
    }
    $ws.SendAsync($seg, $msgType, $true, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
}

function WS-SendText([System.Net.WebSockets.ClientWebSocket]$ws, [string]$text) {
    WS-Send $ws ([System.Text.Encoding]::UTF8.GetBytes($text)) "Text"
}

function WS-RecvText([System.Net.WebSockets.ClientWebSocket]$ws, [int]$timeoutMs = 10000) {
    $buf = New-Object byte[] 65536
    $seg = New-Object System.ArraySegment[byte](,$buf)
    $cts = New-Object System.Threading.CancellationTokenSource($timeoutMs)
    try {
        $r = $ws.ReceiveAsync($seg, $cts.Token).GetAwaiter().GetResult()
        if ($r.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { return $null }
        return [System.Text.Encoding]::UTF8.GetString($buf, 0, $r.Count)
    } catch { return $null }
    finally { $cts.Dispose() }
}

# ── Main ──
$wsUrl  = $Relay.Replace("https://","wss://").Replace("http://","ws://") + "/ws/nb"
$bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$frameMs = [int](1000 / $FPS)

Write-Host ""
Write-Host "  ╔══════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "  ║       NB Remote Client (v1.0)        ║" -ForegroundColor Cyan
Write-Host "  ╚══════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host "  Relay:   $Relay"
Write-Host "  Screen:  $($bounds.Width)x$($bounds.Height) → $([int]($bounds.Width*$Scale))x$([int]($bounds.Height*$Scale))"
Write-Host "  FPS:     $FPS   Quality: $Quality"
Write-Host "  Press Ctrl+C to stop." -ForegroundColor DarkGray
Write-Host ""

while ($true) {
    $ws = $null
    try {
        Write-Host "[nb] Connecting..." -ForegroundColor Yellow -NoNewline

        $ws = New-Object System.Net.WebSockets.ClientWebSocket
        $ws.Options.KeepAliveInterval = [TimeSpan]::FromSeconds(15)

        $ws.ConnectAsync([Uri]$wsUrl, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
        Write-Host " OK" -ForegroundColor Green

        # Auth
        WS-SendText $ws (@{ type="auth"; token=$Token } | ConvertTo-Json -Compress)
        $resp = WS-RecvText $ws 10000
        if (-not $resp) { throw "No auth response" }
        $r = $resp | ConvertFrom-Json
        if ($r.type -ne "auth_ok") { throw "Auth failed: $resp" }
        Write-Host "[nb] Authenticated ✓" -ForegroundColor Green

        # Screen info
        WS-SendText $ws (@{ type="screen_info"; width=$bounds.Width; height=$bounds.Height } | ConvertTo-Json -Compress)

        # Reusable receive buffer
        $recvBuf = New-Object byte[] 65536
        $recvSeg = New-Object System.ArraySegment[byte](,$recvBuf)
        $frameCount = 0

        # ── Frame loop ──
        while ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()

            # Send screenshot
            try {
                $jpeg = Get-ScreenJpeg
                if ($jpeg -and $jpeg.Length -gt 0) {
                    WS-Send $ws $jpeg "Binary"
                    $frameCount++
                    if ($frameCount % 30 -eq 0) {
                        Write-Host "[nb] Frames sent: $frameCount  ($([int]($jpeg.Length/1024)) KB/frame)" -ForegroundColor DarkGray
                    }
                }
            } catch {
                Write-Host "[nb] Capture error: $_" -ForegroundColor Red
            }

            # Drain pending input events (non-blocking)
            $drainLoop = $true
            while ($drainLoop -and $ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
                $cts = New-Object System.Threading.CancellationTokenSource(30)
                try {
                    $result = $ws.ReceiveAsync($recvSeg, $cts.Token).GetAwaiter().GetResult()
                    if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                        Write-Host "[nb] Server sent close frame" -ForegroundColor Yellow
                        $drainLoop = $false
                        break
                    }
                    if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Text -and $result.Count -gt 0) {
                        $text = [System.Text.Encoding]::UTF8.GetString($recvBuf, 0, $result.Count)
                        try {
                            Handle-Event ($text | ConvertFrom-Json)
                        } catch {
                            # Ignore event handling errors silently
                        }
                    }
                } catch {
                    # Timeout or cancel → no more pending messages, exit drain loop
                    $drainLoop = $false
                } finally {
                    $cts.Dispose()
                }
            }

            # Pace frames
            $elapsed = $sw.ElapsedMilliseconds
            $sleep = [Math]::Max(0, $frameMs - $elapsed)
            if ($sleep -gt 0) { Start-Sleep -Milliseconds $sleep }
        }

        Write-Host "[nb] WebSocket state: $($ws.State)" -ForegroundColor Yellow

    } catch {
        Write-Host "[nb] Error: $_" -ForegroundColor Red
    } finally {
        if ($ws) { try { $ws.Dispose() } catch {} }
    }

    Write-Host "[nb] Reconnecting in 5s..." -ForegroundColor Yellow
    Start-Sleep -Seconds 5
}
