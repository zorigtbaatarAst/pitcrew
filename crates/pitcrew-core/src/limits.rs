//! Per-component RAM caps, and where each one came from.
//!
//! Resolution, highest first:
//!
//! 1. a machine-local override — `~/.config/pitcrew/<session>/limits`
//! 2. a per-component `max:` in the project config
//! 3. the role default (`max.be`), falling back to `be`'s
//!
//! **Why (1) is a machine-local file rather than more config.** A cap is a
//! property of the MACHINE, not the project. 8G is generous on a 64G
//! workstation and suicidal on a 16G laptop, and two developers sharing a repo
//! should not be editing each other's numbers in git. (2) still exists for a
//! project that genuinely wants to say "this one is small" for everybody.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use pitcrew_model::LimitSource;

use crate::model::{Component, Project};

/// Machine-local overrides, keyed by component name.
#[derive(Debug, Clone, Default)]
pub struct Limits {
    file: PathBuf,
    overrides: BTreeMap<String, String>,
}

impl Limits {
    /// `<pitcrew home>/<session>/limits`.
    pub fn path_for(home: &Path, session: &str) -> PathBuf {
        home.join(session).join("limits")
    }

    /// Read the overrides. A missing file is the ordinary case, not an error.
    ///
    /// A line this version cannot use means a hand edit or a newer format:
    /// that one line is ignored rather than refusing to start the whole tool.
    pub fn load(file: &Path) -> Limits {
        let mut overrides = BTreeMap::new();
        if let Ok(text) = std::fs::read_to_string(file) {
            for line in text.lines() {
                let line = line.trim();
                if line.is_empty() || line.starts_with('#') {
                    continue;
                }
                let Some((key, value)) = line.split_once('=') else {
                    continue;
                };
                if valid(value) {
                    overrides.insert(key.trim().to_string(), value.trim().to_string());
                }
            }
        }
        Limits {
            file: file.to_path_buf(),
            overrides,
        }
    }

    pub fn get(&self, component: &str) -> Option<&str> {
        self.overrides.get(component).map(String::as_str)
    }

    /// Set or clear one component's override, and rewrite the file.
    ///
    /// Rejects a size this tool could not hand to a kernel: the value ends up
    /// in systemd's `MemoryMax`, where `8gb` or `8 G` fails the unit at start
    /// time with an error nobody connects back to a typo in a limits file.
    pub fn set(&mut self, component: &str, value: Option<&str>) -> Result<(), String> {
        match value {
            Some(v) if !valid(v) => {
                return Err(format!(
                    "'{v}' is not a usable size — write it as 512M, 8G, or a byte count"
                ))
            }
            Some(v) => {
                self.overrides.insert(component.to_string(), v.to_string());
            }
            None => {
                self.overrides.remove(component);
            }
        }
        self.save()
    }

    fn save(&self) -> Result<(), String> {
        if let Some(dir) = self.file.parent() {
            std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
        }
        let body: String = self
            .overrides
            .iter()
            .map(|(k, v)| format!("{k}={v}\n"))
            .collect();
        std::fs::write(&self.file, body).map_err(|e| format!("{}: {e}", self.file.display()))
    }

    /// The cap for a component, and which of the three layers supplied it.
    pub fn resolve(&self, p: &Project, c: &Component) -> (String, LimitSource) {
        if let Some(v) = self.get(&c.name) {
            return (v.to_string(), LimitSource::Override);
        }
        if !c.max.is_empty() {
            return (c.max.clone(), LimitSource::App);
        }
        (p.max_for(c), LimitSource::Role)
    }
}

/// `<integer><M|G>`, or a plain byte count.
///
/// Deliberately strict for the reason in [`Limits::set`]: a value that systemd
/// rejects fails the unit rather than the config, and the error surfaces
/// somewhere unrelated.
pub fn valid(s: &str) -> bool {
    to_bytes(s).is_some()
}

/// A size as bytes. `None` when it is not a size this tool will hand to a
/// kernel.
pub fn to_bytes(s: &str) -> Option<u64> {
    let s = s.trim();
    if s.is_empty() {
        return None;
    }
    let (digits, scale) = match s.chars().last() {
        Some('M' | 'm') => (&s[..s.len() - 1], 1024 * 1024),
        Some('G' | 'g') => (&s[..s.len() - 1], 1024 * 1024 * 1024),
        _ => (s, 1),
    };
    let n: u64 = digits.parse().ok()?;
    // A cap of zero is not a cap. Left as invalid so it is reported rather
    // than applied as "this component may use no memory at all".
    if n == 0 {
        return None;
    }
    n.checked_mul(scale)
}

/// The label the dashboard prints. `8G` is already what we want; a raw byte
/// count is humanised so a cell never reads `8589934592`.
pub fn label(s: &str) -> String {
    match s.chars().last() {
        Some('M' | 'm' | 'G' | 'g') => s.to_uppercase(),
        _ => match to_bytes(s) {
            Some(b) if b % (1024 * 1024 * 1024) == 0 => format!("{}G", b / (1024 * 1024 * 1024)),
            Some(b) if b % (1024 * 1024) == 0 => format!("{}M", b / (1024 * 1024)),
            Some(b) => format!("{b}"),
            None => s.to_string(),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{App, Role};

    fn tmp(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("pitcrew-limits-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d.join("limits")
    }

    #[test]
    fn sizes_convert_and_reject_the_shapes_systemd_would() {
        assert_eq!(to_bytes("512M"), Some(512 * 1024 * 1024));
        assert_eq!(to_bytes("8G"), Some(8 * 1024 * 1024 * 1024));
        assert_eq!(to_bytes("8g"), Some(8 * 1024 * 1024 * 1024));
        assert_eq!(to_bytes("1048576"), Some(1048576));
        // Each of these fails the unit at start time, far from the typo.
        for bad in ["8gb", "8 G", "", "G", "-1", "8.5G", "lots"] {
            assert!(to_bytes(bad).is_none(), "{bad} should be rejected");
        }
    }

    /// A cap of zero is not a cap. Applying it literally would say "this
    /// component may use no memory at all".
    #[test]
    fn zero_is_not_a_cap() {
        assert!(to_bytes("0").is_none());
        assert!(to_bytes("0G").is_none());
    }

    #[test]
    fn labels_stay_readable() {
        assert_eq!(label("8G"), "8G");
        assert_eq!(label("512m"), "512M");
        assert_eq!(label("2147483648"), "2G");
        assert_eq!(label("1048576"), "1M");
    }

    /// A hand edit or a newer format should cost that one line, not the tool.
    #[test]
    fn an_unusable_line_is_skipped_not_fatal() {
        let f = tmp("bad-line");
        std::fs::write(
            &f,
            "# a comment\nbe-a=8G\nfe-a=8gb\n\ngarbage\nworker-a=512M\n",
        )
        .unwrap();
        let l = Limits::load(&f);
        assert_eq!(l.get("be-a"), Some("8G"));
        assert_eq!(l.get("worker-a"), Some("512M"));
        assert_eq!(l.get("fe-a"), None, "8gb is not usable");
    }

    #[test]
    fn a_missing_file_is_not_an_error() {
        assert!(Limits::load(Path::new("/nonexistent/limits"))
            .overrides
            .is_empty());
    }

    #[test]
    fn setting_and_clearing_round_trips_through_the_file() {
        let f = tmp("round-trip");
        let mut l = Limits::load(&f);
        l.set("be-a", Some("4G")).unwrap();
        l.set("fe-a", Some("512M")).unwrap();
        assert_eq!(Limits::load(&f).get("be-a"), Some("4G"));

        l.set("be-a", None).unwrap();
        let reread = Limits::load(&f);
        assert_eq!(reread.get("be-a"), None);
        assert_eq!(reread.get("fe-a"), Some("512M"), "the others survive");
    }

    /// Rejected at the point of entry, not written and discovered later.
    #[test]
    fn an_unusable_size_is_refused_with_the_spelling_that_works() {
        let f = tmp("refuse");
        let mut l = Limits::load(&f);
        let e = l.set("be-a", Some("8gb")).expect_err("refused");
        assert!(e.contains("512M, 8G, or a byte count"), "{e}");
        assert!(!f.exists(), "nothing was written");
    }

    /// The whole point of the three layers: the machine wins.
    #[test]
    fn resolution_is_override_then_component_then_role() {
        let f = tmp("resolve");
        std::fs::write(&f, "be-a=1G\n").unwrap();
        let limits = Limits::load(&f);

        let comp = |role: &str, max: &str| Component {
            name: format!("{role}-a"),
            app: "a".into(),
            role: role.into(),
            max: max.into(),
            enabled: true,
            ..Default::default()
        };
        let p = Project {
            roles: vec![Role {
                name: "be".into(),
                env: String::new(),
                max: "4G".into(),
            }],
            apps: vec![App {
                name: "a".into(),
                enabled: true,
                components: vec![comp("be", "2G"), comp("fe", "2G"), comp("worker", "")],
                ..Default::default()
            }],
            ..Default::default()
        };

        assert_eq!(
            limits.resolve(&p, &comp("be", "2G")),
            ("1G".into(), LimitSource::Override),
            "the machine-local file wins over the project"
        );
        assert_eq!(
            limits.resolve(&p, &comp("fe", "2G")),
            ("2G".into(), LimitSource::App)
        );
        assert_eq!(
            limits.resolve(&p, &comp("worker", "")),
            ("4G".into(), LimitSource::Role),
            "a role nobody budgeted for falls back to be's number"
        );
    }
}
