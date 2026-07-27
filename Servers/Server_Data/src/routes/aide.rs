//! Helpers partages par les routes : extraction du token -> compte authentifie.

use axum::http::HeaderMap;
use crate::db::{maintenant, Compte};
use crate::error::ApiError;
use crate::state::AppState;

// Extrait le token du header "Authorization: Bearer <token>".
pub fn token_du_header(headers: &HeaderMap) -> Option<String> {
    let v = headers.get("authorization");
    if v.is_none() {
        return None;
    }
    let s = v.unwrap().to_str();
    if s.is_err() {
        return None;
    }
    let s = s.unwrap();
    let prefixe = "Bearer ";
    if !s.starts_with(prefixe) {
        return None;
    }
    Some(s[prefixe.len()..].to_string())
}

// Resout le compte authentifie a partir du token (verifie sa presence et son expiration).
pub async fn compte_authentifie(state: &AppState, headers: &HeaderMap) -> Result<Compte, ApiError> {
    let token = token_du_header(headers);
    if token.is_none() {
        return Err(ApiError::non_autorise("token manquant"));
    }
    let token = token.unwrap();

    let compte = sqlx::query_as::<_, Compte>("SELECT * FROM comptes WHERE token = ?")
        .bind(&token)
        .fetch_optional(&state.db)
        .await?;
    if compte.is_none() {
        return Err(ApiError::non_autorise("token invalide"));
    }
    let compte = compte.unwrap();

    let exp = compte.token_expiration.unwrap_or(0);
    if exp < maintenant() {
        return Err(ApiError::non_autorise("token expire"));
    }
    Ok(compte)
}
