@echo off
setlocal
cd /d "%~dp0"
set PYTHONUTF8=1
if not exist ".venv\Scripts\python.exe" (
  echo Run Setup-Windows.cmd first.
  pause
  exit /b 2
)
echo Disconnect Portal from PS5. Connect only after READY.
pause
".venv\Scripts\python.exe" portal_windows.py --baseline
set result=%errorlevel%
echo Exit status: %result%
pause
exit /b %result%
