//! Erreur d'API -> reponse HTTP JSON { "erreur": "..." }.

use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde_json::json;
use crate::journal::{log, LOG_ERROR};

#[derive(Debug)]
pub struct ApiError {
    pub status: StatusCode,
    pub message: String,
}

impl ApiError {
    pub fn new(status: StatusCode, message: &str) -> ApiError {
        ApiError { status, message: message.to_string() }
    }
    pub fn bad(message: &str) -> ApiError {
        ApiError::new(StatusCode::BAD_REQUEST, message)
    }
    pub fn non_autorise(message: &str) -> ApiError {
        ApiError::new(StatusCode::UNAUTHORIZED, message)
    }
    pub fn interdit(message: &str) -> ApiError {
        ApiError::new(StatusCode::FORBIDDEN, message)
    }
    pub fn introuvable(message: &str) -> ApiError {
        ApiError::new(StatusCode::NOT_FOUND, message)
    }
    pub fn conflit(message: &str) -> ApiError {
        ApiError::new(StatusCode::CONFLICT, message)
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (self.status, Json(json!({ "erreur": self.message }))).into_response()
    }
}

// Toute erreur SQL devient une 500 generique (on ne fuit pas le detail au client).
impl From<sqlx::Error> for ApiError {
    fn from(e: sqlx::Error) -> ApiError {
        log(LOG_ERROR, "db", &format!("erreur : {}", e));
        ApiError::new(StatusCode::INTERNAL_SERVER_ERROR, "erreur interne")
    }
}
