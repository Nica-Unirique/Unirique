//! Etat partage : pool DB, config, et les structures RAM (defis, presence, serveurs).

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use sqlx::sqlite::SqlitePool;
use crate::config::Config;

// Un serveur jouable vivant (RAM, jamais persiste).
#[derive(Clone)]
pub struct ServeurVivant {
    pub proprietaire: String,
    pub nom: String,
    // Plusieurs, par ordre de preference : IPv6 globale (pas de NAT), IPv4
    // publique, IPv4 privee. Le client qui rejoint essaie dans l'ordre — un ami
    // sans IPv6 doit pouvoir passer par autre chose.
    // Notation : [2a01:cb00::1]:25000 ou 192.168.1.10:25000
    pub adresses: Vec<String>,
    pub jeu: String,
    pub visibilite: String,
    pub nb_joueurs: i64,
    pub last_seen: i64,
}

pub struct Ram {
    // cle_publique -> (nonce_hex, expiration_unix)
    pub defis: Mutex<HashMap<String, (String, i64)>>,
    // userid -> (last_seen_unix, serveur_courant optionnel)
    pub presence: Mutex<HashMap<String, (i64, Option<String>)>>,
    // serveur_id -> ServeurVivant
    pub serveurs: Mutex<HashMap<String, ServeurVivant>>,
}

impl Ram {
    pub fn nouveau() -> Ram {
        Ram {
            defis: Mutex::new(HashMap::new()),
            presence: Mutex::new(HashMap::new()),
            serveurs: Mutex::new(HashMap::new()),
        }
    }
}

#[derive(Clone)]
pub struct AppState {
    pub db: SqlitePool,
    pub config: Arc<Config>,
    pub ram: Arc<Ram>,
}
