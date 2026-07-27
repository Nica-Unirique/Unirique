# Unirique - construit une version complete et la publie sur GitHub.
#   .\publier.bat 0.1.0
#
# Enchaine : compilation des modules WASM -> export Godot -> empreintes ->
# manifeste -> release GitHub.
#
# Le manifeste est ce qui rend les mises a jour differentielles possibles : le
# lanceur compare les empreintes et ne telecharge que ce qui a change. C'est
# aussi pourquoi le .pck n'est PAS embarque dans l'exe — separes, une correction
# de code pese 0,4 Mo au lieu de 116.

param(
    [Parameter(Mandatory = $true, HelpMessage = "Numero de version, ex. 0.1.0")]
    [string]$Version,
    # Tout construire et verifier, sans rien envoyer sur GitHub. A utiliser
    # avant une vraie publication : une release ne se retire pas discretement.
    [switch]$Essai
)

$ErrorActionPreference = "Stop"
$Racine = $PSScriptRoot
$Projet = Join-Path $Racine "Clients\client-godot"
$Release = Join-Path $Racine "release"

# Quel module compile va ou. Ajouter un jeu = ajouter une ligne.
$Modules = [ordered]@{
    "identity"   = "Clients\client-godot\identity.wasm"
    "hub_client" = "Clients\client-godot\Games\Hub\client.wasm"
    "hub_server" = "Clients\client-godot\Games\Hub\server.wasm"
    "collect"    = "Clients\client-godot\Games\Collect\client.wasm"
}

function Etape($texte) { Write-Host "`n=== $texte" -ForegroundColor Cyan }
function Echec($texte) { Write-Host "[ERREUR] $texte" -ForegroundColor Red; exit 1 }

# Les outils en ligne de commande ecrivent leur progression sur la sortie
# d'erreur — cargo comme Godot. Avec ErrorActionPreference a "Stop", PowerShell
# prendrait ces lignes pour des pannes. On revient donc a "Continue" le temps de
# l'appel, et on juge sur le code de sortie, qui lui ne ment pas.
function Executer($exe, $arguments) {
    $ancien = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & $exe @arguments 2>&1 | ForEach-Object { "$_" } | Out-Null
    $code = $LASTEXITCODE
    $ErrorActionPreference = $ancien
    return $code
}

# --- Outils ---------------------------------------------------------------

$Godot = Get-ChildItem "D:\Godot\Godot_v*_win64_console.exe" -ErrorAction SilentlyContinue |
    Select-Object -Last 1 -ExpandProperty FullName
if (-not $Godot) { Echec "Godot introuvable dans D:\Godot" }

$Gh = (Get-Command gh -ErrorAction SilentlyContinue).Source
if (-not $Gh) { $Gh = "$env:ProgramFiles\GitHub CLI\gh.exe" }
if (-not (Test-Path $Gh)) { Echec "GitHub CLI introuvable. winget install GitHub.cli" }

# --- 1. Modules WASM ------------------------------------------------------

Etape "Compilation des modules WASM"
Push-Location $Racine
$code = Executer "cargo" @("build", "--release", "--target", "wasm32-unknown-unknown")
if ($code -ne 0) { Pop-Location; Echec "compilation des modules echouee" }

# La liste des 2048 mots vient de la crate bip39 elle-meme : c'est ce qui
# garantit qu'elle est identique a celle que identity.wasm valide.
$code = Executer "cargo" @(
    "test", "--release", "-p", "identity", "--", "--ignored", "extraire_liste_des_mots"
)
Pop-Location
if ($code -ne 0) { Echec "extraction de la liste des mots echouee" }

$Sortie = Join-Path $Racine "target\wasm32-unknown-unknown\release"
foreach ($module in $Modules.Keys) {
    $source = Join-Path $Sortie "$module.wasm"
    if (-not (Test-Path $source)) { Echec "$module.wasm non produit" }
    $cible = Join-Path $Racine $Modules[$module]
    New-Item -ItemType Directory -Force (Split-Path $cible) | Out-Null
    Copy-Item $source $cible -Force
    Write-Host ("  {0,-12} -> {1}" -f $module, $Modules[$module])
}
Copy-Item (Join-Path $Racine "Norms\identity\Rust\wordlist.txt") `
          (Join-Path $Projet "wordlist.txt") -Force

# --- 2. Export Godot ------------------------------------------------------

Etape "Export du client"
# On vide d'abord : sinon les fichiers d'une version precedente survivraient
# dans release/ et se retrouveraient dans le manifeste.
if (Test-Path $Release) { Remove-Item $Release -Recurse -Force }
New-Item -ItemType Directory -Force $Release | Out-Null

Executer $Godot @("--headless", "--path", $Projet, "--export-release", "Windows Desktop") | Out-Null
if (-not (Test-Path (Join-Path $Release "unirique.exe"))) { Echec "export echoue" }

Copy-Item (Join-Path $Projet "Games") (Join-Path $Release "Games") -Recurse -Force

# --- 3. Manifeste ---------------------------------------------------------

Etape "Empreintes et manifeste"
# Les noms d'attachement GitHub n'acceptent pas de barre oblique : on aplatit,
# et c'est le manifeste qui retablit le vrai chemin a l'installation.
$Depot = Join-Path $Release "_upload"
New-Item -ItemType Directory -Force $Depot | Out-Null

$fichiers = @()
$aEnvoyer = @()
foreach ($f in Get-ChildItem $Release -Recurse -File | Where-Object { $_.FullName -notlike "$Depot*" }) {
    $chemin = $f.FullName.Substring($Release.Length + 1).Replace("\", "/")
    $asset = $chemin.Replace("/", "_")
    $fichiers += [ordered]@{
        chemin = $chemin
        asset  = $asset
        sha256 = (Get-FileHash $f.FullName -Algorithm SHA256).Hash.ToLower()
        taille = $f.Length
    }
    if ($asset -eq $chemin) {
        $aEnvoyer += $f.FullName
    } else {
        $plat = Join-Path $Depot $asset
        Copy-Item $f.FullName $plat -Force
        $aEnvoyer += $plat
    }
    Write-Host ("  {0,10:N0} o  {1}" -f $f.Length, $chemin)
}

$manifeste = Join-Path $Release "manifest.json"
$json = [ordered]@{ version = $Version; fichiers = $fichiers } | ConvertTo-Json -Depth 4
# WriteAllText et non Set-Content : ce dernier ajoute une marque d'ordre des
# octets en tete, sur laquelle un analyseur JSON strict echouerait — et le
# lanceur ne lit rien d'autre que ce fichier.
[System.IO.File]::WriteAllText($manifeste, $json)
$aEnvoyer += $manifeste

# --- 4. Release GitHub ----------------------------------------------------

$etiquette = "v$Version"
if ($Essai) {
    Remove-Item $Depot -Recurse -Force
    Write-Host "`n=== Essai : rien n'a ete envoye" -ForegroundColor Yellow
    Write-Host "  $($aEnvoyer.Count) fichiers prets pour $etiquette"
    Write-Host "  manifeste : $manifeste"
    exit 0
}

Etape "Publication de la version $Version"
if ((Executer $Gh @("release", "view", $etiquette)) -eq 0) {
    Echec "la version $etiquette existe deja"
}

$arguments = @("release", "create", $etiquette) + $aEnvoyer + @(
    "--title", "Unirique $Version",
    "--notes", "Version $Version. Le lanceur telecharge automatiquement ce qui a change."
)
if ((Executer $Gh $arguments) -ne 0) { Echec "publication refusee" }

Remove-Item $Depot -Recurse -Force
Write-Host "`n=== Publie : $etiquette ($($fichiers.Count) fichiers)" -ForegroundColor Green
