//! SDK Unirique — miroir du contrat. Rien ici qui ne soit dans le contrat.
//!
//! Le contrat a trois interfaces : `scene` (les objets, partagee), `client`
//! (entrees du joueur local) et `server` (entrees par joueur). Un module WASM
//! ne peut declarer que celles que son hote fournit, d'ou les features.

pub mod input;
pub mod scene;

#[cfg(feature = "client")]
pub mod client;

#[cfg(feature = "server")]
pub mod server;

pub use input::*;
pub use scene::*;
