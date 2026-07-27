//! Journal du serveur : une porte d'entrée `log(type, position, message)` (console + fichier
//! de session `logs/<date>.csv`) et un middleware qui trace chaque requête / réponse.
//! Binaire unique -> le chemin du fichier tient dans un simple LazyLock (pas d'env comme le client).

use std::io::Write;
use std::sync::LazyLock;
use std::time::{SystemTime, UNIX_EPOCH};

use axum::body::{Body, to_bytes};
use axum::extract::Request;
use axum::middleware::Next;
use axum::response::Response;

// --- Types de log (const &str, comme le client) ---
pub const LOG_ERROR: &str = "ERROR";
pub const LOG_WARNING: &str = "WARNING";
pub const LOG_INFO: &str = "INFO";

// Fichier de session, calcule UNE fois au 1er log (= au demarrage du serveur).
static CHEMIN_LOG: LazyLock<String> = LazyLock::new(|| {
    let d = maintenant();
    format!("./logs/{:04}-{:02}-{:02}_{:02}-{:02}-{:02}.csv", d.annee, d.mois, d.jour, d.heure, d.minute, d.seconde)
});

// =====================================================================
// Niveau 1 : la fonction que le serveur appelle.
// =====================================================================
pub fn log(type_log: &str, position: &str, message: &str) {
    let date = date_texte();
    println!("[{}]\t[{}]\t({})\t{}", date, type_log, position, message);
    ecrire_ligne(&date, type_log, position, message);
}

// Middleware : 1 log pour la requete entrante, 1 pour la reponse (corps bufferises + remis).
pub async fn journal_requete(req: Request, next: Next) -> Response {
    let methode = req.method().clone();
    let uri = req.uri().clone();

    // Requete : token (en-tete Authorization) + corps, bufferise puis remis a l'identique.
    // On n'ajoute un segment "| ..." que s'il a du contenu (pas de "|" vide qui traine).
    let (parties, corps) = req.into_parts();
    let auth = parties.headers.get("authorization").and_then(|v| v.to_str().ok()).unwrap_or("");
    let octets = to_bytes(corps, usize::MAX).await.unwrap_or_default();
    let corps_txt = String::from_utf8_lossy(&octets);
    let mut ligne = format!("{} {}", methode, uri);
    if !auth.is_empty() {
        ligne.push_str(&format!(" | auth: {}", auth));
    }
    if !corps_txt.is_empty() {
        ligne.push_str(&format!(" | {}", corps_txt));
    }
    log(LOG_INFO, "requete", &ligne);
    let req = Request::from_parts(parties, Body::from(octets));

    let reponse = next.run(req).await;

    // Reponse : statut (+ corps s'il y en a), bufferise puis remis.
    let statut = reponse.status();
    let type_log = if statut.is_success() { LOG_INFO } else { LOG_WARNING };
    let (parties_r, corps_r) = reponse.into_parts();
    let octets_r = to_bytes(corps_r, usize::MAX).await.unwrap_or_default();
    let corps_r_txt = String::from_utf8_lossy(&octets_r);
    let mut ligne_r = format!("{} {} -> {}", methode, uri, statut);
    if !corps_r_txt.is_empty() {
        ligne_r.push_str(&format!(" | {}", corps_r_txt));
    }
    log(type_log, "reponse", &ligne_r);
    Response::from_parts(parties_r, Body::from(octets_r))
}

// =====================================================================
// Niveau 2 : ecriture fichier + horodatage.
// =====================================================================

// Ecrit une ligne CSV. Le message est entre guillemets car il contient des virgules
// (les corps JSON) ; les guillemets internes sont doubles (regle CSV).
fn ecrire_ligne(date: &str, type_log: &str, position: &str, message: &str) {
    let _ = std::fs::create_dir_all("./logs");
    let ouverture = std::fs::OpenOptions::new().create(true).append(true).open(&*CHEMIN_LOG);
    if ouverture.is_err() {
        return;
    }
    let msg = message.replace('"', "\"\"");
    let _ = writeln!(ouverture.unwrap(), "{},{},{},\"{}\"", date, type_log, position, msg);
}

struct DateHeure {
    annee: u16,
    mois: u16,
    jour: u16,
    heure: u16,
    minute: u16,
    seconde: u16,
}

// "AAAA/MM/JJ HH:MM:SS" (UTC).
fn date_texte() -> String {
    let d = maintenant();
    format!("{:04}/{:02}/{:02} {:02}:{:02}:{:02}", d.annee, d.mois, d.jour, d.heure, d.minute, d.seconde)
}

// Instant courant decompose (UTC), conversion manuelle depuis le timestamp Unix (algo Hinnant).
fn maintenant() -> DateHeure {
    let dur = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default();
    let total_secondes = dur.as_secs();
    let jours = (total_secondes / 86400) as i64;
    let reste = total_secondes % 86400;
    let heure = (reste / 3600) as u16;
    let minute = ((reste % 3600) / 60) as u16;
    let seconde = (reste % 60) as u16;

    let z = jours + 719468;
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let annee_civ = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let jour = (doy - (153 * mp + 2) / 5 + 1) as u16;
    let mois = if mp < 10 { (mp + 3) as u16 } else { (mp - 9) as u16 };
    let annee = if mois <= 2 { (annee_civ + 1) as u16 } else { annee_civ as u16 };
    DateHeure { annee, mois, jour, heure, minute, seconde }
}
