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
    [string]$Relay  = $env:NB_REMOTE_RELAY,
    [string]$Token  = $env:NB_REMOTE_TOKEN,
    [int]$FPS       = $(if ($env:NB_REMOTE_FPS)    { [int]$env:NB_REMOTE_FPS }    else { 2 }),
    [int]$Quality   = $(if ($env:NB_REMOTE_QUALITY) { [int]$env:NB_REMOTE_QUALITY } else { 40 }),
    [double]$Scale  = 0.5
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

# ── Screen capture (pre-cache encoder) ──
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

function Invoke-InputEvent($msg) {
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
            $mainKey = ""
            foreach ($k in $msg.keys) {
                switch ($k) {
                    "ctrl"  { $prefix += "^" }
                    "alt"   { $prefix += "%" }
                    "shift" { $prefix += "+" }
                    default { $mainKey = $k }
                }
            }
            if ($mainKey) { [System.Windows.Forms.SendKeys]::SendWait("$prefix$mainKey") }
        }
    }
}

# ── WebSocket helpers (use .Wait() instead of .GetAwaiter().GetResult()) ──
function Send-WsText($socket, [string]$text) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
    $seg = New-Object System.ArraySegment[byte](,$bytes)
    $task = $socket.SendAsync($seg,
        [System.Net.WebSockets.WebSocketMessageType]::Text, $true,
        [System.Threading.CancellationToken]::None)
    $task.Wait(10000) | Out-Null
}

function Receive-WsText($socket, [int]$timeoutMs = 10000) {
    $buf = New-Object byte[] 65536
    $seg = New-Object System.ArraySegment[byte](,$buf)
    $task = $socket.ReceiveAsync($seg, [System.Threading.CancellationToken]::None)
    if (-not $task.Wait($timeoutMs)) { return $null }
    $r = $task.Result
    if ($r.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { return $null }
    return [System.Text.Encoding]::UTF8.GetString($buf, 0, $r.Count)
}

# ── Main ──
$wsUrl  = $Relay.Replace("https://","wss://").Replace("http://","ws://") + "/ws/nb"
$bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$frameMs = [int](1000 / $FPS)

Write-Host ""
Write-Host "  ======================================" -ForegroundColor Cyan
Write-Host "       NB Remote Client (v1.0)          " -ForegroundColor Cyan
Write-Host "  ======================================" -ForegroundColor Cyan
Write-Host "  Relay:   $Relay"
Write-Host "  Screen:  $($bounds.Width)x$($bounds.Height) -> $([int]($bounds.Width*$Scale))x$([int]($bounds.Height*$Scale))"
Write-Host "  FPS:     $FPS   Quality: $Quality"
Write-Host "  Press Ctrl+C to stop." -ForegroundColor DarkGray
Write-Host ""

while ($true) {
    $socket = $null
    try {
        Write-Host "[nb] Connecting..." -ForegroundColor Yellow -NoNewline

        $socket = New-Object System.Net.WebSockets.ClientWebSocket
        $socket.Options.KeepAliveInterval = [TimeSpan]::FromSeconds(15)
        $socket.Options.SetBuffer(65536, 65536)

        $connectTask = $socket.ConnectAsync([Uri]$wsUrl, [System.Threading.CancellationToken]::None)
        $connectTask.Wait(15000) | Out-Null
        if ($socket.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
            throw "Connect failed (state: $($socket.State))"
        }
        Write-Host " OK" -ForegroundColor Green

        # Auth
        $authJson = @{ type = "auth"; token = $Token } | ConvertTo-Json -Compress
        Send-WsText $socket $authJson
        $resp = Receive-WsText $socket 10000
        if (-not $resp) { throw "No auth response" }
        $authResp = $resp | ConvertFrom-Json
        if ($authResp.type -ne "auth_ok") { throw "Auth failed: $resp" }
        Write-Host "[nb] Authenticated" -ForegroundColor Green

        # Screen info
        $infoJson = @{ type = "screen_info"; width = $bounds.Width; height = $bounds.Height } | ConvertTo-Json -Compress
        Send-WsText $socket $infoJson

        # Reusable receive buffer + persistent receive task
        $recvBuf = New-Object byte[] 65536
        $recvSeg = New-Object System.ArraySegment[byte](,$recvBuf)
        $frameCount = 0

        # Start a persistent receive task (never cancel it — cancelling aborts the socket)
        $recvTask = $socket.ReceiveAsync($recvSeg, [System.Threading.CancellationToken]::None)

        # ── Frame loop ──
        while ($socket.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()

            # 1. Capture and send frame (base64-encoded as text to survive proxy inspection)
            try {
                $jpeg = Get-ScreenJpeg
                if ($jpeg -and $jpeg.Length -gt 0) {
                    $b64 = [Convert]::ToBase64String($jpeg)
                    $frameJson = "{`"type`":`"frame`",`"data`":`"$b64`"}"
                    Send-WsText $socket $frameJson
                    $frameCount++
                    if ($frameCount % 30 -eq 0) {
                        Write-Host "[nb] Frames: $frameCount  ($([int]($jpeg.Length/1024)) KB/frame)" -ForegroundColor DarkGray
                    }
                }
            }
            catch {
                Write-Host "[nb] Capture error: $_" -ForegroundColor Red
                break
            }

            # 2. Check if receive task completed (non-blocking — never cancel!)
            while ($recvTask.IsCompleted -and ($socket.State -eq [System.Net.WebSockets.WebSocketState]::Open)) {
                try {
                    $result = $recvTask.Result

                    if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                        Write-Host "[nb] Server closed" -ForegroundColor Yellow
                        break
                    }
                    if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Text -and $result.Count -gt 0) {
                        $text = [System.Text.Encoding]::UTF8.GetString($recvBuf, 0, $result.Count)
                        try { Invoke-InputEvent ($text | ConvertFrom-Json) } catch { }
                    }

                    # Start next receive
                    $recvTask = $socket.ReceiveAsync($recvSeg, [System.Threading.CancellationToken]::None)
                }
                catch {
                    Write-Host "[nb] Receive error: $_" -ForegroundColor Red
                    break
                }
            }

            # 3. Pace frames
            $elapsed = $sw.ElapsedMilliseconds
            $sleepMs = [Math]::Max(0, $frameMs - $elapsed)
            if ($sleepMs -gt 0) { Start-Sleep -Milliseconds $sleepMs }
        }

        Write-Host "[nb] WebSocket closed (state: $($socket.State))" -ForegroundColor Yellow

    }
    catch {
        Write-Host "[nb] Error: $_" -ForegroundColor Red
    }
    finally {
        if ($socket) {
            try { $socket.Dispose() } catch { }
        }
    }

    Write-Host "[nb] Reconnecting in 5s..." -ForegroundColor Yellow
    Start-Sleep -Seconds 5
}
