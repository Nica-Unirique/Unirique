//! Presence : heartbeat (je suis en ligne + ou je joue) + helpers de lecture (RAM).

use axum::extract::State;
use axum::http::HeaderMap;
use axum::Json;
use serde::Deserialize;
use serde_json::{json, Value};
use crate::db::maintenant;
use crate::error::ApiError;
use crate::routes::aide;
use crate::state::AppState;

#[derive(Deserialize)]
pub struct HeartbeatReq {
    pub serveur: Option<String>, // optionnel : le serveur ou je joue
}

// Le client ping regulierement : on horodate + on note le serveur courant.
pub async fn heartbeat(State(state): State<AppState>, headers: HeaderMap, Json(req): Json<HeartbeatReq>) -> Result<Json<Value>, ApiError> {
    let moi = aide::compte_authentifie(&state, &headers).await?;
    {
        let mut presence = state.ram.presence.lock().unwrap();
        presence.insert(moi.userid.clone(), (maintenant(), req.serveur));
    }
    Ok(Json(json!({ "ok": true })))
}

// Vrai si `userid` a ete vu il y a moins de en_ligne_seuil_secondes.
pub fn est_en_ligne(state: &AppState, userid: &str) -> bool {
    let seuil = state.config.entier("presence.en_ligne_seuil_secondes");
    let presence = state.ram.presence.lock().unwrap();
    let p = presence.get(userid);
    if p.is_none() {
        return false;
    }
    let last_seen = p.unwrap().0;
    last_seen >= maintenant() - seuil
}

// Le serveur courant de `userid` s'il est en ligne (None sinon).
pub fn serveur_de(state: &AppState, userid: &str) -> Option<String> {
    let seuil = state.config.entier("presence.en_ligne_seuil_secondes");
    let presence = state.ram.presence.lock().unwrap();
    let p = presence.get(userid);
    if p.is_none() {
        return None;
    }
    let p = p.unwrap();
    if p.0 < maintenant() - seuil {
        return None;
    }
    p.1.clone()
}
