@echo off
setlocal
title Tweakr23
rem ---------------------------------------------------------------
rem  Tweakr23 by Tech Merlin - https://github.com/thetechmerlin
rem  Asks for admin, then starts the engine. Keep the folder layout
rem  from the download (windows\ next to ui\).
rem ---------------------------------------------------------------

net session >nul 2>&1
if %errorlevel% neq 0 (
  echo Requesting administrator rights...
  powershell -NoProfile -Command "Start-Process -FilePath \"%~f0\" -Verb RunAs"
  exit /b
)

cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Tweakr23.ps1"
endlocal
