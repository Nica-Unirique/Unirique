//! Identite Unirique : phrase secrete BIP39 -> paire de cles Ed25519.
//! Norme : Norms/identity.md
//!
//! Module WASM SANS ETAT et SANS AUCUN IMPORT : n'importe quel moteur le charge
//! sans rien cabler. Il existe parce que certains moteurs — Godot notamment —
//! n'ont ni SHA512 ni Ed25519. Un moteur qui dispose de ces primitives peut
//! l'ignorer et implementer directement la norme : c'est elle qui fait foi.
//!
//! AUCUNE cryptographie n'est ecrite ici. Tout vient de `bip39` et
//! `ed25519-dalek` ; ce fichier n'est que de la plomberie.
//!
//! DERIVATION FIGEE, ne doit JAMAIS changer — en changer rendrait tout compte
//! existant irrecuperable :
//!   phrase 24 mots --PBKDF2-HMAC-SHA512, 2048 tours--> graine 64 octets
//!   graine[0..32] --> cle privee Ed25519
//!
//! ABI : aucun allocateur. Deux tampons statiques de taille fixe, dont l'hote
//! lit l'adresse une fois pour toutes. Entrees et sorties sont bornees.
//!   1. l'hote ecrit ses octets a `input_ptr()`
//!   2. il appelle la fonction en donnant les longueurs
//!   3. elle renvoie la longueur ecrite a `output_ptr()`, ou ERREUR

use bip39::Mnemonic;
use core::ptr::addr_of_mut;
use ed25519_dalek::{Signer, SigningKey};

/// Phrase (24 mots, ~220 octets) puis message a signer. Large de quoi voir venir.
const TAILLE_ENTREE: usize = 1024;
/// Le plus long resultat est une signature en hexadecimal : 128 caracteres.
const TAILLE_SORTIE: usize = 256;
/// Phrase invalide, longueurs hors bornes, ou resultat trop long.
const ERREUR: i32 = -1;

static mut ENTREE: [u8; TAILLE_ENTREE] = [0; TAILLE_ENTREE];
static mut SORTIE: [u8; TAILLE_SORTIE] = [0; TAILLE_SORTIE];

// --- ABI : adresses des tampons, lues une fois par l'hote ---

#[no_mangle]
pub extern "C" fn input_ptr() -> i32 {
    addr_of_mut!(ENTREE) as i32
}

#[no_mangle]
pub extern "C" fn output_ptr() -> i32 {
    addr_of_mut!(SORTIE) as i32
}

#[no_mangle]
pub extern "C" fn input_size() -> i32 {
    TAILLE_ENTREE as i32
}

// --- Fonctions ---

/// Cle publique en hexadecimal (64 caracteres).
/// Entree : la phrase, en UTF-8.
#[no_mangle]
pub extern "C" fn public_key(phrase_len: i32) -> i32 {
    let phrase = read_text(0, phrase_len);
    if phrase.is_none() {
        return ERREUR;
    }
    let key = derive(phrase.unwrap());
    if key.is_none() {
        return ERREUR;
    }
    write_output(&hex::encode(key.unwrap().verifying_key().to_bytes()))
}

/// Signature en hexadecimal (128 caracteres).
/// Entree : la phrase en UTF-8, suivie du message BRUT a signer.
/// Le defi du serveur arrive en hexadecimal : l'hote le DECODE avant de
/// l'ecrire ici, car c'est sur les octets decodes que porte la verification.
#[no_mangle]
pub extern "C" fn sign(phrase_len: i32, message_len: i32) -> i32 {
    let phrase = read_text(0, phrase_len);
    if phrase.is_none() {
        return ERREUR;
    }
    let message = read_bytes(phrase_len, message_len);
    if message.is_none() {
        return ERREUR;
    }
    let key = derive(phrase.unwrap());
    if key.is_none() {
        return ERREUR;
    }
    let signature = key.unwrap().sign(message.unwrap());
    write_output(&hex::encode(signature.to_bytes()))
}

// --- Interne ---

/// La derivation figee. None si la phrase est invalide : mot hors liste,
/// nombre de mots incorrect, ou checksum faux.
fn derive(phrase: &str) -> Option<SigningKey> {
    let mnemonic = Mnemonic::parse(phrase);
    if mnemonic.is_err() {
        return None;
    }
    // Mot de passe BIP39 vide : la phrase seule constitue l'identite.
    let seed = mnemonic.unwrap().to_seed("");
    let mut secret = [0u8; 32];
    secret.copy_from_slice(&seed[0..32]);
    Some(SigningKey::from_bytes(&secret))
}

fn read_bytes(start: i32, length: i32) -> Option<&'static [u8]> {
    if start < 0 || length < 0 {
        return None;
    }
    let end = (start as usize) + (length as usize);
    if end > TAILLE_ENTREE {
        return None;
    }
    let tampon: &'static [u8] = unsafe { &*addr_of_mut!(ENTREE) };
    Some(&tampon[start as usize..end])
}

fn read_text(start: i32, length: i32) -> Option<&'static str> {
    let octets = read_bytes(start, length);
    if octets.is_none() {
        return None;
    }
    let texte = core::str::from_utf8(octets.unwrap());
    if texte.is_err() {
        return None;
    }
    Some(texte.unwrap())
}

/// Renvoie la longueur ecrite, ou ERREUR si le resultat ne tient pas.
fn write_output(texte: &str) -> i32 {
    let octets = texte.as_bytes();
    if octets.len() > TAILLE_SORTIE {
        return ERREUR;
    }
    let tampon: &mut [u8] = unsafe { &mut *addr_of_mut!(SORTIE) };
    tampon[..octets.len()].copy_from_slice(octets);
    octets.len() as i32
}

// --- Vecteurs de test ---
//
// Ils VERROUILLENT la derivation. S'ils cassent un jour, ce n'est pas le test
// qu'il faut corriger : c'est que la derivation a change, et que tout compte
// existant vient de devenir irrecuperable.

#[cfg(test)]
mod tests {
    use super::*;

    /// Vecteur officiel BIP39 : entropie de 256 bits toute a zero -> 24 mots.
    const PHRASE: &str = "abandon abandon abandon abandon abandon abandon abandon abandon \
                          abandon abandon abandon abandon abandon abandon abandon abandon \
                          abandon abandon abandon abandon abandon abandon abandon art";

    /// Graine de reference pour PHRASE, mot de passe vide (jeu de tests BIP39).
    const GRAINE: &str = "408b285c123836004f4b8842c89324c1f01382450c0d439af345ba7fc49acf70\
                          5489c6fc77dbd4e3dc1dd8cc6bc9f043db8ada1e243c4a0eafb290d399480840";

    /// Meme entropie sur 128 bits -> 12 mots. Second vecteur, pour verifier
    /// PBKDF2 contre une reference DIFFERENTE de celle qu'on verrouille.
    const PHRASE_12: &str = "abandon abandon abandon abandon abandon abandon \
                             abandon abandon abandon abandon abandon about";
    const GRAINE_12: &str = "5eb00bbddcf069084889a8ab9155568165f5c453ccb85e70811aaed6f6da5fc1\
                             9a5ac40b389cd370d086206dec8aa6c43daea6690f20ad3d8d48b2d2ce9e38e4";

    /// Cle publique attendue pour PHRASE. C'est CE vecteur qui garantit qu'une
    /// reimplementation future rouvrira les memes comptes.
    const CLE_PUBLIQUE: &str =
        "1de352e44cd333672593f2334a730e180aaf290de89aa16d480de594e34e2961";

    #[test]
    fn graine_conforme_au_vecteur_bip39() {
        let seed = Mnemonic::parse(PHRASE).unwrap().to_seed("");
        assert_eq!(hex::encode(seed), GRAINE);
    }

    #[test]
    fn graine_conforme_au_vecteur_bip39_12_mots() {
        let seed = Mnemonic::parse(PHRASE_12).unwrap().to_seed("");
        assert_eq!(hex::encode(seed), GRAINE_12);
    }

    #[test]
    fn cle_publique_stable() {
        let cle = derive(PHRASE).unwrap();
        assert_eq!(hex::encode(cle.verifying_key().to_bytes()), CLE_PUBLIQUE);
    }

    #[test]
    fn cle_privee_est_bien_la_premiere_moitie_de_la_graine() {
        // Le seul pas non standard du schema, verifie explicitement.
        let seed = Mnemonic::parse(PHRASE).unwrap().to_seed("");
        assert_eq!(hex::encode(derive(PHRASE).unwrap().to_bytes()), hex::encode(&seed[0..32]));
    }

    #[test]
    fn signature_verifiable_par_la_cle_publique() {
        use ed25519_dalek::Verifier;
        let cle = derive(PHRASE).unwrap();
        let message = b"defi du serveur";
        let signature = cle.sign(message);
        // Meme chemin que `crypto::verifier_signature` cote serveur data.
        let publique = cle.verifying_key();
        assert!(publique.verify(message, &signature).is_ok());
        assert_eq!(hex::encode(signature.to_bytes()).len(), 128);
    }

    /// Outil, pas un test : extrait les 2048 mots pour les moteurs, qui en ont
    /// besoin pour l'autocompletion et la generation. Ainsi la liste cote
    /// moteur est FORCEMENT celle que ce module valide.
    ///   cargo test -p identity -- --ignored extraire_liste_des_mots
    #[test]
    #[ignore]
    fn extraire_liste_des_mots() {
        let mots = bip39::Language::English.word_list();
        assert_eq!(mots.len(), 2048);
        std::fs::write("wordlist.txt", mots.join("\n")).unwrap();
    }

    #[test]
    fn phrase_invalide_rejetee() {
        assert!(derive("ceci n est pas une phrase bip39").is_none());
        // Checksum faux : mots valides, mais dernier mot incoherent.
        let bancale = PHRASE.replace(" art", " zoo");
        assert!(derive(&bancale).is_none());
    }
}
