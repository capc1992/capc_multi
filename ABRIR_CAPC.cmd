@echo off
setlocal
cd /d "%~dp0dist\CAPC-MULTISERVICIO-0.4.0-20260927-154149-290"
if errorlevel 1 exit /b 1
if not exist "capc_multi.exe" exit /b 1
start "" "capc_multi.exe"
