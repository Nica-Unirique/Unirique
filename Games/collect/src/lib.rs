use api::*;
use api::client::*;

const NB: usize = 3;
const PORTAIL_X: [f32; NB] = [-3.0, 0.0, 3.0];
const PORTAIL_Z: f32 = -2.0;
const COULEURS: [u32; NB] = [0xFF3399FF, 0xFF33CC66, 0xFFCC5533];
const VITESSE: f32 = 5.0;

static mut PORTAILS: [u64; NB] = [0; NB];
static mut JOUEUR: u64 = 0;
static mut X: f32 = 0.0;
static mut Z: f32 = 4.0;
static mut SURVOL: i32 = -1;

#[no_mangle]
pub extern "C" fn start() {
    unsafe {
        let sol = spawn();
        set_position(sol, 0.0, -1.1, 0.0);
        set_scale(sol, 14.0, 0.2, 12.0);
        set_color(sol, 0xFF23262E);

        let mut i = 0;
        while i < NB {
            let p = spawn();
            set_position(p, PORTAIL_X[i], 0.0, PORTAIL_Z);
            set_scale(p, 1.2, 2.4, 0.4);
            set_color(p, COULEURS[i]);
            PORTAILS[i] = p;
            i += 1;
        }

        JOUEUR = spawn();
        X = 0.0;
        Z = 4.0;
        set_position(JOUEUR, X, 0.0, Z);
        set_color(JOUEUR, 0xFFFFFFFF);
    }
}

#[no_mangle]
pub extern "C" fn update(dt: f32) {
    unsafe {
        // input_value rend 0.0..1.0 ; > 0.5 = pressé.
        if input_value(LEFT)  > 0.5 { X -= VITESSE * dt; }
        if input_value(RIGHT) > 0.5 { X += VITESSE * dt; }
        if input_value(UP)    > 0.5 { Z -= VITESSE * dt; }
        if input_value(DOWN)  > 0.5 { Z += VITESSE * dt; }

        if X < -6.0 { X = -6.0; }
        if X >  6.0 { X =  6.0; }
        if Z < -5.0 { Z = -5.0; }
        if Z >  5.0 { Z =  5.0; }
        set_position(JOUEUR, X, 0.0, Z);

        // Quel portail est survolé ?
        let mut nouveau: i32 = -1;
        let mut i = 0;
        while i < NB {
            let dx = X - PORTAIL_X[i];
            let dz = Z - PORTAIL_Z;
            if dx * dx < 1.2 && dz * dz < 2.5 { nouveau = i as i32; }
            i += 1;
        }

        // On ne redessine que lors d'un changement.
        if nouveau != SURVOL {
            if SURVOL >= 0 {
                let a = SURVOL as usize;
                set_color(PORTAILS[a], COULEURS[a]);
            }
            if nouveau >= 0 {
                set_color(PORTAILS[nouveau as usize], 0xFFFFFFFF);
                log(nouveau as f64);   // le client saura quoi lancer
            }
            SURVOL = nouveau;
        }
    }
}