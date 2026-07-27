//! Amis : demande/acceptation, liste (avec presence), blocages.

use axum::extract::State;
use axum::http::HeaderMap;
use axum::Json;
use serde::Deserialize;
use serde_json::{json, Value};
use crate::db::maintenant;
use crate::error::ApiError;
use crate::routes::{aide, presence, serveurs};
use crate::state::AppState;

#[derive(Deserialize)]
pub struct CibleReq {
    pub userid: String,
}

// --- helpers ---

// Deux comptes sont-ils amis (amitie acceptee, peu importe le sens) ?
pub async fn sont_amis(state: &AppState, a: &str, b: &str) -> Result<bool, ApiError> {
    let row = sqlx::query(
        "SELECT 1 FROM amities WHERE etat = 'accepted' AND \
         ((demandeur = ? AND destinataire = ?) OR (demandeur = ? AND destinataire = ?))"
    ).bind(a).bind(b).bind(b).bind(a).fetch_optional(&state.db).await?;
    Ok(row.is_some())
}

async fn est_bloque(state: &AppState, bloqueur: &str, bloque: &str) -> Result<bool, ApiError> {
    let row = sqlx::query("SELECT 1 FROM blocages WHERE bloqueur = ? AND bloque = ?")
        .bind(bloqueur).bind(bloque).fetch_optional(&state.db).await?;
    Ok(row.is_some())
}

// Reglages de partage (statut, serveur) d'un compte.
async fn reglages_partage(state: &AppState, userid: &str) -> Result<(bool, bool), ApiError> {
    let r = sqlx::query_as::<_, (bool, bool)>("SELECT partage_statut, partage_serveur FROM comptes WHERE userid = ?")
        .bind(userid).fetch_optional(&state.db).await?;
    if r.is_none() {
        return Ok((false, false));
    }
    let r = r.unwrap();
    Ok((r.0, r.1))
}

// --- routes ---

// Envoyer une demande d'ami.
pub async fn demander(State(state): State<AppState>, headers: HeaderMap, Json(req): Json<CibleReq>) -> Result<Json<Value>, ApiError> {
    let moi = aide::compte_authentifie(&state, &headers).await?;
    let cible = req.userid;
    if cible == moi.userid {
        return Err(ApiError::bad("impossible de s'ajouter soi-meme"));
    }
    let existe = sqlx::query("SELECT 1 FROM comptes WHERE userid = ?")
        .bind(&cible).fetch_optional(&state.db).await?;
    if existe.is_none() {
        return Err(ApiError::introuvable("utilisateur introuvable"));
    }
    if est_bloque(&state, &cible, &moi.userid).await? || est_bloque(&state, &moi.userid, &cible).await? {
        return Err(ApiError::interdit("demande impossible (blocage)"));
    }
    let deja = sqlx::query(
        "SELECT 1 FROM amities WHERE (demandeur = ? AND destinataire = ?) OR (demandeur = ? AND destinataire = ?)"
    ).bind(&moi.userid).bind(&cible).bind(&cible).bind(&moi.userid).fetch_optional(&state.db).await?;
    if deja.is_some() {
        return Err(ApiError::conflit("relation deja existante"));
    }
    let plafond = state.config.entier("amis.max_demandes_en_attente");
    if plafond > 0 {
        let n = sqlx::query_as::<_, (i64,)>("SELECT COUNT(*) FROM amities WHERE demandeur = ? AND etat = 'pending'")
            .bind(&moi.userid).fetch_one(&state.db).await?;
        if n.0 >= plafond {
            return Err(ApiError::interdit("trop de demandes en attente"));
        }
    }
    sqlx::query("INSERT INTO amities (demandeur, destinataire, etat, date) VALUES (?, ?, 'pending', ?)")
        .bind(&moi.userid).bind(&cible).bind(maintenant()).execute(&state.db).await?;
    Ok(Json(json!({ "ok": true })))
}

// Accepter une demande recue (cible = celui qui m'a envoye la demande).
pub async fn accepter(State(state): State<AppState>, headers: HeaderMap, Json(req): Json<CibleReq>) -> Result<Json<Value>, ApiError> {
    let moi = aide::compte_authentifie(&state, &headers).await?;
    let res = sqlx::query("UPDATE amities SET etat = 'accepted' WHERE demandeur = ? AND destinataire = ? AND etat = 'pending'")
        .bind(&req.userid).bind(&moi.userid).execute(&state.db).await?;
    if res.rows_affected() == 0 {
        return Err(ApiError::introuvable("aucune demande a accepter"));
    }
    Ok(Json(json!({ "ok": true })))
}

// Refuser une demande recue.
pub async fn refuser(State(state): State<AppState>, headers: HeaderMap, Json(req): Json<CibleReq>) -> Result<Json<Value>, ApiError> {
    let moi = aide::compte_authentifie(&state, &headers).await?;
    let res = sqlx::query("DELETE FROM amities WHERE demandeur = ? AND destinataire = ? AND etat = 'pending'")
        .bind(&req.userid).bind(&moi.userid).execute(&state.db).await?;
    if res.rows_affected() == 0 {
        return Err(ApiError::introuvable("aucune demande a refuser"));
    }
    Ok(Json(json!({ "ok": true })))
}

// Annuler MA demande envoyee.
pub async fn annuler(State(state): State<AppState>, headers: HeaderMap, Json(req): Json<CibleReq>) -> Result<Json<Value>, ApiError> {
    let moi = aide::compte_authentifie(&state, &headers).await?;
    let res = sqlx::query("DELETE FROM amities WHERE demandeur = ? AND destinataire = ? AND etat = 'pending'")
        .bind(&moi.userid).bind(&req.userid).execute(&state.db).await?;
    if res.rows_affected() == 0 {
        return Err(ApiError::introuvable("aucune demande a annuler"));
    }
    Ok(Json(json!({ "ok": true })))
}

// Retirer une amitie acceptee (peu importe le sens).
pub async fn retirer(State(state): State<AppState>, headers: HeaderMap, Json(req): Json<CibleReq>) -> Result<Json<Value>, ApiError> {
    let moi = aide::compte_authentifie(&state, &headers).await?;
    let res = sqlx::query(
        "DELETE FROM amities WHERE etat = 'accepted' AND \
         ((demandeur = ? AND destinataire = ?) OR (demandeur = ? AND destinataire = ?))"
    ).bind(&moi.userid).bind(&req.userid).bind(&req.userid).bind(&moi.userid).execute(&state.db).await?;
    if res.rows_affected() == 0 {
        return Err(ApiError::introuvable("vous n'etes pas amis"));
    }
    Ok(Json(json!({ "ok": true })))
}

// Liste des amis acceptes, avec statut/serveur (selon les reglages de partage de chaque ami).
pub async fn liste(State(state): State<AppState>, headers: HeaderMap) -> Result<Json<Value>, ApiError> {
    let moi = aide::compte_authentifie(&state, &headers).await?;
    let lignes = sqlx::query_as::<_, (String,)>(
        "SELECT CASE WHEN demandeur = ? THEN destinataire ELSE demandeur END \
         FROM amities WHERE etat = 'accepted' AND (demandeur = ? OR destinataire = ?)"
    ).bind(&moi.userid).bind(&moi.userid).bind(&moi.userid).fetch_all(&state.db).await?;

    let mut amis = Vec::new();
    for l in lignes {
        let ami_id = l.0;
        let p = sqlx::query_as::<_, (String, String)>("SELECT pseudo, avatar_url FROM comptes WHERE userid = ?")
            .bind(&ami_id).fetch_optional(&state.db).await?;
        if p.is_none() {
            continue;
        }
        let p = p.unwrap();
        let partage = reglages_partage(&state, &ami_id).await?;
        let mut item = json!({ "userid": ami_id, "pseudo": p.0, "avatar_url": p.1 });

        let en_ligne = presence::est_en_ligne(&state, &ami_id);
        if partage.0 {
            item["en_ligne"] = json!(en_ligne);
        }
        if partage.1 && en_ligne {
            let serveur = presence::serveur_de(&state, &ami_id);
            if serveur.is_some() {
                let id = serveur.unwrap();
                if serveurs::peut_rejoindre(&state, &moi.userid, &id).await? {
                    item["serveur"] = json!(id);
                }
            }
        }
        amis.push(item);
    }
    Ok(Json(json!({ "amis": amis })))
}

// Demandes en attente : recues et envoyees.
pub async fn demandes(State(state): State<AppState>, headers: HeaderMap) -> Result<Json<Value>, ApiError> {
    let moi = aide::compte_authentifie(&state, &headers).await?;
    let recues = sqlx::query_as::<_, (String,)>("SELECT demandeur FROM amities WHERE destinataire = ? AND etat = 'pending'")
        .bind(&moi.userid).fetch_all(&state.db).await?;
    let envoyees = sqlx::query_as::<_, (String,)>("SELECT destinataire FROM amities WHERE demandeur = ? AND etat = 'pending'")
        .bind(&moi.userid).fetch_all(&state.db).await?;

    let liste_recues = avec_pseudos(&state, recues).await?;
    let liste_envoyees = avec_pseudos(&state, envoyees).await?;
    Ok(Json(json!({ "recues": liste_recues, "envoyees": liste_envoyees })))
}

// Transforme une liste de userids en objets { userid, pseudo } (pseudo vide si compte absent).
async fn avec_pseudos(state: &AppState, ids: Vec<(String,)>) -> Result<Vec<Value>, ApiError> {
    let mut out = Vec::new();
    for id in ids {
        let userid = id.0;
        let p = sqlx::query_as::<_, (String,)>("SELECT pseudo FROM comptes WHERE userid = ?")
            .bind(&userid).fetch_optional(&state.db).await?;
        let pseudo = if p.is_some() { p.unwrap().0 } else { String::new() };
        out.push(json!({ "userid": userid, "pseudo": pseudo }));
    }
    Ok(out)
}

// Bloquer un utilisateur (supprime aussi toute amitie/demande entre les deux).
pub async fn bloquer(State(state): State<AppState>, headers: HeaderMap, Json(req): Json<CibleReq>) -> Result<Json<Value>, ApiError> {
    let moi = aide::compte_authentifie(&state, &headers).await?;
    if req.userid == moi.userid {
        return Err(ApiError::bad("impossible de se bloquer soi-meme"));
    }
    sqlx::query("INSERT OR IGNORE INTO blocages (bloqueur, bloque, date) VALUES (?, ?, ?)")
        .bind(&moi.userid).bind(&req.userid).bind(maintenant()).execute(&state.db).await?;
    sqlx::query(
        "DELETE FROM amities WHERE (demandeur = ? AND destinataire = ?) OR (demandeur = ? AND destinataire = ?)"
    ).bind(&moi.userid).bind(&req.userid).bind(&req.userid).bind(&moi.userid).execute(&state.db).await?;
    Ok(Json(json!({ "ok": true })))
}

// Debloquer.
pub async fn debloquer(State(state): State<AppState>, headers: HeaderMap, Json(req): Json<CibleReq>) -> Result<Json<Value>, ApiError> {
    let moi = aide::compte_authentifie(&state, &headers).await?;
    sqlx::query("DELETE FROM blocages WHERE bloqueur = ? AND bloque = ?")
        .bind(&moi.userid).bind(&req.userid).execute(&state.db).await?;
    Ok(Json(json!({ "ok": true })))
}

pub async fn liste_blocages(State(state): State<AppState>, headers: HeaderMap) -> Result<Json<Value>, ApiError> {
    let moi = aide::compte_authentifie(&state, &headers).await?;
    let lignes = sqlx::query_as::<_, (String,)>("SELECT bloque FROM blocages WHERE bloqueur = ?")
        .bind(&moi.userid).fetch_all(&state.db).await?;
    Ok(Json(json!({ "bloques": avec_pseudos(&state, lignes).await? })))
}