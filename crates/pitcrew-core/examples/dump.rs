//! Dumps a YAML config as the flattened `path=value` pairs the parser produces,
//! in document order — the same shape `yaml_parse` leaves in YAML_KEYS/YAML_VALS
//! in the bash implementation, so the two can be diffed directly.
//!
//! This is the parser's parity harness, not a user-facing command.
fn main() {
    let path = std::env::args().nth(1).expect("usage: dump <file.yaml>");
    let text = std::fs::read_to_string(&path).expect("read");
    match pitcrew_core::yaml::parse(&text) {
        Ok(entries) => {
            for e in entries {
                println!("{}={}", e.path, e.value);
            }
        }
        Err(e) => {
            eprintln!("{path}:{e}");
            std::process::exit(1);
        }
    }
}
