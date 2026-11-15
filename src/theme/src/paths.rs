use std::env;
use std::fs;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};

use crate::error::{Error, Result};

/// Where Nova and the user keep theme data.
pub struct Paths {
    /// Nova's read-only data: themes/, templates/, wordmark/.
    pub share: PathBuf,
    /// The user's themes/, templates/ and backgrounds/.
    pub config: PathBuf,
    /// current/ (the applied theme and background), rendered/, backgrounds/.
    pub state: PathBuf,
    pub cache: PathBuf,
    /// Locks and short-lived files.
    pub runtime: PathBuf,
}

fn var(name: &str) -> Option<PathBuf> {
    env::var_os(name)
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
}

extern "C" {
    fn geteuid() -> u32;
}

/// `$XDG_RUNTIME_DIR/nova` when that directory is this user's own, as the XDG
/// spec requires of it. `sudo -u`, `su` and `runuser` keep the caller's, which
/// this user cannot write to; `state/run` stands in then, as it does without
/// one.
fn runtime_dir(xdg: Option<PathBuf>, state: &Path, uid: u32) -> PathBuf {
    xdg.filter(|dir| fs::metadata(dir).is_ok_and(|m| m.is_dir() && m.uid() == uid))
        .map(|dir| dir.join("nova"))
        .unwrap_or_else(|| state.join("run"))
}

impl Paths {
    pub fn from_env() -> Result<Paths> {
        let home = var("HOME").ok_or_else(|| Error::new("HOME is not set"))?;
        let xdg = |name: &str, default: &str| {
            var(name).unwrap_or_else(|| home.join(default)).join("nova")
        };
        let state = xdg("XDG_STATE_HOME", ".local/state");
        Ok(Paths {
            share: var("NOVA_PATH").unwrap_or_else(|| PathBuf::from("/usr/share/nova")),
            config: xdg("XDG_CONFIG_HOME", ".config"),
            cache: xdg("XDG_CACHE_HOME", ".cache"),
            // SAFETY: geteuid has no preconditions and cannot fail.
            runtime: runtime_dir(var("XDG_RUNTIME_DIR"), &state, unsafe { geteuid() }),
            state,
        })
    }

    pub fn current(&self) -> PathBuf {
        self.state.join("current")
    }

    /// A symlink to the applied theme's rendered directory.
    pub fn theme(&self) -> PathBuf {
        self.current().join("theme")
    }

    /// A symlink to the background image in use.
    pub fn background(&self) -> PathBuf {
        self.current().join("background")
    }

    pub fn rendered(&self) -> PathBuf {
        self.state.join("rendered")
    }

    pub fn lock_file(&self) -> PathBuf {
        self.runtime.join("theme.lock")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_runtime_dir_must_be_the_users_own() {
        let dir = env::temp_dir();
        let owner = fs::metadata(&dir).unwrap().uid();
        let state = Path::new("/state/nova");
        assert_eq!(
            runtime_dir(Some(dir.clone()), state, owner),
            dir.join("nova")
        );
        assert_eq!(
            runtime_dir(Some(dir), state, owner.wrapping_add(1)),
            state.join("run")
        );
        assert_eq!(
            runtime_dir(Some("/nonexistent".into()), state, owner),
            state.join("run")
        );
        assert_eq!(runtime_dir(None, state, owner), state.join("run"));
    }
}
