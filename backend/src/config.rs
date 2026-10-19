//! Configuration: usenet provider + indexers + server ports. Loaded from a TOML
//! file (default `./velvet.toml`, or $VELVET_CONFIG) whose secrets never enter
//! git — `.gitignore` covers `velvet.toml`. Env vars override individual fields
//! so a container can be configured without a mounted file.

use serde::Deserialize;
use std::path::Path;

#[derive(Debug, Clone, Deserialize)]
pub struct Config {
    /// One or more usenet providers (`[[providers]]`). Order = failover priority
    /// (first is primary); their connection budgets are pooled together for
    /// throughput so several high-bitrate streams can run at once.
    pub providers: Vec<Provider>,
    #[serde(default)]
    pub indexers: Vec<Indexer>,
    #[serde(default = "default_bind")]
    pub bind: String,
    #[serde(default = "default_port")]
    pub port: u16,
    /// Public base URL the resolver embeds in stream links (what the app hits).
    #[serde(default)]
    pub public_base_url: Option<String>,
    /// Optional bearer shared with the apps (sync/handoff/report_play), mirrors
    /// the old SYNC_TOKEN. Empty = open.
    #[serde(default)]
    pub token: String,
    #[serde(default = "default_db")]
    pub db_path: String,
    #[serde(default)]
    pub category_ai: CategoryAi,
    #[serde(default)]
    pub live_tv: LiveTv,
    #[serde(default)]
    pub live_sports: LiveSports,
}

#[derive(Debug, Clone, Deserialize, Default)]
#[serde(default)]
pub struct LiveSports {
    pub enabled: bool,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct LiveTv {
    pub enabled: bool,
    pub source_name: String,
    pub upstream_url: String,
    pub lineup_path: String,
    pub guide_enabled: bool,
    /// Optional private EPlusTV origin. Spectrum remains the lineup and fallback.
    pub direct_tve_url: Option<String>,
    /// Optional private native Spectrum sidecar. Replaces Live TV capture when configured.
    pub native_spectrum_url: Option<String>,
}

impl Default for LiveTv {
    fn default() -> Self {
        Self {
            enabled: false,
            source_name: "Spectrum".into(),
            upstream_url: "http://velvet-prismcast:5589".into(),
            lineup_path: "/playlist?service=spectrum".into(),
            guide_enabled: false,
            direct_tve_url: None,
            native_spectrum_url: None,
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct CategoryAi {
    pub enabled: bool,
    pub codex_path: String,
    pub codex_home: Option<String>,
    pub model: Option<String>,
}

impl Default for CategoryAi {
    fn default() -> Self {
        Self { enabled: false, codex_path: "codex".into(), codex_home: None, model: None }
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct Provider {
    #[serde(default)]
    pub name: String,
    pub host: String,
    #[serde(default = "default_nntp_port")]
    pub port: u16,
    #[serde(default = "default_true")]
    pub tls: bool,
    pub username: String,
    pub password: String,
    /// Max simultaneous NNTP connections (provider-enforced; e.g. 30–50).
    #[serde(default = "default_conns")]
    pub max_connections: usize,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Indexer {
    pub name: String,
    /// Newznab base, e.g. https://api.nzbgeek.info
    pub url: String,
    pub api_key: String,
}

fn default_bind() -> String { "0.0.0.0".into() }
fn default_port() -> u16 { 8799 }
fn default_nntp_port() -> u16 { 563 }
fn default_true() -> bool { true }
fn default_conns() -> usize { 30 }
fn default_db() -> String { "/data/velvet.db".into() }

#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    #[error("reading {0}: {1}")]
    Io(String, std::io::Error),
    #[error("parsing config: {0}")]
    Parse(#[from] toml::de::Error),
}

impl Config {
    pub fn load() -> Result<Config, ConfigError> {
        let path = std::env::var("VELVET_CONFIG").unwrap_or_else(|_| "velvet.toml".into());
        let mut cfg = Config::from_file(&path)?;
        cfg.apply_env_overrides();
        Ok(cfg)
    }

    pub fn from_file(path: &str) -> Result<Config, ConfigError> {
        let text = std::fs::read_to_string(Path::new(path))
            .map_err(|e| ConfigError::Io(path.to_string(), e))?;
        Ok(toml::from_str(&text)?)
    }

    fn apply_env_overrides(&mut self) {
        if let Ok(v) = std::env::var("VELVET_TOKEN") { self.token = v; }
        if let Ok(v) = std::env::var("VELVET_PUBLIC_BASE_URL") { self.public_base_url = Some(v); }
        if let Ok(v) = std::env::var("VELVET_DB") { self.db_path = v; }
        // Env overrides target the PRIMARY provider (container single-provider case).
        if let Some(p) = self.providers.first_mut() {
            if let Ok(v) = std::env::var("NNTP_HOST") { p.host = v; }
            if let Ok(v) = std::env::var("NNTP_USER") { p.username = v; }
            if let Ok(v) = std::env::var("NNTP_PASS") { p.password = v; }
            if let Some(v) = std::env::var("NNTP_CONNS").ok().and_then(|s| s.parse().ok()) {
                p.max_connections = v;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn public_example_requires_runtime_credentials() {
        let cfg: Config = toml::from_str(include_str!("../velvet.toml.example")).unwrap();
        assert!(cfg.token.is_empty());
        assert!(cfg.providers.iter().all(|p| p.username.is_empty() && p.password.is_empty()));
        assert!(cfg.indexers.iter().all(|i| i.api_key.is_empty()));
        assert!(!cfg.category_ai.enabled && !cfg.live_tv.enabled && !cfg.live_sports.enabled);
        assert!(cfg.live_tv.direct_tve_url.is_none());
        assert!(cfg.live_tv.native_spectrum_url.is_none());
        assert_eq!(cfg.public_base_url.as_deref(), Some("https://velvet.example.com"));
    }

    #[test]
    fn parses_full_config() {
        let toml = r#"
            port = 8799
            public_base_url = "https://velvet.example.com"
            token = "sekret"

            [[providers]]
            name = "Main"
            host = "news.example.com"
            port = 563
            username = "user"
            password = "pw"
            max_connections = 40

            [[indexers]]
            name = "NZBGeek"
            url = "https://api.nzbgeek.info"
            api_key = "AAA"

            [[indexers]]
            name = "DrunkenSlug"
            url = "https://api.drunkenslug.com"
            api_key = "BBB"
        "#;
        let cfg: Config = toml::from_str(toml).unwrap();
        assert_eq!(cfg.providers.len(), 1);
        assert_eq!(cfg.providers[0].host, "news.example.com");
        assert_eq!(cfg.providers[0].max_connections, 40);
        assert!(cfg.providers[0].tls); // defaulted true
        assert_eq!(cfg.indexers.len(), 2);
        assert_eq!(cfg.indexers[1].name, "DrunkenSlug");
        assert_eq!(cfg.port, 8799);
    }
}
