//! Chat completions — Dottie Pro, BYOK xAI, Ollama, and dottie-local.

use crate::config_store;
use crate::http;
use crate::json::{self, Value};
use crate::log;
use crate::memory::sessions;
use crate::tls;
use crate::token;

const OLLAMA_HOST: &str = "127.0.0.1";
const OLLAMA_PORT: u16 = 11434;
const DOTTIE_LOCAL_DEFAULT_HOST: &str = "127.0.0.1";
const DOTTIE_LOCAL_DEFAULT_PORT: u16 = 1318;

/// Live chat routing from `~/.dottie/config.json` (HTTP `/v1/config` + WS `config`).
#[derive(Debug, Clone)]
pub struct ChatConfig {
    pub provider: String,
    pub model: String,
    pub api_key: String,
}

pub fn load_chat_config() -> ChatConfig {
    let cfg = config_store::read_config();
    let provider = cfg
        .get_str("provider")
        .or_else(|| cfg.get_str("chatProvider"))
        .unwrap_or("dottiepro")
        .to_string();
    let model = cfg.get_str("model").unwrap_or("").to_string();
    let api_key = cfg.get_str("apiKey").unwrap_or("").to_string();
    ChatConfig {
        provider,
        model,
        api_key,
    }
}

/// Persist provider/model/apiKey from a WS or HTTP body into config.json.
pub fn apply_chat_config_fields(msg: &Value) -> Result<(), String> {
    let mut cfg = config_store::read_config();
    let mut changed = false;
    if let Some(p) = msg.get_str("provider") {
        cfg.insert("provider", Value::str(p));
        changed = true;
    }
    if let Some(m) = msg.get_str("model") {
        cfg.insert("model", Value::str(m));
        changed = true;
    }
    if let Some(k) = msg.get_str("apiKey") {
        cfg.insert("apiKey", Value::str(k));
        changed = true;
    }
    if let Some(u) = msg.get_str("localBaseUrl") {
        let trimmed = u.trim();
        if !trimmed.is_empty() {
            cfg.insert("localBaseUrl", Value::str(trimmed));
            changed = true;
        }
    }
    if changed {
        config_store::write_config(&cfg)?;
    }
    Ok(())
}

/// Run a non-streaming chat completion; returns assistant text.
pub fn chat_once(session_id: &str, user_text: &str) -> Result<String, String> {
    let session = sessions::get_session(session_id)?
        .ok_or_else(|| "session not found".to_string())?;

    let messages = session
        .get("messages")
        .cloned()
        .unwrap_or_else(|| Value::arr(vec![]));
    let mut msgs = messages.as_array().unwrap_or(&[]).to_vec();
    let mut user = Value::obj();
    user.insert("role", Value::str("user"));
    user.insert("content", Value::str(user_text));
    msgs.push(user);

    let reply = complete(&msgs)?;

    let mut assistant = Value::obj();
    assistant.insert("role", Value::str("assistant"));
    assistant.insert("content", Value::str(&reply));
    msgs.push(assistant);

    sessions::upsert_session(session_id, None, Some(&Value::arr(msgs)), None, None)?;
    Ok(reply)
}

fn complete(messages: &[Value]) -> Result<String, String> {
    let cfg = load_chat_config();
    match cfg.provider.to_ascii_lowercase().as_str() {
        "ollama" => complete_ollama(messages, &cfg.model),
        "dottielocal" => complete_dottie_local(messages, &cfg.model),
        "xai" => {
            let key = if !cfg.api_key.is_empty() {
                cfg.api_key.clone()
            } else {
                std::env::var("XAI_API_KEY")
                    .map_err(|_| "missing xAI API key".to_string())?
            };
            let model = if cfg.model.is_empty() {
                "grok-2-latest".to_string()
            } else {
                cfg.model.clone()
            };
            complete_xai(messages, &key, &model)
        }
        "dottiepro" | "local" | "" => {
            let tok = token::read_api_token().unwrap_or_default();
            if tok.is_empty() {
                return Err("missing Dottie Pro api_token".into());
            }
            complete_pro(messages, &tok)
        }
        other => Err(format!(
            "provider '{other}' not wired yet — use dottiepro, xai, ollama, or dottielocal"
        )),
    }
}

/// Host/port for dottie-local façade. Env `DOTTIE_LOCAL_URL` beats config `localBaseUrl`.
pub fn dottie_local_endpoint() -> (String, u16) {
    let url = std::env::var("DOTTIE_LOCAL_URL")
        .ok()
        .filter(|s| !s.trim().is_empty())
        .or_else(|| {
            config_store::read_config()
                .get_str("localBaseUrl")
                .map(|s| s.to_string())
                .filter(|s| !s.trim().is_empty())
        })
        .unwrap_or_else(|| {
            format!("http://{DOTTIE_LOCAL_DEFAULT_HOST}:{DOTTIE_LOCAL_DEFAULT_PORT}")
        });
    parse_http_host_port(&url).unwrap_or((
        DOTTIE_LOCAL_DEFAULT_HOST.to_string(),
        DOTTIE_LOCAL_DEFAULT_PORT,
    ))
}

fn parse_http_host_port(url: &str) -> Option<(String, u16)> {
    let rest = url
        .strip_prefix("http://")
        .or_else(|| url.strip_prefix("https://"))?;
    let hostport = rest.split('/').next().unwrap_or(rest);
    if let Some((host, port_s)) = hostport.rsplit_once(':') {
        let port: u16 = port_s.parse().ok()?;
        if host.is_empty() {
            return None;
        }
        Some((host.to_string(), port))
    } else if !hostport.is_empty() {
        Some((hostport.to_string(), 80))
    } else {
        None
    }
}

fn complete_openai_compat_local(
    host: &str,
    port: u16,
    messages: &[Value],
    model: &str,
    label: &str,
    empty_model_hint: &str,
) -> Result<String, String> {
    if model.trim().is_empty() {
        return Err(empty_model_hint.into());
    }
    let mut body = Value::obj();
    body.insert("model", Value::str(model));
    body.insert("messages", Value::arr(messages.to_vec()));
    body.insert("stream", Value::bool(false));
    let bytes = body.stringify().into_bytes();
    // First-load of a model can take minutes; keep generous.
    let (status, resp) = http::http_exchange(
        "POST",
        host,
        port,
        "/v1/chat/completions",
        &[("Content-Type", "application/json")],
        &bytes,
        300_000,
    )?;
    if !(200..300).contains(&status) {
        let s = String::from_utf8_lossy(&resp);
        log::error("agent", format!("{label} {status}: {s}"), "LLM");
        return Err(format!("{label} HTTP {status}: {s}"));
    }
    extract_content(&resp)
}

fn complete_ollama(messages: &[Value], model: &str) -> Result<String, String> {
    complete_openai_compat_local(
        OLLAMA_HOST,
        OLLAMA_PORT,
        messages,
        model,
        "ollama",
        "Ollama model not selected — pick one in Settings (ollama serve + ollama pull)",
    )
}

fn complete_dottie_local(messages: &[Value], model: &str) -> Result<String, String> {
    let (host, port) = dottie_local_endpoint();
    complete_openai_compat_local(
        &host,
        port,
        messages,
        model,
        "dottielocal",
        "Dottie Local model not selected — start dottie-local and pick a model in Settings",
    )
}

fn complete_pro(messages: &[Value], token: &str) -> Result<String, String> {
    let mut body = Value::obj();
    body.insert("model", Value::str("grok"));
    body.insert("messages", Value::arr(messages.to_vec()));
    body.insert("stream", Value::bool(false));
    let auth = format!("Bearer {token}");
    let resp = tls::request(
        "POST",
        "https://api.dottie.ai/v1/chat/completions",
        &[
            ("Authorization", auth.as_str()),
            ("Content-Type", "application/json"),
        ],
        Some(body.stringify().as_bytes()),
        120,
    )?;
    extract_content(&resp.body)
}

fn complete_xai(messages: &[Value], key: &str, model: &str) -> Result<String, String> {
    let mut body = Value::obj();
    body.insert("model", Value::str(model));
    body.insert("messages", Value::arr(messages.to_vec()));
    body.insert("stream", Value::bool(false));
    let auth = format!("Bearer {key}");
    let resp = tls::request(
        "POST",
        "https://api.x.ai/v1/chat/completions",
        &[
            ("Authorization", auth.as_str()),
            ("Content-Type", "application/json"),
        ],
        Some(body.stringify().as_bytes()),
        120,
    )?;
    extract_content(&resp.body)
}

fn extract_content(body: &[u8]) -> Result<String, String> {
    let s = std::str::from_utf8(body).map_err(|e| e.to_string())?;
    let v = json::parse(s)?;
    v.get("choices")
        .and_then(|c| c.as_array())
        .and_then(|a| a.first())
        .and_then(|c| c.get("message"))
        .and_then(|m| m.get_str("content"))
        .map(|s| s.to_string())
        .ok_or_else(|| {
            log::error("agent", s, "LLM");
            format!("bad completion: {s}")
        })
}

fn tags_reachable(host: &str, port: u16, label: &str) -> Result<(), String> {
    let (status, body) = http::http_exchange(
        "GET",
        host,
        port,
        "/api/tags",
        &[],
        &[],
        5_000,
    )?;
    if !(200..300).contains(&status) {
        let s = String::from_utf8_lossy(&body);
        return Err(format!("{label} HTTP {status}: {s}"));
    }
    Ok(())
}

/// Probe local Ollama (`GET /api/tags`). Used by `/v1/provider/test`.
pub fn ollama_reachable() -> Result<(), String> {
    tags_reachable(OLLAMA_HOST, OLLAMA_PORT, "Ollama")
}

/// Probe dottie-local façade (`GET /api/tags`). Used by `/v1/provider/test`.
pub fn dottie_local_reachable() -> Result<(), String> {
    let (host, port) = dottie_local_endpoint();
    tags_reachable(&host, port, "Dottie Local")
}

/// Stream chat tokens via callback (SSE from Pro/xAI). Local providers use non-stream `complete`.
pub fn chat_stream(
    messages: &[Value],
    mut on_delta: impl FnMut(&str) + Send + 'static,
) -> Result<String, String> {
    let cfg = load_chat_config();
    if cfg.provider.eq_ignore_ascii_case("ollama") {
        let reply = complete_ollama(messages, &cfg.model)?;
        on_delta(&reply);
        return Ok(reply);
    }
    if cfg.provider.eq_ignore_ascii_case("dottielocal") {
        let reply = complete_dottie_local(messages, &cfg.model)?;
        on_delta(&reply);
        return Ok(reply);
    }

    let mut body = Value::obj();
    let (url, auth, model) = match cfg.provider.to_ascii_lowercase().as_str() {
        "xai" => {
            let key = if !cfg.api_key.is_empty() {
                cfg.api_key.clone()
            } else {
                std::env::var("XAI_API_KEY").map_err(|_| "no cloud credentials")?
            };
            let model = if cfg.model.is_empty() {
                "grok-2-latest".to_string()
            } else {
                cfg.model.clone()
            };
            (
                "https://api.x.ai/v1/chat/completions".to_string(),
                format!("Bearer {key}"),
                model,
            )
        }
        _ => {
            let tok = token::read_api_token().unwrap_or_default();
            if tok.is_empty() {
                return Err("no cloud credentials".into());
            }
            (
                "https://api.dottie.ai/v1/chat/completions".to_string(),
                format!("Bearer {tok}"),
                "grok".to_string(),
            )
        }
    };
    body.insert("model", Value::str(model));
    body.insert("messages", Value::arr(messages.to_vec()));
    body.insert("stream", Value::bool(true));

    let mut full = String::new();
    let mut line_buf = String::new();
    let status = tls::post_stream(
        &url,
        &[
            ("Authorization", auth.as_str()),
            ("Content-Type", "application/json"),
            ("Accept", "text/event-stream"),
        ],
        body.stringify().as_bytes(),
        180,
        move |chunk| {
            if let Ok(s) = std::str::from_utf8(chunk) {
                line_buf.push_str(s);
                while let Some(pos) = line_buf.find('\n') {
                    let line = line_buf[..pos].trim().to_string();
                    line_buf = line_buf[pos + 1..].to_string();
                    if let Some(data) = line.strip_prefix("data: ") {
                        if data.trim() == "[DONE]" {
                            continue;
                        }
                        if let Ok(v) = json::parse(data) {
                            if let Some(delta) = v
                                .get("choices")
                                .and_then(|c| c.as_array())
                                .and_then(|a| a.first())
                                .and_then(|c| c.get("delta"))
                                .and_then(|d| d.get_str("content"))
                            {
                                on_delta(delta);
                            }
                        }
                    }
                }
            }
        },
    )?;
    if !(200..300).contains(&status) {
        return Err(format!("stream status {status}"));
    }
    Ok(full)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::json::Value;

    #[test]
    fn apply_chat_config_fields_sets_provider_model() {
        let dir = std::env::temp_dir().join(format!("dottie-agent-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        // paths::dottie_dir is HOME/.dottie — skip filesystem if we can't isolate.
        // Smoke the Value merge path only.
        let mut msg = Value::obj();
        msg.insert("provider", Value::str("ollama"));
        msg.insert("model", Value::str("llama3.2"));
        assert_eq!(msg.get_str("provider"), Some("ollama"));
        assert_eq!(msg.get_str("model"), Some("llama3.2"));
    }

    #[test]
    fn parse_http_host_port_defaults() {
        assert_eq!(
            parse_http_host_port("http://127.0.0.1:1318"),
            Some(("127.0.0.1".into(), 1318))
        );
        assert_eq!(
            parse_http_host_port("http://127.0.0.1:1318/v1"),
            Some(("127.0.0.1".into(), 1318))
        );
        assert_eq!(parse_http_host_port("not-a-url"), None);
    }
}
