@echo off
REM Unirique - serveur data : une fenetre Windows Terminal, deux onglets.
REM   Tailscale Funnel expose le port local en HTTPS sur https://<...>.ts.net
REM   Le serveur data ecoute sur 127.0.0.1:<PORT>
REM PORT doit concorder avec la ligne "serveur,port" de Server_Data\config.csv.

set "PORT=8080"
set "DOSSIER=%~dp0Servers\Server_Data"
set "BINAIRE=%DOSSIER%\target\release\unirique_server_data.exe"
if not exist "%BINAIRE%" set "BINAIRE=%DOSSIER%\target\debug\unirique_server_data.exe"

if not exist "%BINAIRE%" (echo [ERREUR] Serveur non compile : cargo build --release & pause & exit /b 1)

REM Chemins courts 8.3 : sans espaces, ils evitent les guillemets imbriques dans
REM la ligne de wt, fragiles a cause du ";" qui separe les onglets.
for %%I in ("%ProgramFiles%\Tailscale\tailscale.exe") do set "TAILSCALE=%%~sI"
for %%I in ("%DOSSIER%") do set "DOSSIER=%%~sI"
for %%I in ("%BINAIRE%") do set "BINAIRE=%%~sI"

if not exist "%TAILSCALE%" (echo [ERREUR] Tailscale introuvable. & pause & exit /b 1)

REM Fermer la fenetre ne laisse pas toujours les processus se terminer proprement :
REM le funnel reste alors enregistre cote service tailscaled, et le port occupe.
REM On nettoie donc avant de lancer, pour pouvoir relancer sans rien fermer.
REM (funnel reset efface TOUTE la config funnel de cette machine.)
%TAILSCALE% funnel reset >nul 2>nul
taskkill /F /IM unirique_server_data.exe >nul 2>nul

REM /k garde l'onglet ouvert (journaux + arret manuel).
REM -d fixe le repertoire de travail : le serveur lit config.csv en relatif.
wt new-tab --title "Tailscale Funnel" cmd /k %TAILSCALE% funnel %PORT% ; new-tab --title "Serveur Data" -d %DOSSIER% cmd /k %BINAIRE%
