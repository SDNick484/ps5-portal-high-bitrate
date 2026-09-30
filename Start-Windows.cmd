@echo off
setlocal
cd /d "%~dp0"
set PYTHONUTF8=1
if not exist ".venv\Scripts\python.exe" (
  echo Run Setup-Windows.cmd first.
  pause
  exit /b 2
)
echo Experimental Windows preview. First complete Check and Baseline.
set /p "profile=Target 65, 100, or 200 [65]: "
if not defined profile set "profile=65"
rem Pass user input through an environment variable, never interpolate it into shell code.
".venv\Scripts\python.exe" -c "import os,sys; p=os.environ.get('profile','65'); sys.exit(0 if p in ('65','100','200') else 1)"
if errorlevel 1 exit /b 2
echo Disconnect Portal. Connect only after READY appears.
pause
".venv\Scripts\python.exe" -c "import os,sys,portal_windows; sys.argv=['portal_windows.py','--profile',os.environ['profile']]; sys.exit(portal_windows.main())"
set result=%errorlevel%
echo Exit status: %result%
pause
exit /b %result%
