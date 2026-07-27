//! Identite : register (declaration decentralisee), challenge/login (defi-signature), logout.

use axum::extract::State;
use axum::http::{HeaderMap, StatusCode};
use axum::Json;
use serde::Deserialize;
use serde_json::{json, Value};
use crate::db::{self, Compte};
use crate::error::ApiError;
use crate::routes::aide;
use crate::state::AppState;
use crate::crypto;

#[derive(Deserialize)]
pub struct RegisterReq {
    pub cle_publique: String,
    pub email: Option<String>, // optionnel ; vide par defaut a la creation
}

// Declare un compte (partie centralisee) : cle publique -> userid + pseudo ALEATOIRES.
// Le pseudo est choisi par le serveur ; l'utilisateur le changera ensuite via /me/update.
pub async fn register(State(state): State<AppState>, Json(req): Json<RegisterReq>) -> Result<Json<Value>, ApiError> {
    // Cle publique : hex de 32 octets.
    let cle = hex::decode(&req.cle_publique);
    if cle.is_err() || cle.unwrap().len() != 32 {
        return Err(ApiError::bad("cle_publique invalide (hex de 32 octets attendu)"));
    }

    // Longueur du userid : minimale, doublee automatiquement selon le nombre de comptes.
    let min = state.config.entier("identite.userid_longueur_min") as usize;
    let total = db::nombre_comptes(&state.db).await;
    let longueur = crypto::longueur_userid(min, total);
    let maintenant = db::maintenant();

    // Insertion ; on regenere userid + pseudo en cas de (tres improbable) collision.
    let mut essais = 0;
    while essais < 10 {
        let userid = crypto::id_aleatoire(longueur);
        let pseudo = format!("user{}", crypto::id_aleatoire(6)); // pseudo par defaut
        let res = sqlx::query(
            "INSERT INTO comptes (userid, cle_publique, pseudo, email, date_creation) VALUES (?, ?, ?, ?, ?)"
        )
        .bind(&userid)
        .bind(&req.cle_publique)
        .bind(&pseudo)
        .bind(&req.email)
        .bind(maintenant)
        .execute(&state.db)
        .await;

        if res.is_ok() {
            return Ok(Json(json!({ "userid": userid, "pseudo": pseudo })));
        }
        let msg = res.err().unwrap().to_string();
        if msg.contains("comptes.userid") || msg.contains("pseudo") {
            essais += 1;
            continue; // collision userid ou pseudo : on retente (nouveaux tirages)
        }
        if msg.contains("cle_publique") {
            return Err(ApiError::conflit("cette cle publique a deja un compte"));
        }
        if msg.contains("email") {
            return Err(ApiError::conflit("email deja utilise"));
        }
        return Err(ApiError::new(StatusCode::INTERNAL_SERVER_ERROR, "erreur interne"));
    }
    Err(ApiError::new(StatusCode::INTERNAL_SERVER_ERROR, "impossible de generer un compte unique"))
}

#[derive(Deserialize)]
pub struct ChallengeReq {
    pub cle_publique: String,
}

// Renvoie un defi (nonce) a signer, uniquement pour une cle deja enregistree.
pub async fn challenge(State(state): State<AppState>, Json(req): Json<ChallengeReq>) -> Result<Json<Value>, ApiError> {
    let existe = sqlx::query("SELECT 1 FROM comptes WHERE cle_publique = ?")
        .bind(&req.cle_publique)
        .fetch_optional(&state.db)
        .await?;
    if existe.is_none() {
        return Err(ApiError::introuvable("aucun compte pour cette cle publique"));
    }
    let nonce = crypto::hex_aleatoire(32);
    let duree = state.config.entier("identite.defi_duree_secondes");
    let expiration = db::maintenant() + duree;
    {
        let mut defis = state.ram.defis.lock().unwrap();
        defis.insert(req.cle_publique.clone(), (nonce.clone(), expiration));
    }
    Ok(Json(json!({ "defi": nonce })))
}

#[derive(Deserialize)]
pub struct LoginReq {
    pub cle_publique: String,
    pub signature: String,
}

// Verifie la signature du defi. Renvoie le token existant (si valide) sinon en cree un.
pub async fn login(State(state): State<AppState>, Json(req): Json<LoginReq>) -> Result<Json<Value>, ApiError> {
    // Recupere et consomme le defi.
    let defi;
    {
        let mut defis = state.ram.defis.lock().unwrap();
        let d = defis.remove(&req.cle_publique);
        if d.is_none() {
            return Err(ApiError::bad("aucun defi en cours (appelle /auth/challenge d'abord)"));
        }
        defi = d.unwrap();
    }
    let nonce_hex = defi.0;
    let expiration_defi = defi.1;
    if expiration_defi < db::maintenant() {
        return Err(ApiError::bad("defi expire"));
    }
    let message = hex::decode(&nonce_hex).unwrap();
    if !crypto::verifier_signature(&req.cle_publique, &message, &req.signature) {
        return Err(ApiError::non_autorise("signature invalide"));
    }

    let compte = sqlx::query_as::<_, Compte>("SELECT * FROM comptes WHERE cle_publique = ?")
        .bind(&req.cle_publique)
        .fetch_optional(&state.db)
        .await?;
    if compte.is_none() {
        return Err(ApiError::introuvable("compte introuvable"));
    }
    let compte = compte.unwrap();

    // Token existant encore valide -> on le renvoie.
    let maintenant = db::maintenant();
    let token_valide = compte.token.is_some() && compte.token_expiration.unwrap_or(0) > maintenant;
    if token_valide {
        return Ok(Json(json!({ "token": compte.token.unwrap(), "userid": compte.userid })));
    }

    // Sinon on en cree un.
    let duree_h = state.config.entier("token.token_duree_heures");
    let octets = state.config.entier("token.token_octets") as usize;
    let token = crypto::hex_aleatoire(octets);
    let expiration = maintenant + duree_h * 3600;
    sqlx::query("UPDATE comptes SET token = ?, token_expiration = ? WHERE userid = ?")
        .bind(&token)
        .bind(expiration)
        .bind(&compte.userid)
        .execute(&state.db)
        .await?;
    Ok(Json(json!({ "token": token, "userid": compte.userid })))
}

// Deconnecte : efface le token (donc TOUTES les plateformes d'un coup).
pub async fn logout(State(state): State<AppState>, headers: HeaderMap) -> Result<Json<Value>, ApiError> {
    let compte = aide::compte_authentifie(&state, &headers).await?;
    sqlx::query("UPDATE comptes SET token = NULL, token_expiration = NULL WHERE userid = ?")
        .bind(&compte.userid)
        .execute(&state.db)
        .await?;
    Ok(Json(json!({ "ok": true })))
}
