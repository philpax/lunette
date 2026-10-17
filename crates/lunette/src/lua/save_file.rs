//! `lunette.saveFile`: an atomic write of one file in a directory, for settings and
//! saved state.
//!
//! The contents go to a temporary file beside the target, which is flushed and
//! renamed over the target, so a reader sees the old file or the new one and never a
//! truncated one. `lovr.filesystem.write` cannot rename, so Lua writes persistent
//! files through this.

use std::{
    fmt,
    fs::{self, File},
    io::{self, Write},
    path::{Path, PathBuf},
};

/// A failed atomic write, naming the file and the step that failed.
#[derive(Debug)]
pub enum SaveFileError {
    /// The name is empty, names a directory entry such as `..`, or holds a separator
    /// or a NUL byte, so it would not stay a file directly inside the directory.
    Name(String),
    /// The directory is not an absolute path to an existing directory.
    Directory(PathBuf),
    /// Writing, flushing, or renaming failed.
    Io {
        step: &'static str,
        path: PathBuf,
        source: io::Error,
    },
}

impl fmt::Display for SaveFileError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Name(name) => write!(
                formatter,
                "save file: {name:?} is not a file name inside the directory"
            ),
            Self::Directory(path) => write!(
                formatter,
                "save file: {} is not an absolute path to a directory",
                path.display()
            ),
            Self::Io { step, path, source } => write!(
                formatter,
                "save file: could not {step} {}: {source}",
                path.display()
            ),
        }
    }
}

impl std::error::Error for SaveFileError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Io { source, .. } => Some(source),
            Self::Name(_) | Self::Directory(_) => None,
        }
    }
}

/// Writes `contents` to `name` inside `directory`, replacing any file there at once.
pub fn save(directory: &Path, name: &str, contents: &[u8]) -> Result<(), SaveFileError> {
    if name.is_empty() || name == "." || name == ".." || name.contains(['/', '\\', '\0']) {
        return Err(SaveFileError::Name(name.to_owned()));
    }
    if !directory.is_absolute() || !directory.is_dir() {
        return Err(SaveFileError::Directory(directory.to_path_buf()));
    }
    let target = directory.join(name);
    // The process id keeps two sessions sharing a save directory from writing one
    // temporary file.
    let temporary = directory.join(format!(".{name}.{}.tmp", std::process::id()));
    let io = |step: &'static str, path: &Path| {
        let path = path.to_path_buf();
        move |source| SaveFileError::Io { step, path, source }
    };
    let written = File::create(&temporary)
        .map_err(io("create", &temporary))
        .and_then(|mut file| {
            file.write_all(contents).map_err(io("write", &temporary))?;
            file.sync_all().map_err(io("flush", &temporary))
        });
    if let Err(error) = written {
        // The temporary file is ours; a failure to remove it leaves a stray file but
        // the target intact, and the write's own error is the one to report.
        let _ = fs::remove_file(&temporary);
        return Err(error);
    }
    if let Err(error) = fs::rename(&temporary, &target).map_err(io("rename over", &target)) {
        let _ = fs::remove_file(&temporary);
        return Err(error);
    }
    sync_directory(directory)
}

/// Flushes the directory, so the rename itself survives a power loss.
#[cfg(unix)]
fn sync_directory(directory: &Path) -> Result<(), SaveFileError> {
    File::open(directory)
        .and_then(|handle| handle.sync_all())
        .map_err(|source| SaveFileError::Io {
            step: "flush",
            path: directory.to_path_buf(),
            source,
        })
}

#[cfg(not(unix))]
fn sync_directory(_directory: &Path) -> Result<(), SaveFileError> {
    Ok(())
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "Tests fail loudly on a broken fixture; that is the assertion."
)]
mod tests {
    use pretty_assertions::assert_eq;

    use super::*;

    #[test]
    fn a_save_replaces_the_file_and_leaves_no_temporary_file() {
        let directory = tempfile::tempdir().expect("a temporary directory");
        save(directory.path(), "settings", b"first").expect("the first save");
        save(directory.path(), "settings", b"second").expect("the second save");
        assert_eq!(
            fs::read(directory.path().join("settings")).expect("the saved file"),
            b"second"
        );
        let names: Vec<_> = fs::read_dir(directory.path())
            .expect("the directory")
            .map(|entry| entry.expect("an entry").file_name())
            .collect();
        assert_eq!(names, vec!["settings"]);
    }

    #[test]
    fn names_that_leave_the_directory_are_rejected() {
        let directory = tempfile::tempdir().expect("a temporary directory");
        for name in [
            "",
            ".",
            "..",
            "../escape",
            "nested/file",
            "back\\slash",
            "nul\0",
        ] {
            assert!(
                matches!(
                    save(directory.path(), name, b"x"),
                    Err(SaveFileError::Name(_))
                ),
                "{name:?} is rejected"
            );
        }
        assert_eq!(
            fs::read_dir(directory.path())
                .expect("the directory")
                .count(),
            0,
            "nothing was written"
        );
    }

    #[test]
    fn a_missing_or_relative_directory_is_rejected() {
        let directory = tempfile::tempdir().expect("a temporary directory");
        let missing = directory.path().join("missing");
        assert!(matches!(
            save(&missing, "settings", b"x"),
            Err(SaveFileError::Directory(_))
        ));
        assert!(matches!(
            save(Path::new("relative"), "settings", b"x"),
            Err(SaveFileError::Directory(_))
        ));
    }

    #[test]
    fn a_failed_write_keeps_the_previous_file() {
        let directory = tempfile::tempdir().expect("a temporary directory");
        save(directory.path(), "settings", b"kept").expect("the first save");
        // A directory where the temporary file would go makes its creation fail.
        fs::create_dir(
            directory
                .path()
                .join(format!(".settings.{}.tmp", std::process::id())),
        )
        .expect("the blocking directory");
        assert!(save(directory.path(), "settings", b"lost").is_err());
        assert_eq!(
            fs::read(directory.path().join("settings")).expect("the kept file"),
            b"kept"
        );
    }
}
