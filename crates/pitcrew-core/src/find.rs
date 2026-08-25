//! Finding a project's config, and its root, without loading it.
//!
//! The root has to be known **before** the file is read, because paths in the
//! file resolve against it — so it cannot come out of the loaded model. It is
//! read back out of the text instead, which is what `config_declared_root` does
//! in the bash implementation and for the same reason.

use std::path::{Path, PathBuf};

use crate::model::Format;

/// Config file names, in the order they win. YAML is the default; the bash
/// format is still recognised so the tool can say what it is rather than
/// reporting a missing config.
pub const CONFIG_NAMES: &[(&str, Format)] = &[
    ("pitcrew.yaml", Format::Yaml),
    ("pitcrew.yml", Format::Yaml),
    ("pitcrew.config.sh", Format::Sh),
];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Found {
    pub file: PathBuf,
    pub format: Format,
    /// The project root: whatever the file declares, else the file's directory.
    pub root: PathBuf,
    /// Set when a directory holds both formats. YAML is read and this says so,
    /// rather than choosing silently.
    pub shadowed: Option<PathBuf>,
}

/// The config in exactly this directory, if there is one.
pub fn in_dir(dir: &Path) -> Option<Found> {
    let mut hit: Option<Found> = None;
    let mut shadowed = None;
    for (name, format) in CONFIG_NAMES {
        let path = dir.join(name);
        if !path.is_file() {
            continue;
        }
        match hit {
            // A later name is a lower-priority format that is now shadowed.
            Some(_) => shadowed = shadowed.or(Some(path)),
            None => {
                hit = Some(Found {
                    root: declared_root(&path).unwrap_or_else(|| dir.to_path_buf()),
                    file: path,
                    format: *format,
                    shadowed: None,
                })
            }
        }
    }
    hit.map(|f| Found { shadowed, ..f })
}

/// Walk up from `start` looking for a config, so `pitcrew` works from any
/// subdirectory of a project.
pub fn walk_up(start: &Path) -> Option<Found> {
    let mut dir = Some(start);
    while let Some(d) = dir {
        if let Some(found) = in_dir(d) {
            return Some(found);
        }
        dir = d.parent();
    }
    None
}

/// The root a config declares, read textually.
///
/// Deliberately not a parse: this runs before the file is loaded, and for the
/// bash format there is nothing to parse at all — it is a shell script. Only a
/// plain literal is understood, which is what every config that sets this
/// writes.
pub fn declared_root(file: &Path) -> Option<PathBuf> {
    let text = std::fs::read_to_string(file).ok()?;
    let dir = file.parent()?;
    for line in text.lines() {
        let line = line.trim();
        // `continue`, not `?`: a declaration is rarely the first line of a
        // commented config, and bailing on the first line that is not one
        // would find it only by accident.
        let Some(raw) = line
            .strip_prefix("root:")
            .or_else(|| line.strip_prefix("PITCREW_ROOT="))
        else {
            continue;
        };
        let raw = raw.trim();
        if raw.is_empty() || raw.starts_with('#') {
            continue;
        }
        let raw = raw.trim_matches(|c| c == '"' || c == '\'');
        if raw.is_empty() {
            continue;
        }
        let p = Path::new(raw);
        return Some(if p.is_absolute() {
            p.to_path_buf()
        } else {
            // Normalised so a `root: ..` reads as a directory rather than as a
            // path with a `..` still in the middle of it.
            dir.join(p).canonicalize().unwrap_or_else(|_| dir.join(p))
        });
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp() -> PathBuf {
        let d = std::env::temp_dir().join(format!(
            "pitcrew-find-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn a_config_is_found_in_its_own_directory() {
        let d = tmp();
        std::fs::write(d.join("pitcrew.yaml"), "name: x\n").unwrap();
        let f = in_dir(&d).expect("found");
        assert_eq!(f.format, Format::Yaml);
        assert_eq!(f.root, d);
    }

    /// Running from a subdirectory is the normal case, not the exception.
    #[test]
    fn a_config_is_found_by_walking_up() {
        let d = tmp();
        let deep = d.join("a/b/c");
        std::fs::create_dir_all(&deep).unwrap();
        std::fs::write(d.join("pitcrew.yaml"), "name: x\n").unwrap();
        assert_eq!(walk_up(&deep).expect("found").file, d.join("pitcrew.yaml"));
    }

    /// Where a directory holds both formats, YAML is read — and the other one
    /// is reported rather than silently ignored.
    #[test]
    fn yaml_wins_over_sh_and_says_so() {
        let d = tmp();
        std::fs::write(d.join("pitcrew.yaml"), "name: x\n").unwrap();
        std::fs::write(d.join("pitcrew.config.sh"), "PITCREW_APPS=(a)\n").unwrap();
        let f = in_dir(&d).expect("found");
        assert_eq!(f.format, Format::Yaml);
        assert_eq!(f.shadowed, Some(d.join("pitcrew.config.sh")));
    }

    /// The root must be readable before the file is loaded, because everything
    /// in the file resolves against it.
    #[test]
    fn the_declared_root_is_readable_without_loading_the_file() {
        let d = tmp();
        std::fs::create_dir_all(d.join("sub")).unwrap();
        std::fs::write(d.join("sub/pitcrew.yaml"), "root: ..\nname: x\n").unwrap();
        let f = in_dir(&d.join("sub")).expect("found");
        assert_eq!(f.root, d.canonicalize().unwrap());
    }

    /// A declaration is rarely the first line of a real config — it sits under
    /// a comment header. Finding it only when it happens to be first is the
    /// same as not finding it.
    #[test]
    fn a_declared_root_is_found_below_comments_and_other_keys() {
        let d = tmp();
        std::fs::create_dir_all(d.join("sub")).unwrap();
        std::fs::write(
            d.join("sub/pitcrew.yaml"),
            "# a header comment\nname: x\nemoji: \"z\"\n\nroot: ..\n",
        )
        .unwrap();
        assert_eq!(
            in_dir(&d.join("sub")).unwrap().root,
            d.canonicalize().unwrap()
        );
    }

    #[test]
    fn no_declared_root_means_the_files_own_directory() {
        let d = tmp();
        std::fs::write(d.join("pitcrew.yaml"), "name: x\n").unwrap();
        assert_eq!(in_dir(&d).unwrap().root, d);
    }

    /// It works for the bash format too, which cannot be parsed at all.
    #[test]
    fn a_declared_root_is_read_out_of_a_sh_config_as_well() {
        let d = tmp();
        std::fs::create_dir_all(d.join("sub")).unwrap();
        std::fs::write(
            d.join("sub/pitcrew.config.sh"),
            "PITCREW_ROOT=\"..\"\nPITCREW_APPS=(a)\n",
        )
        .unwrap();
        let f = in_dir(&d.join("sub")).expect("found");
        assert_eq!(f.format, Format::Sh);
        assert_eq!(f.root, d.canonicalize().unwrap());
    }

    #[test]
    fn nothing_is_found_where_there_is_nothing() {
        assert!(in_dir(&tmp()).is_none());
    }
}
