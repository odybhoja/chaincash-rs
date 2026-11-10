use std::path::{Path, PathBuf};
use std::sync::Arc;

use chaincash_offchain::node::node_from_config;
use chaincash_predicate::predicates::Predicate;
use chaincash_server::Server;
use chaincash_services::{scanner::start_scanner, ServerState};
use chaincash_store::{ChainCashStore, Update};
use config::{Environment, File, FileFormat};
use directories::BaseDirs;
use thiserror::Error;
use tracing::info;

#[derive(Error, Debug)]
pub enum Error {
    #[error(transparent)]
    Store(#[from] chaincash_store::Error),

    #[error(transparent)]
    Server(#[from] chaincash_server::Error),

    #[error(transparent)]
    Node(#[from] chaincash_offchain::node::NodeError),

    #[error("Failed to load chaincash predicates specified in config file")]
    LoadPredicate(#[from] chaincash_predicate::Error),

    #[error(transparent)]
    Config(#[from] config::ConfigError),
}

#[derive(serde::Deserialize, Debug)]
pub struct ChainCashConfig {
    server: chaincash_server::Config,
    store: chaincash_store::Config,
    node: chaincash_offchain::node::Config,
    acceptance: chaincash_predicate::Config,
}

/// Default configuration, compiled into the binary so it runs from any directory.
const DEFAULT_CONFIG: &str = include_str!("../../../config/default.toml");

/// Name of the user configuration file inside [`config_dir`].
pub const CONFIG_FILE_NAME: &str = "config.toml";

/// Directory holding the user's `chaincash` configuration.
///
/// `$XDG_CONFIG_HOME/chaincash` if `XDG_CONFIG_HOME` is set to an absolute path,
/// otherwise `~/.config/chaincash` (on every platform, including macOS and Windows).
pub fn config_dir() -> Option<PathBuf> {
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .or_else(|| BaseDirs::new().map(|d| d.home_dir().join(".config")))?;

    Some(base.join("chaincash"))
}

impl ChainCashConfig {
    /// Loads configuration from the following sources, later sources overriding earlier ones:
    ///
    /// 1. built-in defaults (`config/default.toml` in the repository)
    /// 2. `~/.config/chaincash/config.toml` (see [`config_dir`])
    /// 3. `./config/local.toml` relative to the current directory
    /// 4. `CHAINCASH_*` environment variables, e.g. `CHAINCASH_NODE.API_KEY`
    pub fn new() -> Result<Self, Error> {
        Self::from_sources(
            config_dir().map(|d| d.join(CONFIG_FILE_NAME)),
            Path::new("config/local"),
        )
    }

    fn from_sources(user_config: Option<PathBuf>, local_config: &Path) -> Result<Self, Error> {
        let mut builder =
            config::Config::builder().add_source(File::from_str(DEFAULT_CONFIG, FileFormat::Toml));

        if let Some(path) = user_config {
            if path.is_file() {
                info!("loading config from {}", path.display());
                builder = builder.add_source(File::from(path));
            }
        }

        let c = builder
            .add_source(File::from(local_config).required(false))
            .add_source(Environment::with_prefix("chaincash"))
            .build()?;

        Ok(c.try_deserialize()?)
    }
}

/// Facade class encompassing all components that make up the `chaincash` application.
pub struct ChainCashApp {
    config: ChainCashConfig,
}

impl ChainCashApp {
    pub fn new(config: ChainCashConfig) -> Self {
        Self { config }
    }

    pub async fn run(&self) -> Result<(), Error> {
        let store = ChainCashStore::open(&self.config.store.url)?;

        if store.has_updates()? {
            store.update()?;
        }

        let predicates = self
            .config
            .acceptance
            .predicates
            .iter()
            .map(Predicate::from_file)
            .collect::<Result<Vec<_>, _>>()?;

        info!("loaded {} predicates from files", predicates.len());

        let listener = listenfd::ListenFd::from_env()
            .take_tcp_listener(0)
            .unwrap()
            .unwrap_or_else(|| {
                std::net::TcpListener::bind(format!(
                    "{}:{}",
                    self.config.server.url, self.config.server.port
                ))
                .unwrap()
            });

        let node = node_from_config(&self.config.node)?;

        let state = Arc::new(ServerState::new(node, store, predicates));
        start_scanner(state.clone()).await.unwrap();
        Ok(Server::serve(listener, state).await?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("chaincash-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn loads_builtin_defaults_without_any_files() {
        let dir = temp_dir("defaults");
        let cfg =
            ChainCashConfig::from_sources(Some(dir.join("missing.toml")), &dir.join("missing"))
                .unwrap();

        assert_eq!(cfg.server.port, 8080);
        assert_eq!(cfg.store.url, "chaincash.sqlite");
        assert_eq!(
            cfg.acceptance.predicates,
            vec![PathBuf::from("config/predicates/example.toml")]
        );
    }

    #[test]
    fn user_config_overrides_defaults() {
        let dir = temp_dir("user");
        let user_config = dir.join(CONFIG_FILE_NAME);
        std::fs::write(
            &user_config,
            "[store]\nurl = '/data/chaincash.sqlite'\n\n[acceptance]\npredicates = ['/cfg/predicates/example.toml']\n",
        )
        .unwrap();

        let cfg = ChainCashConfig::from_sources(Some(user_config), &dir.join("missing")).unwrap();

        assert_eq!(cfg.store.url, "/data/chaincash.sqlite");
        assert_eq!(
            cfg.acceptance.predicates,
            vec![PathBuf::from("/cfg/predicates/example.toml")]
        );
        // values not present in the user config keep their defaults
        assert_eq!(cfg.server.port, 8080);
    }

    #[test]
    fn local_config_overrides_user_config() {
        let dir = temp_dir("local");
        let user_config = dir.join(CONFIG_FILE_NAME);
        std::fs::write(&user_config, "[server]\nport = 9000\n").unwrap();
        std::fs::write(dir.join("local.toml"), "[server]\nport = 9001\n").unwrap();

        let cfg = ChainCashConfig::from_sources(Some(user_config), &dir.join("local")).unwrap();

        assert_eq!(cfg.server.port, 9001);
    }
}
