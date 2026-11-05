@echo off
setlocal
title Tweakr23
rem ---------------------------------------------------------------
rem  Tweakr23 launcher - asks for admin, then starts the engine.
rem  Keep Tweakr23.bat, Tweakr23.ps1 and ui.html in the same folder.
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
