//! The parity gate.
//!
//! `tests/golden/*.status.json` is real output captured from the bash
//! implementation (`./bin/pitcrew -C <fixture> status --json`). This test
//! deserializes it into the Rust contract types, re-serializes, and deep-compares
//! against the original.
//!
//! That catches all three ways the port can drift, and names the exact JSON path
//! for each:
//!
//!   * a field bash emits that the types do not model — dropped on the way in,
//!     shows up here as missing
//!   * a field the types invent — shows up as extra
//!   * a field whose type changed (a port that became a string, a null that
//!     became 0)
//!
//! It is deliberately NOT `deny_unknown_fields`: a hard deserialize error says
//! only "something is wrong", where the diff says which key, at which path.
//!
//! When the Rust CLI can produce this object itself (phase 4), this same
//! comparison runs against its live output and becomes the real parity gate.
//! Refresh the golden files by re-running the capture against the bash tree.

use pitcrew_model::Snapshot;
use serde_json::Value;

/// Walks two JSON values together, appending a human-readable line per
/// difference. `path` is a JSON-pointer-ish trail so a failure names the field.
fn diff(path: &str, want: &Value, got: &Value, out: &mut Vec<String>) {
    match (want, got) {
        // 1 and 1.0 are different `Value`s but the same number. Comparing as
        // f64 keeps an integer-valued float from reading as a contract break.
        (Value::Number(a), Value::Number(b)) => {
            let (a, b) = (a.as_f64(), b.as_f64());
            if a != b {
                out.push(format!("{path}: {want} != {got}"));
            }
        }
        (Value::Object(a), Value::Object(b)) => {
            for (k, av) in a {
                match b.get(k) {
                    Some(bv) => diff(&format!("{path}.{k}"), av, bv, out),
                    None => out.push(format!("{path}.{k}: MISSING from the Rust types")),
                }
            }
            for k in b.keys() {
                if !a.contains_key(k) {
                    out.push(format!("{path}.{k}: EXTRA, not emitted by bash"));
                }
            }
        }
        (Value::Array(a), Value::Array(b)) => {
            if a.len() != b.len() {
                out.push(format!("{path}: length {} != {}", a.len(), b.len()));
                return;
            }
            for (i, (av, bv)) in a.iter().zip(b).enumerate() {
                diff(&format!("{path}[{i}]"), av, bv, out);
            }
        }
        _ if want != got => out.push(format!("{path}: {want} != {got}")),
        _ => {}
    }
}

fn assert_round_trips(name: &str, raw: &str) {
    let original: Value = serde_json::from_str(raw)
        .unwrap_or_else(|e| panic!("{name}: golden file is not valid JSON: {e}"));

    let typed: Snapshot = serde_json::from_str(raw)
        .unwrap_or_else(|e| panic!("{name}: bash output does not fit the contract types: {e}"));

    let again = serde_json::to_value(&typed).expect("re-serialize");

    let mut diffs = Vec::new();
    diff("$", &original, &again, &mut diffs);
    assert!(
        diffs.is_empty(),
        "{name}: the contract types do not round-trip bash output:\n  {}",
        diffs.join("\n  ")
    );
}

/// The bash config format. Covers the awkward shapes on purpose: an app with
/// both roles, one backend-only, one frontend-only, health on one backend only.
#[test]
fn sh_fixture_round_trips() {
    assert_round_trips("fixture", include_str!("golden/fixture.status.json"));
}

/// The YAML front end onto the same model. The two formats describe the same
/// project, so a difference here is a difference between the front ends.
#[test]
fn yaml_fixture_round_trips() {
    assert_round_trips(
        "fixture-yaml",
        include_str!("golden/fixture-yaml.status.json"),
    );
}

/// The schema version is part of the contract, not of the crate version. If
/// this fails, either a field was removed or `SCHEMA` was bumped by accident.
#[test]
fn golden_files_declare_the_schema_this_crate_implements() {
    for (name, raw) in [
        ("fixture", include_str!("golden/fixture.status.json")),
        (
            "fixture-yaml",
            include_str!("golden/fixture-yaml.status.json"),
        ),
    ] {
        let s: Snapshot = serde_json::from_str(raw).unwrap();
        assert_eq!(s.schema, pitcrew_model::SCHEMA, "{name}: schema version");
    }
}

/// The key set, asserted directly rather than only via the round-trip, so a
/// reader can see the contract without running anything. Mirrors
/// `test/output_test.sh:39-56`.
#[test]
fn top_level_key_set_is_pinned() {
    let v: Value = serde_json::from_str(include_str!("golden/fixture.status.json")).unwrap();
    let mut keys: Vec<&str> = v.as_object().unwrap().keys().map(String::as_str).collect();
    keys.sort_unstable();
    assert_eq!(
        keys.join(" "),
        "at collector components deps errorPattern health logDir machine \
         profileDir profiles project root schema shells summary"
    );

    let mut ckeys: Vec<&str> = v["components"][0]
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect();
    ckeys.sort_unstable();
    assert_eq!(
        ckeys.join(" "),
        "app cpu enabled errors exit health idle limit limitSource name pid \
         port processes protected restarts role rss since state url"
    );
}
