//! Codes d'entree (convention du contrat). Les memes des deux cotes :
//! `client::input-down(code)` et `server::input-down(player, code)`.

pub const LEFT: u32 = 0;
pub const RIGHT: u32 = 1;
pub const UP: u32 = 2;
pub const DOWN: u32 = 3;
pub const ACTION: u32 = 4;
pub const BACK: u32 = 5;
