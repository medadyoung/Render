<#
.SYNOPSIS
  NB Remote Client — pure PowerShell/.NET
  Connects to relay via WebSocket (auto NTLM proxy auth).
  Captures screen and replays mouse/keyboard input.

.USAGE
  Set environment variables, then run:
    $env:NB_REMOTE_RELAY = "https://render-ylyt.onrender.com"
    $env:NB_REMOTE_TOKEN = "your-token"
    .\nb_client.ps1
#>

param(
    [string]$Relay = $env:NB_REMOTE_RELAY,
    [string]$Token = $env:NB_REMOTE_TOKEN,
    [int]$FPS = $(if ($env:NB_REMOTE_FPS) { [int]$env:NB_REMOTE_FPS } else { 2 }),
    [int]$Quality = $(if ($env:NB_REMOTE_QUALITY) { [int]$env:NB_REMOTE_QUALITY } else { 40 }),
    [double]$Scale = 0.5
)

if (-not $Relay) {
    Write-Host "[nb-client] ERROR: Set `$env:NB_REMOTE_RELAY first" -ForegroundColor Red
    exit 1
}
if (-not $Token) {
    Write-Host "[nb-client] ERROR: Set `$env:NB_REMOTE_TOKEN first" -ForegroundColor Red
    exit 1
}

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

# --- Win32 input APIs ---
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class NbInput {
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, int dx, int dy, uint cButtons, uint dwExtraInfo);

    public static void MoveTo(int x, int y) { SetCursorPos(x, y); }
    public static void LeftClick(int x, int y) {
        SetCursorPos(x, y);
        mouse_event(0x0002, 0, 0, 0, 0);
        mouse_event(0x0004, 0, 0, 0, 0);
    }
    public static void RightClick(int x, int y) {
        SetCursorPos(x, y);
        mouse_event(0x0008, 0, 0, 0, 0);
        mouse_event(0x0010, 0, 0, 0, 0);
    }
    public static void DoubleClick(int x, int y) {
        SetCursorPos(x, y);
        mouse_event(0x0002, 0, 0, 0, 0);
        mouse_event(0x0004, 0, 0, 0, 0);
        System.Threading.Thread.Sleep(60);
        mouse_event(0x0002, 0, 0, 0, 0);
        mouse_event(0x0004, 0, 0, 0, 0);
    }
    public static void Scroll(int clicks) {
        mouse_event(0x0800, 0, 0, (uint)(clicks * 120), 0);
    }
}
"@

# --- Screen capture ---
function Get-ScreenJpegBytes {
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bmp = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
    $g.Dispose()

    $newW = [int]($bounds.Width * $Scale)
    $newH = [int]($bounds.Height * $Scale)
    $thumb = New-Object System.Drawing.Bitmap($newW, $newH)
    $g2 = [System.Drawing.Graphics]::FromImage($thumb)
    $g2.InterpolationMode = 'HighQualityBilinear'
    $g2.DrawImage($bmp, 0, 0, $newW, $newH)
    $g2.Dispose()
    $bmp.Dispose()

    $ms = New-Object System.IO.MemoryStream
    $encoder = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
    $params = New-Object System.Drawing.Imaging.EncoderParameters(1)
    $params.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter(
        [System.Drawing.Imaging.Encoder]::Quality, [long]$Quality
    )
    $thumb.Save($ms, $encoder, $params)
    $thumb.Dispose()

    $bytes = $ms.ToArray()
    $ms.Dispose()
    return $bytes
}

# --- Input handler ---
function Handle-Event($msg) {
    $type = $msg.type
    switch ($type) {
        "mouse_move"    { [NbInput]::MoveTo($msg.x, $msg.y) }
        "mouse_click"   {
            if ($msg.button -eq "right") {
                [NbInput]::RightClick($msg.x, $msg.y)
            } else {
                [NbInput]::LeftClick($msg.x, $msg.y)
            }
        }
        "mouse_dblclick" { [NbInput]::DoubleClick($msg.x, $msg.y) }
        "mouse_scroll"  {
            $clicks = [Math]::Max(-10, [Math]::Min(10, [int](-$msg.dy / 30)))
            if ($clicks -ne 0) {
                [NbInput]::MoveTo($msg.x, $msg.y)
                [NbInput]::Scroll($clicks)
            }
        }
        "key_char"      {
            $ch = $msg.char
            if ($ch) {
                $escaped = $ch.Replace("{","{{").Replace("}","}}").Replace("+","{+}").Replace("^","{^}").Replace("%","{%}").Replace("~","{~}")
                [System.Windows.Forms.SendKeys]::SendWait($escaped)
            }
        }
        "key_special"   {
            $map = @{
                "backspace"="{BS}"; "delete"="{DEL}"; "enter"="~"
                "escape"="{ESC}"; "tab"="{TAB}"
                "left"="{LEFT}"; "right"="{RIGHT}"; "up"="{UP}"; "down"="{DOWN}"
                "home"="{HOME}"; "end"="{END}"; "pageup"="{PGUP}"; "pagedown"="{PGDN}"
                "win"="^{ESC}"
                "f1"="{F1}"; "f2"="{F2}"; "f3"="{F3}"; "f4"="{F4}"; "f5"="{F5}"
            }
            $sk = $map[$msg.key]
            if ($sk) { [System.Windows.Forms.SendKeys]::SendWait($sk) }
        }
        "key_combo"     {
            $keys = $msg.keys
            if ($keys) {
                # Build SendKeys combo: ctrl=^, alt=%, shift=+
                $prefix = ""
                $mainKey = ""
                foreach ($k in $keys) {
                    switch ($k) {
                        "ctrl"  { $prefix += "^" }
                        "alt"   { $prefix += "%" }
                        "shift" { $prefix += "+" }
                        default { $mainKey = $k }
                    }
                }
                if ($mainKey) {
                    [System.Windows.Forms.SendKeys]::SendWait("$prefix$mainKey")
                }
            }
        }
    }
}

# --- WebSocket helpers ---
function Send-Text($ws, [string]$text) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
    $seg = New-Object System.ArraySegment[byte](,$bytes)
    $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true,
        [System.Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
}

function Send-Binary($ws, [byte[]]$data) {
    $seg = New-Object System.ArraySegment[byte](,$data)
    $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Binary, $true,
        [System.Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
}

function Recv-Text($ws, [int]$timeoutMs = 10000) {
    $buf = New-Object byte[] 65536
    $seg = New-Object System.ArraySegment[byte](,$buf)
    $cts = New-Object System.Threading.CancellationTokenSource($timeoutMs)
    try {
        $result = $ws.ReceiveAsync($seg, $cts.Token).GetAwaiter().GetResult()
        if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
            return $null
        }
        return [System.Text.Encoding]::UTF8.GetString($buf, 0, $result.Count)
    } catch {
        return $null
    } finally {
        $cts.Dispose()
    }
}

# --- Main loop ---
$wsUrl = $Relay.Replace("https://","wss://").Replace("http://","ws://") + "/ws/nb"
$bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds

Write-Host "[nb-client] NB Remote Client (PowerShell)" -ForegroundColor Cyan
Write-Host "[nb-client] Relay: $Relay"
Write-Host "[nb-client] Screen: $($bounds.Width)x$($bounds.Height)"
Write-Host "[nb-client] FPS: $FPS, Quality: $Quality, Scale: $Scale"

while ($true) {
    try {
        Write-Host "[nb-client] Connecting to $wsUrl ..." -ForegroundColor Yellow

        $ws = New-Object System.Net.WebSockets.ClientWebSocket
        $ws.Options.KeepAliveInterval = [TimeSpan]::FromSeconds(15)
        # .NET auto-uses system proxy + NTLM auth

        $ws.ConnectAsync([Uri]$wsUrl, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
        Write-Host "[nb-client] WebSocket connected" -ForegroundColor Green

        # Authenticate
        $authMsg = @{ type = "auth"; token = $Token } | ConvertTo-Json -Compress
        Send-Text $ws $authMsg
        $resp = Recv-Text $ws 10000
        if (-not $resp) { throw "No auth response" }
        $authResp = $resp | ConvertFrom-Json
        if ($authResp.type -ne "auth_ok") { throw "Auth failed: $resp" }
        Write-Host "[nb-client] Authenticated!" -ForegroundColor Green

        # Send screen info
        $info = @{ type = "screen_info"; width = $bounds.Width; height = $bounds.Height } | ConvertTo-Json -Compress
        Send-Text $ws $info

        # Main loop: send frames + check for incoming events
        $recvBuf = New-Object byte[] 65536
        $recvSeg = New-Object System.ArraySegment[byte](,$recvBuf)
        $frameInterval = [int](1000 / $FPS)

        while ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            $loopStart = [System.Diagnostics.Stopwatch]::StartNew()

            # 1. Capture and send frame
            try {
                $jpegBytes = Get-ScreenJpegBytes
                if ($jpegBytes -and $jpegBytes.Length -gt 0) {
                    Send-Binary $ws $jpegBytes
                }
            } catch {
                Write-Host "[nb-client] Capture error: $_" -ForegroundColor Red
            }

            # 2. Drain all pending incoming messages (non-blocking)
            while ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
                $cts = New-Object System.Threading.CancellationTokenSource(50)  # 50ms timeout
                try {
                    $task = $ws.ReceiveAsync($recvSeg, $cts.Token)
                    $result = $task.GetAwaiter().GetResult()
                    if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                        throw "Server closed connection"
                    }
                    if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Text) {
                        $text = [System.Text.Encoding]::UTF8.GetString($recvBuf, 0, $result.Count)
                        try {
                            $evt = $text | ConvertFrom-Json
                            Handle-Event $evt
                        } catch {
                            Write-Host "[nb-client] Event parse error: $_" -ForegroundColor DarkYellow
                        }
                    }
                } catch [System.OperationCanceledException] {
                    break  # No more messages pending
                } catch {
                    throw $_  # Real error
                } finally {
                    $cts.Dispose()
                }
            }

            # 3. Sleep remainder of frame interval
            $elapsed = $loopStart.ElapsedMilliseconds
            $sleepMs = [Math]::Max(0, $frameInterval - $elapsed)
            if ($sleepMs -gt 0) {
                Start-Sleep -Milliseconds $sleepMs
            }
        }

    } catch {
        Write-Host "[nb-client] Error: $_" -ForegroundColor Red
    } finally {
        if ($ws) {
            try { $ws.Dispose() } catch {}
        }
    }

    Write-Host "[nb-client] Reconnecting in 5s..." -ForegroundColor Yellow
    Start-Sleep -Seconds 5
}
