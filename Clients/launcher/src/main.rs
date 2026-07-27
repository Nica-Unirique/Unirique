//! Lanceur d'Unirique : met a jour l'installation, puis demarre le client.
//!
//! Il ne telecharge que ce qui a change. Le manifeste publie avec chaque version
//! donne l'empreinte SHA256 de chaque fichier ; on compare a ce qu'on a sur le
//! disque, et on ne va chercher que la difference. Corriger un bug represente
//! ainsi 0,4 Mo — le .pck — au lieu des 115 Mo de l'installation complete.
//!
//! Il ne se met JAMAIS a jour lui-meme : il est en cours d'execution quand il
//! telechargerait son remplacant. D'ou sa simplicite — verifier, telecharger,
//! lancer, rien d'autre.

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::Command;

const DEPOT: &str = "Nica-Unirique/Unirique";
const MANIFESTE: &str = "manifest.json";
const CLIENT: &str = "unirique.exe";
// GitHub refuse les requetes sans identification de l'appelant.
const AGENT: &str = "unirique-launcher";

/// Un fichier de l'installation. `chemin` est son emplacement reel ; `asset` son
/// nom cote GitHub, aplati parce que les attachements n'acceptent pas de barre
/// oblique.
#[derive(Deserialize, Serialize, Clone)]
struct Fichier {
    chemin: String,
    asset: String,
    sha256: String,
    taille: u64,
}

#[derive(Deserialize, Serialize)]
struct Manifeste {
    version: String,
    fichiers: Vec<Fichier>,
}

#[derive(Deserialize)]
struct Release {
    tag_name: String,
    assets: Vec<Asset>,
}

#[derive(Deserialize)]
struct Asset {
    name: String,
    browser_download_url: String,
}

fn main() {
    let racine = dossier_du_programme();

    let resultat = mettre_a_jour(&racine);
    if resultat.is_err() {
        // Pas de reseau, GitHub muet, quota depasse : on joue avec ce qu'on a.
        // Refuser de lancer pour un echec de mise a jour serait pire que la
        // version un peu ancienne qu'on possede deja.
        println!("Mise a jour impossible : {}", resultat.unwrap_err());
    }
    lancer_client(&racine);
}

/// --- Mise a jour ---

fn mettre_a_jour(racine: &Path) -> Result<(), String> {
    println!("Recherche de mises a jour...");
    let release = derniere_release()?;
    let nouveau = manifeste_de(&release)?;

    let ancien = lire_manifeste_local(racine);
    let installe = if ancien.is_some() {
        ancien.unwrap().version
    } else {
        String::from("(aucune)")
    };
    println!("Version installee : {} / disponible : {}", installe, nouveau.version);

    let mut recus = 0;
    for fichier in &nouveau.fichiers {
        if a_jour(racine, fichier) {
            continue;
        }
        let url = url_de(&release, &fichier.asset)?;
        println!("  {} ({} o)", fichier.chemin, fichier.taille);
        telecharger(&url, &racine.join(&fichier.chemin))?;
        recus += 1;
    }

    supprimer_disparus(racine, &nouveau);
    ecrire_manifeste(racine, &nouveau)?;

    if recus == 0 {
        println!("Deja a jour.");
    } else {
        println!("{} fichier(s) mis a jour.", recus);
    }
    Ok(())
}

/// Un fichier est a jour si son empreinte correspond. On ne se fie pas a la
/// taille seule : deux versions d'un .pck peuvent peser pareil.
fn a_jour(racine: &Path, fichier: &Fichier) -> bool {
    let empreinte = empreinte_de(&racine.join(&fichier.chemin));
    if empreinte.is_none() {
        return false;
    }
    empreinte.unwrap() == fichier.sha256
}

/// Ce qui etait dans l'ancien manifeste et n'est plus dans le nouveau. On se
/// limite a ce qu'on a soi-meme installe : effacer tout ce qui n'est pas au
/// manifeste detruirait les fichiers de l'utilisateur.
fn supprimer_disparus(racine: &Path, nouveau: &Manifeste) {
    let ancien = lire_manifeste_local(racine);
    if ancien.is_none() {
        return;
    }
    for fichier in ancien.unwrap().fichiers {
        let garde = nouveau.fichiers.iter().any(|f| f.chemin == fichier.chemin);
        if garde {
            continue;
        }
        println!("  retire : {}", fichier.chemin);
        let _ = fs::remove_file(racine.join(&fichier.chemin));
    }
}

/// --- GitHub ---

fn derniere_release() -> Result<Release, String> {
    let url = format!("https://api.github.com/repos/{}/releases/latest", DEPOT);
    let reponse = ureq::get(&url)
        .set("User-Agent", AGENT)
        .call()
        .map_err(|e| format!("{}", e))?;
    reponse
        .into_json::<Release>()
        .map_err(|e| format!("reponse illisible : {}", e))
}

fn manifeste_de(release: &Release) -> Result<Manifeste, String> {
    let url = url_de(release, MANIFESTE)?;
    let texte = ureq::get(&url)
        .set("User-Agent", AGENT)
        .call()
        .map_err(|e| format!("{}", e))?
        .into_string()
        .map_err(|e| format!("{}", e))?;
    serde_json::from_str::<Manifeste>(&texte)
        .map_err(|e| format!("manifeste illisible : {}", e))
}

fn url_de(release: &Release, nom: &str) -> Result<String, String> {
    for asset in &release.assets {
        if asset.name == nom {
            return Ok(asset.browser_download_url.clone());
        }
    }
    Err(format!("{} absent de la version {}", nom, release.tag_name))
}

/// Ecrit d'abord un fichier temporaire, puis le renomme. Une coupure en cours
/// de telechargement laisserait sinon un fichier tronque que l'empreinte
/// rejetterait, certes — mais qui aurait ecrase une version fonctionnelle.
fn telecharger(url: &str, destination: &Path) -> Result<(), String> {
    let parent = destination.parent();
    if parent.is_some() {
        fs::create_dir_all(parent.unwrap()).map_err(|e| format!("{}", e))?;
    }

    let reponse = ureq::get(url)
        .set("User-Agent", AGENT)
        .call()
        .map_err(|e| format!("{}", e))?;

    let mut octets: Vec<u8> = Vec::new();
    reponse
        .into_reader()
        .read_to_end(&mut octets)
        .map_err(|e| format!("{}", e))?;

    let temporaire = destination.with_extension("telechargement");
    fs::write(&temporaire, &octets).map_err(|e| format!("{}", e))?;
    fs::rename(&temporaire, destination).map_err(|e| format!("{}", e))
}

/// --- Fichiers locaux ---

fn empreinte_de(chemin: &Path) -> Option<String> {
    let contenu = fs::read(chemin);
    if contenu.is_err() {
        return None;
    }
    let mut hacheur = Sha256::new();
    hacheur.update(contenu.unwrap());
    Some(format!("{:x}", hacheur.finalize()))
}

fn lire_manifeste_local(racine: &Path) -> Option<Manifeste> {
    let texte = fs::read_to_string(racine.join(MANIFESTE));
    if texte.is_err() {
        return None;
    }
    let manifeste = serde_json::from_str::<Manifeste>(&texte.unwrap());
    if manifeste.is_err() {
        return None;
    }
    Some(manifeste.unwrap())
}

fn ecrire_manifeste(racine: &Path, manifeste: &Manifeste) -> Result<(), String> {
    let texte = serde_json::to_string_pretty(manifeste).map_err(|e| format!("{}", e))?;
    fs::write(racine.join(MANIFESTE), texte).map_err(|e| format!("{}", e))
}

/// Le dossier du lanceur : c'est la qu'on installe. Il n'y a donc rien a
/// configurer — deplacer le lanceur deplace l'installation.
fn dossier_du_programme() -> PathBuf {
    let chemin = std::env::current_exe();
    if chemin.is_err() {
        return PathBuf::from(".");
    }
    let chemin = chemin.unwrap();
    let parent = chemin.parent();
    if parent.is_none() {
        return PathBuf::from(".");
    }
    parent.unwrap().to_path_buf()
}

/// --- Lancement ---

fn lancer_client(racine: &Path) {
    let client = racine.join(CLIENT);
    if !client.exists() {
        println!("\n{} introuvable : la premiere mise a jour n'a pas abouti.", CLIENT);
        attendre();
        return;
    }
    println!("Lancement...");
    // On ne rend pas la main : le client suit son propre cycle de vie, et le
    // lanceur n'a plus rien a faire.
    let lance = Command::new(&client).current_dir(racine).spawn();
    if lance.is_err() {
        println!("Lancement impossible : {}", lance.unwrap_err());
        attendre();
    }
}

fn attendre() {
    println!("Appuyez sur Entree pour fermer.");
    let mut ligne = String::new();
    let _ = std::io::stdin().read_line(&mut ligne);
}
