@echo off
REM NB Remote Client launcher
REM Edit the two lines below, then double-click this file to start.

set NB_REMOTE_RELAY=https://YOUR-APP-NAME.onrender.com
set NB_REMOTE_TOKEN=YOUR-TOKEN-HERE
set NB_REMOTE_FPS=5
set NB_REMOTE_QUALITY=50

echo Starting NB Remote Client...
echo Relay: %NB_REMOTE_RELAY%
echo Press Ctrl+C to stop.
echo.

python nb_client.py
pause
