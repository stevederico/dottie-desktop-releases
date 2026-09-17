//! Agent bearer token reader — mirrors `agent_token.js` (60s cache).

use std::sync::Mutex;
use std::time::{Duration, Instant};

use crate::paths;

struct Cache {
    token: Option<String>,
    at: Option<Instant>,
}

static CACHE: Mutex<Cache> = Mutex::new(Cache {
    token: None,
    at: None,
});

pub fn read_agent_token() -> Result<String, String> {
    let path = paths::agent_token_path();
    let raw = std::fs::read_to_string(&path)
        .map_err(|e| format!("read {}: {e}", path.display()))?;
    Ok(raw.trim().to_string())
}

pub fn read_agent_token_cached() -> Result<String, String> {
    read_agent_token_cached_ttl(Duration::from_secs(60))
}

pub fn read_agent_token_cached_ttl(ttl: Duration) -> Result<String, String> {
    let mut guard = CACHE.lock().map_err(|_| "token cache poisoned".to_string())?;
    if let (Some(tok), Some(at)) = (&guard.token, guard.at) {
        if at.elapsed() <= ttl {
            return Ok(tok.clone());
        }
    }
    let tok = read_agent_token()?;
    guard.token = Some(tok.clone());
    guard.at = Some(Instant::now());
    Ok(tok)
}

pub fn read_api_token() -> Result<String, String> {
    let path = paths::api_token_path();
    let raw = std::fs::read_to_string(&path)
        .map_err(|e| format!("read {}: {e}", path.display()))?;
    Ok(raw.trim().to_string())
}
