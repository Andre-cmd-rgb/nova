use std::env;
use std::path::PathBuf;

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
            runtime: var("XDG_RUNTIME_DIR")
                .map(|d| d.join("nova"))
                .unwrap_or_else(|| state.join("run")),
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
