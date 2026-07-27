//! Primitives crypto : verification Ed25519, generation de token / nonce / userid.

use ed25519_dalek::{Signature, VerifyingKey};
use rand::RngCore;

// Alphabet base32 SANS caracteres ambigus (pas de l, o, 0, 1). 32 symboles.
const ALPHABET: &[u8; 32] = b"abcdefghijkmnpqrstuvwxyz23456789";

// Vrai si `signature_hex` est bien la signature de `message` par la cle `cle_publique_hex`.
pub fn verifier_signature(cle_publique_hex: &str, message: &[u8], signature_hex: &str) -> bool {
    let cle_octets = hex::decode(cle_publique_hex);
    if cle_octets.is_err() {
        return false;
    }
    let cle_octets = cle_octets.unwrap();
    if cle_octets.len() != 32 {
        return false;
    }
    let mut cle_tab = [0u8; 32];
    cle_tab.copy_from_slice(&cle_octets);
    let vk = VerifyingKey::from_bytes(&cle_tab);
    if vk.is_err() {
        return false;
    }
    let vk = vk.unwrap();

    let sig_octets = hex::decode(signature_hex);
    if sig_octets.is_err() {
        return false;
    }
    let sig_octets = sig_octets.unwrap();
    if sig_octets.len() != 64 {
        return false;
    }
    let mut sig_tab = [0u8; 64];
    sig_tab.copy_from_slice(&sig_octets);
    let sig = Signature::from_bytes(&sig_tab);

    vk.verify_strict(message, &sig).is_ok()
}

// `n` octets aleatoires, rendus en hexadecimal.
pub fn hex_aleatoire(n: usize) -> String {
    let mut buf = vec![0u8; n];
    rand::thread_rng().fill_bytes(&mut buf);
    hex::encode(buf)
}

// Chaine aleatoire de `longueur` caracteres base32 (userid, serveur_id).
pub fn id_aleatoire(longueur: usize) -> String {
    let mut rng = rand::thread_rng();
    let mut s = String::with_capacity(longueur);
    let mut i = 0;
    while i < longueur {
        let idx = (rng.next_u32() as usize) % 32;
        s.push(ALPHABET[idx] as char);
        i += 1;
    }
    s
}

// Borne des anniversaires d'une longueur L : 32^(L/2) = seuil ou les collisions commencent
// a compter. Sature a u128::MAX si le calcul deborde (seuil alors inatteignable).
fn borne_anniversaire(longueur: usize) -> u128 {
    let exposant = longueur / 2;
    let mut r: u128 = 1;
    let mut i = 0;
    while i < exposant {
        let m = r.checked_mul(32);
        if m.is_none() {
            return u128::MAX;
        }
        r = m.unwrap();
        i += 1;
    }
    r
}

// Longueur d'un userid : part de `min` et DOUBLE (16->32->64...) chaque fois que le nombre
// de comptes atteint la borne des anniversaires de la longueur courante.
pub fn longueur_userid(min: usize, nb_comptes: i64) -> usize {
    let mut longueur = min;
    let n = nb_comptes as u128;
    while n >= borne_anniversaire(longueur) {
        longueur *= 2;
        if longueur >= 1024 {
            break; // garde-fou (jamais atteint en pratique)
        }
    }
    longueur
}
