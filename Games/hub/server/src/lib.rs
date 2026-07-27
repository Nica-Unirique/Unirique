use api::*;
use api::server::*;

// Le hub cote autorite : il construit le decor et surveille les portails.
// Il ne cree AUCUN avatar — les joueurs appartiennent a la plateforme, qui les
// cree et les deplace. Le jeu ne recoit que leur objet de scene.

const NB_PORTAILS: usize = 3;
const PORTAIL_X: [f32; NB_PORTAILS] = [-3.0, 0.0, 3.0];
const PORTAIL_Z: f32 = -2.0;
const COULEURS: [u32; NB_PORTAILS] = [0xFF3399FF, 0xFF33CC66, 0xFFCC5533];
const BLANC: u32 = 0xFFFFFFFF;

const MAX_PLAYERS: usize = 16;
const PORTEE_X: f32 = 1.2;
const PORTEE_Z: f32 = 2.5;

static mut PORTAILS: [u64; NB_PORTAILS] = [0; NB_PORTAILS];
static mut SURVOL: i32 = -1;

// Tableaux paralleles indexes par PLACE. 0 dans PLAYERS = place libre.
static mut PLAYERS: [u64; MAX_PLAYERS] = [0; MAX_PLAYERS];
static mut AVATARS: [u64; MAX_PLAYERS] = [0; MAX_PLAYERS];

#[no_mangle]
pub extern "C" fn start() {
    unsafe {
        build_ground();
        build_portals();
    }
}

#[no_mangle]
pub extern "C" fn update(_dt: f32) {
    unsafe {
        let survole = portal_under_players();
        if survole == SURVOL {
            return;
        }
        // On ne repeint qu'au changement : inutile de reecrire la meme couleur
        // 60 fois par seconde, la replication n'enverrait rien mais le jeu
        // travaillerait pour rien.
        if SURVOL >= 0 {
            let ancien = SURVOL as usize;
            set_color(PORTAILS[ancien], COULEURS[ancien]);
        }
        if survole >= 0 {
            set_color(PORTAILS[survole as usize], BLANC);
            log(survole as f64);
        }
        SURVOL = survole;
    }
}

#[no_mangle]
pub extern "C" fn player_join(player: u64, object: u64) {
    unsafe {
        let place = free_place();
        if place >= MAX_PLAYERS {
            return; // serveur plein
        }
        PLAYERS[place] = player;
        AVATARS[place] = object;
        log(player_count() as f64);
    }
}

#[no_mangle]
pub extern "C" fn player_leave(player: u64, _object: u64) {
    unsafe {
        let place = place_of(player);
        if place >= MAX_PLAYERS {
            return;
        }
        PLAYERS[place] = 0;
        AVATARS[place] = 0;
        log(player_count() as f64);
    }
}

// --- decor ---

unsafe fn build_ground() {
    let ground = spawn();
    set_position(ground, 0.0, -1.1, 0.0);
    set_scale(ground, 14.0, 0.2, 12.0);
    set_color(ground, 0xFF23262E);
    set_sync(ground, SYNC_SERVER);
}

unsafe fn build_portals() {
    let mut index = 0;
    while index < NB_PORTAILS {
        let portail = spawn();
        set_position(portail, PORTAIL_X[index], 0.0, PORTAIL_Z);
        set_scale(portail, 1.2, 2.4, 0.4);
        set_color(portail, COULEURS[index]);
        set_sync(portail, SYNC_SERVER);
        PORTAILS[index] = portail;
        index += 1;
    }
}

// --- survol ---

// Le premier portail devant lequel se tient un joueur, ou -1.
unsafe fn portal_under_players() -> i32 {
    let mut place = 0;
    while place < MAX_PLAYERS {
        if PLAYERS[place] != 0 {
            let portail = portal_under(AVATARS[place]);
            if portail >= 0 {
                return portail;
            }
        }
        place += 1;
    }
    -1
}

unsafe fn portal_under(avatar: u64) -> i32 {
    let x = get_position_x(avatar);
    let z = get_position_z(avatar);

    let mut index = 0;
    while index < NB_PORTAILS {
        let dx = x - PORTAIL_X[index];
        let dz = z - PORTAIL_Z;
        if dx * dx < PORTEE_X && dz * dz < PORTEE_Z {
            return index as i32;
        }
        index += 1;
    }
    -1
}

// --- places ---

unsafe fn free_place() -> usize {
    let mut place = 0;
    while place < MAX_PLAYERS {
        if PLAYERS[place] == 0 {
            return place;
        }
        place += 1;
    }
    MAX_PLAYERS
}

unsafe fn place_of(player: u64) -> usize {
    let mut place = 0;
    while place < MAX_PLAYERS {
        if PLAYERS[place] == player {
            return place;
        }
        place += 1;
    }
    MAX_PLAYERS
}
