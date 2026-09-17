//! `~/.dottie` filesystem paths — mirrors `paths.js`.

use std::path::PathBuf;

pub fn dottie_dir() -> PathBuf {
    dirs_home().join(".dottie")
}

pub fn agent_db_path() -> PathBuf {
    dottie_dir().join("agent.db")
}

pub fn config_path() -> PathBuf {
    dottie_dir().join("config.json")
}

pub fn agent_token_path() -> PathBuf {
    dottie_dir().join("agent_token")
}

pub fn api_token_path() -> PathBuf {
    dottie_dir().join("api_token")
}

pub fn preferences_path() -> PathBuf {
    dottie_dir().join("preferences.json")
}

pub fn user_memory_path() -> PathBuf {
    dottie_dir().join("dottie-memory.md")
}

pub fn logs_dir() -> PathBuf {
    dottie_dir().join("logs")
}

pub fn gateway_log_path() -> PathBuf {
    logs_dir().join("gateway.log")
}

pub fn gateway_pid_path() -> PathBuf {
    dottie_dir().join("gateway.pid")
}

pub fn workspace_dir() -> PathBuf {
    dottie_dir().join("workspace")
}

fn dirs_home() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/"))
}
