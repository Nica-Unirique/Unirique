//! Base de donnees : connexion SQLite, creation du schema, type Compte, horodatage.

use sqlx::sqlite::{SqliteConnectOptions, SqlitePool, SqlitePoolOptions};
use sqlx::FromRow;
use std::time::{SystemTime, UNIX_EPOCH};

// Horodatage courant en secondes Unix.
pub fn maintenant() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs() as i64
}

// Un compte, tel que stocke en base (cle_publique et email ne sortent JAMAIS en public).
#[derive(FromRow, Clone)]
pub struct Compte {
    pub userid: String,
    pub cle_publique: String,
    pub pseudo: String,
    pub email: Option<String>,
    pub bio: String,
    pub avatar_url: String,
    pub partage_statut: bool,
    pub partage_serveur: bool,
    pub token: Option<String>,
    pub token_expiration: Option<i64>,
    pub date_creation: i64,
}

// Ouvre (ou cree) la base et applique le schema.
pub async fn ouvrir(fichier: &str) -> SqlitePool {
    let options = SqliteConnectOptions::new()
        .filename(fichier)
        .create_if_missing(true);
    let pool = SqlitePoolOptions::new()
        .max_connections(5)
        .connect_with(options)
        .await
        .expect("connexion SQLite impossible");
    creer_schema(&pool).await;
    pool
}

async fn creer_schema(pool: &SqlitePool) {
    let schema = "
        CREATE TABLE IF NOT EXISTS comptes (
            userid            TEXT PRIMARY KEY,
            cle_publique      TEXT NOT NULL UNIQUE,
            pseudo            TEXT NOT NULL UNIQUE,
            email             TEXT UNIQUE,
            bio               TEXT NOT NULL DEFAULT '',
            avatar_url        TEXT NOT NULL DEFAULT '',
            partage_statut    INTEGER NOT NULL DEFAULT 1,
            partage_serveur   INTEGER NOT NULL DEFAULT 1,
            token             TEXT,
            token_expiration  INTEGER,
            date_creation     INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_comptes_token ON comptes(token);
        CREATE INDEX IF NOT EXISTS idx_comptes_pseudo ON comptes(pseudo);
        CREATE TABLE IF NOT EXISTS amities (
            demandeur     TEXT NOT NULL,
            destinataire  TEXT NOT NULL,
            etat          TEXT NOT NULL,
            date          INTEGER NOT NULL,
            PRIMARY KEY (demandeur, destinataire)
        );
        CREATE TABLE IF NOT EXISTS blocages (
            bloqueur  TEXT NOT NULL,
            bloque    TEXT NOT NULL,
            date      INTEGER NOT NULL,
            PRIMARY KEY (bloqueur, bloque)
        );
    ";
    // SQLite n'execute qu'une instruction a la fois : on decoupe sur ';'.
    for instruction in schema.split(';') {
        let s = instruction.trim();
        if s.is_empty() {
            continue;
        }
        sqlx::query(s).execute(pool).await.expect("creation du schema impossible");
    }
}

// Nombre de comptes (pour l'allongement automatique du userid).
pub async fn nombre_comptes(pool: &SqlitePool) -> i64 {
    let row = sqlx::query_as::<_, (i64,)>("SELECT COUNT(*) FROM comptes")
        .fetch_one(pool)
        .await;
    if row.is_err() {
        return 0;
    }
    row.unwrap().0
}
