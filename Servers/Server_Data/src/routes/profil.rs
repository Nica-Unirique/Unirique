//! Profil : /me, mise a jour, suppression, recherche, profil public d'un autre.

use axum::extract::{Path, Query, State};
use axum::http::HeaderMap;
use axum::Json;
use serde::Deserialize;
use serde_json::{json, Value};
use crate::db::Compte;
use crate::error::ApiError;
use crate::routes::{aide, amis, presence};
use crate::state::AppState;
use crate::crypto;

// Mon profil complet (prive).
pub async fn me(State(state): State<AppState>, headers: HeaderMap) -> Result<Json<Value>, ApiError> {
    let c = aide::compte_authentifie(&state, &headers).await?;
    Ok(Json(json!({
        "userid": c.userid,
        "pseudo": c.pseudo,
        "email": c.email,
        "bio": c.bio,
        "avatar_url": c.avatar_url,
        "partage_statut": c.partage_statut,
        "partage_serveur": c.partage_serveur,
        "date_creation": c.date_creation
    })))
}

#[derive(Deserialize)]
pub struct UpdateReq {
    pub pseudo: Option<String>,
    pub bio: Option<String>,
    pub avatar_url: Option<String>,
    pub email: Option<String>,
    pub partage_statut: Option<bool>,
    pub partage_serveur: Option<bool>,
}

// Met a jour les champs fournis (chacun optionnel).
pub async fn update(State(state): State<AppState>, headers: HeaderMap, Json(req): Json<UpdateReq>) -> Result<Json<Value>, ApiError> {
    let c = aide::compte_authentifie(&state, &headers).await?;

    if req.pseudo.is_some() {
        let p = req.pseudo.unwrap();
        let pmin = state.config.entier("profil.pseudo_min") as usize;
        let pmax = state.config.entier("profil.pseudo_max") as usize;
        let l = p.chars().count();
        if l < pmin || l > pmax {
            return Err(ApiError::bad("pseudo : longueur invalide"));
        }
        let r = sqlx::query("UPDATE comptes SET pseudo = ? WHERE userid = ?")
            .bind(&p).bind(&c.userid).execute(&state.db).await;
        if r.is_err() {
            return Err(ApiError::conflit("pseudo deja pris"));
        }
    }
    if req.bio.is_some() {
        let b = req.bio.unwrap();
        let bmax = state.config.entier("profil.bio_max") as usize;
        if b.chars().count() > bmax {
            return Err(ApiError::bad("bio trop longue"));
        }
        sqlx::query("UPDATE comptes SET bio = ? WHERE userid = ?")
            .bind(&b).bind(&c.userid).execute(&state.db).await?;
    }
    if req.avatar_url.is_some() {
        sqlx::query("UPDATE comptes SET avatar_url = ? WHERE userid = ?")
            .bind(req.avatar_url.unwrap()).bind(&c.userid).execute(&state.db).await?;
    }
    if req.email.is_some() {
        let r = sqlx::query("UPDATE comptes SET email = ? WHERE userid = ?")
            .bind(req.email.unwrap()).bind(&c.userid).execute(&state.db).await;
        if r.is_err() {
            return Err(ApiError::conflit("email deja utilise"));
        }
    }
    if req.partage_statut.is_some() {
        sqlx::query("UPDATE comptes SET partage_statut = ? WHERE userid = ?")
            .bind(req.partage_statut.unwrap()).bind(&c.userid).execute(&state.db).await?;
    }
    if req.partage_serveur.is_some() {
        sqlx::query("UPDATE comptes SET partage_serveur = ? WHERE userid = ?")
            .bind(req.partage_serveur.unwrap()).bind(&c.userid).execute(&state.db).await?;
    }
    Ok(Json(json!({ "ok": true })))
}

#[derive(Deserialize)]
pub struct DeleteReq {
    pub signature: String, // signature de "delete:<userid>" avec la cle privee
}

// Supprime le compte du serveur (l'identite decentralisee, elle, survit).
pub async fn delete(State(state): State<AppState>, headers: HeaderMap, Json(req): Json<DeleteReq>) -> Result<Json<Value>, ApiError> {
    let c = aide::compte_authentifie(&state, &headers).await?;
    let message = format!("delete:{}", c.userid);
    if !crypto::verifier_signature(&c.cle_publique, message.as_bytes(), &req.signature) {
        return Err(ApiError::non_autorise("signature de confirmation invalide"));
    }
    sqlx::query("DELETE FROM comptes WHERE userid = ?").bind(&c.userid).execute(&state.db).await?;
    sqlx::query("DELETE FROM amities WHERE demandeur = ? OR destinataire = ?")
        .bind(&c.userid).bind(&c.userid).execute(&state.db).await?;
    sqlx::query("DELETE FROM blocages WHERE bloqueur = ? OR bloque = ?")
        .bind(&c.userid).bind(&c.userid).execute(&state.db).await?;
    Ok(Json(json!({ "ok": true })))
}

#[derive(Deserialize)]
pub struct SearchQuery {
    pub q: String,
}

// Recherche par pseudo (reservee aux connectes).
pub async fn search(State(state): State<AppState>, headers: HeaderMap, Query(q): Query<SearchQuery>) -> Result<Json<Value>, ApiError> {
    aide::compte_authentifie(&state, &headers).await?;
    let motif = format!("%{}%", q.q);
    let lignes = sqlx::query_as::<_, (String, String, String)>(
        "SELECT userid, pseudo, avatar_url FROM comptes WHERE pseudo LIKE ? LIMIT 50"
    ).bind(&motif).fetch_all(&state.db).await?;

    let mut resultats = Vec::new();
    for l in lignes {
        resultats.push(json!({ "userid": l.0, "pseudo": l.1, "avatar_url": l.2 }));
    }
    Ok(Json(json!({ "resultats": resultats })))
}

// Profil PUBLIC d'un autre. Token optionnel : si present + amis, ajoute le statut en ligne.
pub async fn public(State(state): State<AppState>, headers: HeaderMap, Path(userid): Path<String>) -> Result<Json<Value>, ApiError> {
    let cible = sqlx::query_as::<_, Compte>("SELECT * FROM comptes WHERE userid = ?")
        .bind(&userid).fetch_optional(&state.db).await?;
    if cible.is_none() {
        return Err(ApiError::introuvable("utilisateur introuvable"));
    }
    let cible = cible.unwrap();

    let mut sortie = json!({
        "userid": cible.userid,
        "pseudo": cible.pseudo,
        "bio": cible.bio,
        "avatar_url": cible.avatar_url
    });

    // Avec token valide + si amis : statut en ligne (si la cible le partage).
    let demandeur = aide::compte_authentifie(&state, &headers).await;
    if demandeur.is_ok() {
        let moi = demandeur.unwrap();
        let amis_ok = amis::sont_amis(&state, &moi.userid, &cible.userid).await?;
        if amis_ok && cible.partage_statut {
            sortie["en_ligne"] = json!(presence::est_en_ligne(&state, &cible.userid));
        }
    }
    Ok(Json(sortie))
}
