@echo off
REM Unirique - publie une version. Usage :  publier.bat 0.1.0
REM Le travail est en PowerShell : SHA256 et JSON y sont natifs.

if "%~1"=="" (
    echo Usage : publier.bat VERSION      exemple : publier.bat 0.1.0
    echo.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0publier.ps1" -Version %1
if errorlevel 1 pause
