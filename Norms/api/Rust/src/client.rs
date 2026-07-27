//! `interface client` : ce qui n'existe que chez le joueur.

#[link(wasm_import_module = "client")]
extern "C" {
    #[link_name = "input_value"] fn raw_input_value(code: u32) -> f32;
}

// Valeur d'une entrée du joueur local, 0.0..1.0. 0/1 pour une touche, la course
// réelle pour un stick ou une gâchette. Codes dans `input`.
pub fn input_value(code: u32) -> f32 {
    unsafe { raw_input_value(code) }
}
