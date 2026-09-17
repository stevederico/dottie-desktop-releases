//! Read/write ~/.dottie/config.json + preferences.json.

use crate::json::{self, Value};
use crate::paths;

pub fn read_config() -> Value {
    read_json_file(&paths::config_path()).unwrap_or_else(|_| Value::obj())
}

pub fn write_config(v: &Value) -> Result<(), String> {
    write_json_file(&paths::config_path(), v)
}

pub fn read_preferences() -> Value {
    let mut defaults = Value::obj();
    defaults.insert("agentName", Value::str("Dottie"));
    defaults.insert("agentPersonality", Value::str(""));
    match read_json_file(&paths::preferences_path()) {
        Ok(v) => {
            if let Some(obj) = v.as_object() {
                for (k, val) in obj {
                    defaults.insert(k.clone(), val.clone());
                }
            }
            defaults
        }
        Err(_) => defaults,
    }
}

pub fn write_preferences(v: &Value) -> Result<(), String> {
    write_json_file(&paths::preferences_path(), v)
}

pub fn read_user_memory() -> String {
    let path = paths::user_memory_path();
    std::fs::read_to_string(&path).unwrap_or_else(|_| {
        "# Dottie Memory\n\nThings to remember about the user.\n".to_string()
    })
}

pub fn write_user_memory(content: &str) -> Result<(), String> {
    if let Some(parent) = paths::user_memory_path().parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    std::fs::write(paths::user_memory_path(), content).map_err(|e| e.to_string())
}

fn read_json_file(path: &std::path::Path) -> Result<Value, String> {
    let raw = std::fs::read_to_string(path).map_err(|e| e.to_string())?;
    json::parse(&raw)
}

fn write_json_file(path: &std::path::Path, v: &Value) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    std::fs::write(path, v.stringify()).map_err(|e| e.to_string())
}
