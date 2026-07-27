//! Annuaire des serveurs jouables (RAM, temporaire) : register / heartbeat / liste.

use axum::extract::State;
use axum::http::HeaderMap;
use axum::Json;
use serde::Deserialize;
use serde_json::{json, Value};
use crate::db::maintenant;
use crate::error::ApiError;
use crate::routes::{aide, amis};
use crate::state::{AppState, ServeurVivant};
use crate::crypto;

#[derive(Deserialize)]
pub struct RegisterReq {
    pub nom: String,
    // Par ordre de preference. Voir ServeurVivant::adresses.
    pub adresses: Vec<String>,
    pub jeu: String,
    pub visibilite: String,
}

const VISIBILITES: [&str; 5] = ["nobody", "friends", "friends_plus", "invite", "invite_plus"];

// Un serveur jouable se declare (authentifie par le token de son proprietaire).
pub async fn register(State(state): State<AppState>, headers: HeaderMap, Json(req): Json<RegisterReq>) -> Result<Json<Value>, ApiError> {
    let moi = aide::compte_authentifie(&state, &headers).await?;
    if !VISIBILITES.contains(&req.visibilite.as_str()) {
        return Err(ApiError::bad("visibilite inconnue"));
    }
    // Un serveur sans adresse ne serait jamais joignable : autant le dire ici
    // plutot que de le laisser figurer dans l'annuaire sans servir a rien.
    if req.adresses.is_empty() {
        return Err(ApiError::bad("aucune adresse fournie"));
    }
    let serveur_id = crypto::id_aleatoire(16);
    let sv = ServeurVivant {
        proprietaire: moi.userid,
        nom: req.nom,
        adresses: req.adresses,
        jeu: req.jeu,
        visibilite: req.visibilite,
        nb_joueurs: 0,
        last_seen: maintenant(),
    };
    {
        let mut serveurs = state.ram.serveurs.lock().unwrap();
        serveurs.insert(serveur_id.clone(), sv);
    }
    Ok(Json(json!({ "serveur_id": serveur_id })))
}

#[derive(Deserialize)]
pub struct HeartbeatReq {
    pub serveur_id: String,
    pub nb_joueurs: i64,
}

// Le serveur prouve qu'il est vivant + met a jour son nombre de joueurs.
pub async fn heartbeat(State(state): State<AppState>, headers: HeaderMap, Json(req): Json<HeartbeatReq>) -> Result<Json<Value>, ApiError> {
    let moi = aide::compte_authentifie(&state, &headers).await?;
    let mut serveurs = state.ram.serveurs.lock().unwrap();
    let sv = serveurs.get_mut(&req.serveur_id);
    if sv.is_none() {
        return Err(ApiError::introuvable("serveur inconnu (re-register)"));
    }
    let sv = sv.unwrap();
    if sv.proprietaire != moi.userid {
        return Err(ApiError::interdit("pas proprietaire de ce serveur"));
    }
    sv.nb_joueurs = req.nb_joueurs;
    sv.last_seen = maintenant();
    Ok(Json(json!({ "ok": true })))
}

// Liste des serveurs vivants (vus recemment). Public, pas de token.
pub async fn liste(State(state): State<AppState>, headers: HeaderMap) -> Result<Json<Value>, ApiError> {
    let moi = aide::compte_authentifie(&state, &headers).await?;
    let limite = maintenant()
        - state.config.entier("serveurs_jouables.heartbeat_seuil_secondes");

    // Copie d'abord : le verrou ne survit pas aux await de peut_rejoindre.
    let vivants;
    {
        let serveurs = state.ram.serveurs.lock().unwrap();
        let mut copie = Vec::new();
        for entree in serveurs.iter() {
            if entree.1.last_seen >= limite {
                copie.push((entree.0.clone(), entree.1.clone()));
            }
        }
        vivants = copie;
    }

    let mut liste = Vec::new();
    for entree in vivants {
        let id = entree.0;
        let sv = entree.1;
        if !peut_rejoindre(&state, &moi.userid, &id).await? {
            continue;
        }
        liste.push(json!({
            "serveur_id": id,
            "nom": sv.nom,
            "adresses": sv.adresses,
            "jeu": sv.jeu,
            "nb_joueurs": sv.nb_joueurs
        }));
    }
    Ok(Json(json!({ "serveurs": liste })))
}

pub async fn peut_rejoindre(
    state: &AppState, demandeur: &str, serveur_id: &str,
) -> Result<bool, ApiError> {
    // On copie avant tout await : un MutexGuard ne traverse pas un point d'attente.
    let sv;
    {
        let serveurs = state.ram.serveurs.lock().unwrap();
        let trouve = serveurs.get(serveur_id);
        if trouve.is_none() {
            return Ok(false);
        }
        sv = trouve.unwrap().clone();
    }

    // L'hote entre toujours chez lui, quelle que soit sa politique.
    if sv.proprietaire == demandeur {
        return Ok(true);
    }

    if sv.visibilite == "friends" {
        return amis::sont_amis(state, &sv.proprietaire, demandeur).await;
    }
    if sv.visibilite == "friends_plus" {
        return ami_d_un_present(state, demandeur, serveur_id).await;
    }
    // "nobody", "invite", "invite_plus" : le sous-systeme d'invitations n'existe
    // pas encore. On refuse — un serveur ferme par erreur vaut mieux qu'un
    // serveur ouvert par defaut.
    Ok(false)
}

// `friends_plus` : les amis de N'IMPORTE QUEL joueur present a l'instant. La
// liste des occupants se lit dans la presence — aucune structure de plus.
async fn ami_d_un_present(
    state: &AppState, demandeur: &str, serveur_id: &str,
) -> Result<bool, ApiError> {
    for occupant in occupants(state, serveur_id) {
        if occupant == demandeur {
            return Ok(true); // deja dedans
        }
        if amis::sont_amis(state, &occupant, demandeur).await? {
            return Ok(true);
        }
    }
    Ok(false)
}

fn occupants(state: &AppState, serveur_id: &str) -> Vec<String> {
    let limite = maintenant() - state.config.entier("presence.en_ligne_seuil_secondes");
    let presence = state.ram.presence.lock().unwrap();
    let mut trouves = Vec::new();
    for entree in presence.iter() {
        let vu = entree.1;
        if vu.0 < limite {
            continue;
        }
        let sur = vu.1.clone();
        if sur.is_none() {
            continue;
        }
        if sur.unwrap() == serveur_id {
            trouves.push(entree.0.clone());
        }
    }
    trouves
}