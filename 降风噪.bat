@echo off
rem ============================================================
rem  Wind noise remover - drag & drop launcher
rem
rem  Drag video file(s) onto this .bat file. A preset word can be
rem  mixed in anywhere: light / medium / strong / voice
rem
rem  Examples (cmd):
rem    "%~nx0" "D:\videos\a.mp4"
rem    "%~nx0" "D:\videos\a.mp4" strong
rem    "%~nx0" "D:\videos\a.mp4" "D:\videos\b.mp4" voice
rem ============================================================
chcp 65001 >nul
setlocal EnableExtensions
set "PS1=%~dp0reduce-wind-noise.ps1"

if not exist "%PS1%" (
  echo [ERROR] reduce-wind-noise.ps1 not found next to this file.
  pause
  exit /b 1
)
if "%~1"=="" (
  echo.
  echo   How to use:
  echo     - Drag video file^(s^) onto this .bat file, or
  echo     - cmd:  "%~nx0" "D:\videos\a.mp4" [light^|medium^|strong^|voice]
  echo.
  echo   Presets: light / medium^(default^) / strong / voice
  echo.
  pause
  exit /b 1
)

echo.
rem %* keeps the original quoting, so paths with spaces stay intact
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
set "CODE=%ERRORLEVEL%"
echo.
if not "%CODE%"=="0" echo [exit code %CODE%]
pause
exit /b %CODE%
