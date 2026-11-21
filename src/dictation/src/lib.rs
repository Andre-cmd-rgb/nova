//! Nova's dictation daemon, nova-dictationd: speech to text on this
//! computer's CPU, heard while it is said (docs/ARCHITECTURE.md, Dictation).

pub mod dictation;
pub mod engine;
pub mod look;
pub mod server;
pub mod settle;
pub mod system;
pub mod tidy;
pub mod vocab;
pub mod voice;
