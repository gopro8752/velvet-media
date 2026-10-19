//! Shared SQLite handle. One connection behind a mutex — sync/handoff/intro
//! traffic is tiny and every op is sub-millisecond, so a brief lock (never held
//! across `.await`) is simpler and faster than a pool here. WAL keeps the
//! background intro worker from blocking app reads.

use std::sync::{Arc, Mutex};

use rusqlite::Connection;

/// The shared DB handle passed to sync handlers and the intro worker.
pub type Db = Arc<Mutex<Connection>>;

pub fn open(path: &str) -> anyhow::Result<Db> {
    if let Some(parent) = std::path::Path::new(path).parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent).ok();
        }
    }
    let conn = Connection::open(path)?;
    conn.pragma_update(None, "journal_mode", "WAL")?;
    conn.pragma_update(None, "busy_timeout", 5000)?;
    Ok(Arc::new(Mutex::new(conn)))
}
