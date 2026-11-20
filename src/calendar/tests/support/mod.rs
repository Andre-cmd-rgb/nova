//! What the sync's tests share: small encodings (codec.rs), a CalDAV server of
//! their own (fake.rs), and the computer the sync runs on, with the shell's and
//! the phone's parts (pc.rs).

pub mod codec;
pub mod fake;
pub mod pc;
