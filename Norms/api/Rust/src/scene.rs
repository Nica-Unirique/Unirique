//! `interface scene` : les objets. Importee par le client ET par le serveur.

// Modes de replication (parametre de `set_sync`, convention du contrat).
pub const SYNC_LOCAL: u32 = 0;   // jamais envoye
pub const SYNC_SERVER: u32 = 1;  // serveur -> clients
pub const SYNC_CLIENT: u32 = 2;  // client -> serveur

#[link(wasm_import_module = "scene")]
extern "C" {
    #[link_name = "object_spawn"]        fn raw_spawn() -> u64;
    #[link_name = "object_destroy"]      fn raw_destroy(id: u64);
    #[link_name = "object_set_position"] fn raw_set_position(id: u64, x: f32, y: f32, z: f32);
    #[link_name = "object_set_rotation"] fn raw_set_rotation(id: u64, x: f32, y: f32, z: f32, w: f32);
    #[link_name = "object_set_scale"]    fn raw_set_scale(id: u64, x: f32, y: f32, z: f32);
    #[link_name = "object_set_color"]    fn raw_set_color(id: u64, argb: u32);
    #[link_name = "object_set_sync"]     fn raw_set_sync(id: u64, mode: u32);
    #[link_name = "log"]                 fn raw_log(value: f64);

    // Relecture. Sur le serveur : la valeur autoritaire. Sur le client : la
    // valeur AFFICHEE, donc interpolee et en leger retard.
    #[link_name = "object_get_position_x"] fn raw_get_position_x(id: u64) -> f32;
    #[link_name = "object_get_position_y"] fn raw_get_position_y(id: u64) -> f32;
    #[link_name = "object_get_position_z"] fn raw_get_position_z(id: u64) -> f32;
    #[link_name = "object_get_rotation_x"] fn raw_get_rotation_x(id: u64) -> f32;
    #[link_name = "object_get_rotation_y"] fn raw_get_rotation_y(id: u64) -> f32;
    #[link_name = "object_get_rotation_z"] fn raw_get_rotation_z(id: u64) -> f32;
    #[link_name = "object_get_rotation_w"] fn raw_get_rotation_w(id: u64) -> f32;
    #[link_name = "object_get_scale_x"]    fn raw_get_scale_x(id: u64) -> f32;
    #[link_name = "object_get_scale_y"]    fn raw_get_scale_y(id: u64) -> f32;
    #[link_name = "object_get_scale_z"]    fn raw_get_scale_z(id: u64) -> f32;
    #[link_name = "object_get_color"]      fn raw_get_color(id: u64) -> u32;
}

pub fn spawn() -> u64 {
    unsafe { raw_spawn() }
}

pub fn destroy(id: u64) {
    unsafe { raw_destroy(id) }
}

pub fn set_position(id: u64, x: f32, y: f32, z: f32) {
    unsafe { raw_set_position(id, x, y, z) }
}

pub fn set_rotation(id: u64, x: f32, y: f32, z: f32, w: f32) {
    unsafe { raw_set_rotation(id, x, y, z, w) }
}

pub fn set_scale(id: u64, x: f32, y: f32, z: f32) {
    unsafe { raw_set_scale(id, x, y, z) }
}

pub fn set_color(id: u64, argb: u32) {
    unsafe { raw_set_color(id, argb) }
}

pub fn set_sync(id: u64, mode: u32) {
    unsafe { raw_set_sync(id, mode) }
}

pub fn log(value: f64) {
    unsafe { raw_log(value) }
}

pub fn get_position_x(id: u64) -> f32 {
    unsafe { raw_get_position_x(id) }
}

pub fn get_position_y(id: u64) -> f32 {
    unsafe { raw_get_position_y(id) }
}

pub fn get_position_z(id: u64) -> f32 {
    unsafe { raw_get_position_z(id) }
}

pub fn get_rotation_x(id: u64) -> f32 {
    unsafe { raw_get_rotation_x(id) }
}

pub fn get_rotation_y(id: u64) -> f32 {
    unsafe { raw_get_rotation_y(id) }
}

pub fn get_rotation_z(id: u64) -> f32 {
    unsafe { raw_get_rotation_z(id) }
}

pub fn get_rotation_w(id: u64) -> f32 {
    unsafe { raw_get_rotation_w(id) }
}

pub fn get_scale_x(id: u64) -> f32 {
    unsafe { raw_get_scale_x(id) }
}

pub fn get_scale_y(id: u64) -> f32 {
    unsafe { raw_get_scale_y(id) }
}

pub fn get_scale_z(id: u64) -> f32 {
    unsafe { raw_get_scale_z(id) }
}

pub fn get_color(id: u64) -> u32 {
    unsafe { raw_get_color(id) }
}
