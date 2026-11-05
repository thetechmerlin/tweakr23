@echo off
rem Tweakr23 - puts a "Tweakr23" shortcut (with the eye icon) on your Desktop and in the Start menu.
rem Run this once from the folder you want to keep Tweakr23 in. Move the folder? Run it again.
setlocal
set "HERE=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$here = $env:HERE.TrimEnd('\');" ^
  "$sh = New-Object -ComObject WScript.Shell;" ^
  "$targets = @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'));" ^
  "foreach ($d in $targets) {" ^
  "  $lnk = $sh.CreateShortcut((Join-Path $d 'Tweakr23.lnk'));" ^
  "  $lnk.TargetPath = Join-Path $here 'Tweakr23.bat';" ^
  "  $lnk.WorkingDirectory = $here;" ^
  "  $lnk.IconLocation = (Join-Path $here 'tweakr23.ico') + ',0';" ^
  "  $lnk.Description = 'Tweakr23 - light Windows tune-up panel by Tech Merlin';" ^
  "  $lnk.WindowStyle = 7;" ^
  "  $lnk.Save();" ^
  "  Write-Host ('Created ' + (Join-Path $d 'Tweakr23.lnk')) -ForegroundColor Cyan" ^
  "}"
echo.
echo Done. Launch Tweakr23 from your Desktop or Start menu.
pause
