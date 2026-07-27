@echo off
REM Unirique - lancement du client.
REM   Utilise l'executable exporte s'il existe, sinon l'editeur Godot.
REM   Tout argument est transmis tel quel, apres le "--" attendu par Godot :
REM     start_client.bat -- --join=192.168.1.20
REM     start_client.bat -- --data=http://127.0.0.1:8080
REM Le client lance lui-meme son serveur de jeu local : rien d'autre a demarrer.

set "PROJET=%~dp0Clients\client-godot"
set "CLIENT=%~dp0release\unirique.exe"

REM L'exporte d'abord : c'est ce que joueront les testeurs.
REM Son dossier Games\ doit etre a cote de lui (les jeux vivent hors du .pck).
if exist "%CLIENT%" (
    "%CLIENT%" %*
    exit /b 0
)

REM A defaut, l'editeur. Le glob survit aux montees de version de Godot ;
REM la variante _console laisse voir les journaux du client.
for %%I in ("D:\Godot\Godot_v*_win64_console.exe") do set "GODOT=%%~fI"
if not defined GODOT (echo [ERREUR] Godot introuvable dans D:\Godot & pause & exit /b 1)

"%GODOT%" --path "%PROJET%" %*
