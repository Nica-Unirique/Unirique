//! Routes utilitaires : /health (monitoring) et /version (compat clients).

use axum::extract::State;
use axum::Json;
use serde_json::{json, Value};
use crate::state::AppState;

pub async fn health() -> Json<Value> {
    Json(json!({ "ok": true }))
}

pub async fn version(State(state): State<AppState>) -> Json<Value> {
    Json(json!({ "version": state.config.texte("api.version") }))
}
