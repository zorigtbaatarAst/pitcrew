//! The pitcrew config model, and the front ends onto it.
//!
//! Everything below the config layer is **format-blind**: it sees a
//! [`model::Project`] and never learns whether that came from YAML, from the
//! legacy bash format, or from a test fixture. That property is inherited from
//! `lib/02-config.sh` and is what let two config formats coexist for as long as
//! they did.

pub mod find;
pub mod load;
pub mod model;
pub mod validate;
pub mod yaml;
