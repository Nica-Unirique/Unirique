use api::*;
use api::client::*;

// Le hub cote joueur.
//
// Le decor, les portails et les avatars appartiennent au serveur : ils arrivent
// par la replication, ce module n'a rien a en faire. Il ne lui reste que ce qui
// est purement local — rien pour l'instant.
//
// Ce vide est normal, pas un oubli : dans un monde a autorite serveur, le module
// client ne sert qu'aux effets locaux, a la prediction et a l'affichage propre
// au joueur. Aucun des trois n'existe encore.

#[no_mangle]
pub extern "C" fn start() {
    // Consomme l'import de `client` pour qu'il reste declare tant que le module
    // ne s'en sert pas encore.
    let _ = input_value(ACTION);
}

#[no_mangle]
pub extern "C" fn update(_dt: f32) {}
