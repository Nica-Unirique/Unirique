//! Serveur de donnees Unirique : identite decentralisee (Ed25519), profils, amis, presence,
//! annuaire des serveurs jouables. API HTTP/JSON (axum) + SQLite (sqlx). Config : config.csv.

mod config;
mod crypto;
mod error;
mod db;
mod state;
mod routes;
mod journal;

use axum::routing::{get, post};
use axum::Router;
use state::{AppState, Ram};
use std::sync::Arc;

#[tokio::main]
async fn main() {
    let config = config::Config::charger("config.csv");
    let pool = db::ouvrir(&config.texte("base_donnees.url")).await;

    let host = config.texte("serveur.host");
    let port = config.entier("serveur.port");

    let state = AppState {
        db: pool,
        config: Arc::new(config),
        ram: Arc::new(Ram::nouveau()),
    };

    let app = Router::new()
        // --- divers ---
        .route("/health", get(routes::divers::health))
        .route("/version", get(routes::divers::version))
        // --- identite ---
        .route("/auth/register", post(routes::auth::register))
        .route("/auth/challenge", post(routes::auth::challenge))
        .route("/auth/login", post(routes::auth::login))
        .route("/auth/logout", post(routes::auth::logout))
        // --- profil ---
        .route("/me", get(routes::profil::me))
        .route("/me/update", post(routes::profil::update))
        .route("/me/delete", post(routes::profil::delete))
        .route("/users/search", get(routes::profil::search))
        .route("/users/:userid", get(routes::profil::public))
        // --- amis ---
        .route("/friends", get(routes::amis::liste))
        .route("/friends/requests", get(routes::amis::demandes))
        .route("/friends/request", post(routes::amis::demander))
        .route("/friends/accept", post(routes::amis::accepter))
        .route("/friends/refuse", post(routes::amis::refuser))
        .route("/friends/cancel", post(routes::amis::annuler))
        .route("/friends/remove", post(routes::amis::retirer))
        .route("/users/block", post(routes::amis::bloquer))
        .route("/users/unblock", post(routes::amis::debloquer))
        .route("/users/blocked", get(routes::amis::liste_blocages))
        // --- presence ---
        .route("/presence/heartbeat", post(routes::presence::heartbeat))
        // --- serveurs jouables ---
        .route("/servers/register", post(routes::serveurs::register))
        .route("/servers/heartbeat", post(routes::serveurs::heartbeat))
        .route("/servers", get(routes::serveurs::liste))
        .with_state(state)
        // Trace chaque requete + reponse (console + logs/<date>.csv).
        .layer(axum::middleware::from_fn(journal::journal_requete));

    let adresse = format!("{}:{}", host, port);
    let listener = tokio::net::TcpListener::bind(&adresse)
        .await
        .expect("impossible d'ecouter sur cette adresse");
    journal::log(journal::LOG_INFO, "serveur", &format!("ecoute sur http://{}", adresse));
    axum::serve(listener, app).await.expect("serveur arrete");
}
