//! `interface server` : ce qui n'existe que chez l'autorité.

#[link(wasm_import_module = "server")]
extern "C" {
    #[link_name = "input_value"]  fn raw_input_value(player: u64, code: u32) -> f32;
    #[link_name = "player_count"] fn raw_player_count() -> u32;
}

// Valeur d'une entrée d'UN joueur précis, 0.0..1.0. Codes dans `input`.
pub fn input_value(player: u64, code: u32) -> f32 {
    unsafe { raw_input_value(player, code) }
}

pub fn player_count() -> u32 {
    unsafe { raw_player_count() }
}
