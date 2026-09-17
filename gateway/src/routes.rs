//! HTTP route table for the Swift client.

use std::sync::Arc;
use std::time::Instant;

use crate::agent;
use crate::auth::{self, AuthFail};
use crate::config_store;
use crate::http::{self, Request, Response};
use crate::json::{self, Value};
use crate::log;
use crate::memory::{events, memories, sessions, tasks, triggers};
use crate::ports;
use crate::supervisor::Supervisor;
use crate::tls;
use crate::token;

pub struct AppState {
    pub supervisor: Arc<Supervisor>,
    pub started: Instant,
}

pub fn dispatch(state: &AppState, req: &Request) -> Response {
    let path = req.path_only();
    let method = req.method.as_str();

    if let Err(fail) = auth::check_auth(method, path, req.header("Authorization")) {
        let mut err = Value::obj();
        match fail {
            AuthFail::TokenUnreadable => err.insert("error", Value::str("token_unreadable")),
            AuthFail::BadToken => err.insert("error", Value::str("unauthorized")),
        }
        return Response::json(401, &err);
    }

    match (method, path) {
        ("GET", "/health") => health(state),

        ("GET", "/system/status") => {
            let mut v = state.supervisor.status_json();
            v.insert("uptime", Value::num(state.started.elapsed().as_secs_f64()));
            Response::json(200, &v)
        }
        ("POST", "/system/start") => {
            state.supervisor.start_all();
            ok()
        }
        ("POST", "/system/stop") => {
            state.supervisor.stop_all();
            ok()
        }
        ("GET", "/system/errors") => Response::json(200, &log::get_error_stats(50)),
        ("POST", "/system/services/talk/stop") => svc_result(state.supervisor.stop_service("talk")),
        ("POST", "/system/services/macuse/stop") => {
            svc_result(state.supervisor.stop_service("macuse"))
        }
        ("POST", "/system/services/talk/restart") => {
            svc_result(state.supervisor.restart_service("talk"))
        }
        ("POST", "/system/services/macuse/restart") => {
            svc_result(state.supervisor.restart_service("macuse"))
        }

        ("GET", "/v1/config/resolved") => {
            let mut out = Value::obj();
            out.insert("config", config_store::read_config());
            out.insert("sttModel", Value::str("parakeet"));
            out.insert("ttsModel", Value::str("koko"));
            Response::json(200, &out)
        }
        ("POST", "/v1/config") => {
            let body = parse_body(req);
            let mut cfg = config_store::read_config();
            if let Some(obj) = body.as_object() {
                for (k, v) in obj {
                    cfg.insert(k.clone(), v.clone());
                }
            }
            result_unit(config_store::write_config(&cfg))
        }
        ("GET", "/v1/preferences") => Response::json(200, &config_store::read_preferences()),
        ("PUT", "/v1/preferences") => {
            let body = parse_body(req);
            let mut prefs = config_store::read_preferences();
            if let Some(obj) = body.as_object() {
                for (k, v) in obj {
                    prefs.insert(k.clone(), v.clone());
                }
            }
            match config_store::write_preferences(&prefs) {
                Ok(()) => Response::json(200, &prefs),
                Err(e) => err500(e),
            }
        }

        ("GET", "/v1/sessions") => result_val(sessions::list_sessions()),
        ("POST", "/v1/sessions") => {
            let body = parse_body(req);
            match sessions::create_session(body.get_str("title"), body.get_str("id")) {
                Ok(s) => {
                    let mut out = Value::obj();
                    out.insert("session", s);
                    Response::json(200, &out)
                }
                Err(e) => err500(e),
            }
        }
        ("GET", p) if p.starts_with("/v1/sessions/") => {
            let id = &p["/v1/sessions/".len()..];
            match sessions::get_session(id) {
                Ok(Some(s)) => {
                    let mut out = Value::obj();
                    out.insert("session", s);
                    Response::json(200, &out)
                }
                Ok(None) => err404(),
                Err(e) => err500(e),
            }
        }
        ("PUT", p) if p.starts_with("/v1/sessions/") => {
            let id = &p["/v1/sessions/".len()..];
            let body = parse_body(req);
            result_unit(sessions::upsert_session(
                id,
                body.get_str("title"),
                body.get("messages"),
                body.get_str("model"),
                body.get_str("provider"),
            ))
        }
        ("DELETE", p) if p.starts_with("/v1/sessions/") => {
            result_unit(sessions::delete_session(&p["/v1/sessions/".len()..]))
        }

        ("GET", "/v1/tasks") => result_val(tasks::list_tasks()),
        ("POST", "/v1/tasks") => result_val(tasks::create_task(&parse_body(req))),
        ("PUT", p) if p.starts_with("/v1/tasks/") => {
            result_unit(tasks::update_task(&p["/v1/tasks/".len()..], &parse_body(req)))
        }
        ("DELETE", p) if p.starts_with("/v1/tasks/") => {
            result_unit(tasks::delete_task(&p["/v1/tasks/".len()..]))
        }

        ("GET", "/v1/triggers") => result_val(triggers::list_triggers()),
        ("POST", "/v1/triggers") => result_val(triggers::create_trigger(&parse_body(req))),
        ("PATCH", p) if p.starts_with("/v1/triggers/") => {
            let id = &p["/v1/triggers/".len()..];
            let enabled = parse_body(req).get_bool("enabled").unwrap_or(true);
            result_unit(triggers::toggle_trigger(id, enabled))
        }
        ("DELETE", p) if p.starts_with("/v1/triggers/") => {
            result_unit(triggers::delete_trigger(&p["/v1/triggers/".len()..]))
        }

        ("GET", "/v1/memory") => result_val(memories::list_memories()),
        ("POST", "/v1/memory") => {
            let body = parse_body(req);
            let key = body.get_str("key").unwrap_or("");
            let value = body.get("value").cloned().unwrap_or_else(Value::null);
            result_val(memories::write_memory(key, &value))
        }
        ("DELETE", p) if p.starts_with("/v1/memory/") => {
            result_unit(memories::delete_memory(&p["/v1/memory/".len()..]))
        }

        ("GET", "/v1/user-memory") => {
            let mut out = Value::obj();
            out.insert("content", Value::str(config_store::read_user_memory()));
            Response::json(200, &out)
        }
        ("POST", "/v1/user-memory") => {
            let body = parse_body(req);
            let content = body.get_str("content").unwrap_or("").to_string();
            result_unit(config_store::write_user_memory(&content))
        }

        ("POST", "/v1/events") => {
            let body = parse_body(req);
            let ty = body.get_str("type").unwrap_or("unknown");
            result_val(events::log_event(ty, body.get("data")))
        }
        ("POST", "/v1/events/fire") => fire_event(req),

        ("POST", "/v1/provider/test") => provider_test(req),
        ("POST", "/v1/title") => {
            let body = parse_body(req);
            let msg = body.get_str("message").unwrap_or("Chat");
            let title: String = msg.chars().take(48).collect();
            let mut out = Value::obj();
            out.insert("title", Value::str(title));
            Response::json(200, &out)
        }

        ("POST", p) if p.starts_with("/v1/tools/") => {
            proxy_post(
                ports::MAC_USE_HTTP_PORT,
                p,
                req.header("Content-Type").unwrap_or("application/json"),
                &req.body,
            )
        }
        ("POST", "/v1/audio/transcriptions") => proxy_post(
            ports::TALK_HTTP_PORT,
            "/v1/audio/transcriptions",
            req.header("Content-Type")
                .unwrap_or("application/octet-stream"),
            &req.body,
        ),

        _ => err404(),
    }
}

fn fire_event(req: &Request) -> Response {
    let body = parse_body(req);
    let event_type = body
        .get_str("eventType")
        .or_else(|| body.get_str("type"))
        .unwrap_or("");
    match triggers::find_matching(event_type) {
        Ok(list) if list.is_empty() => {
            let mut out = Value::obj();
            out.insert("triggered", Value::bool(false));
            Response::json(200, &out)
        }
        Ok(list) => {
            for t in &list {
                if let Some(id) = t.get_str("id") {
                    let _ = triggers::mark_fired(id);
                }
            }
            let mut out = Value::obj();
            out.insert("triggered", Value::bool(true));
            out.insert("triggers", Value::arr(list));
            Response::json(200, &out)
        }
        Err(e) => err500(e),
    }
}

fn provider_test(req: &Request) -> Response {
    let body = parse_body(req);
    let provider = body.get_str("provider").unwrap_or("dottiepro");
    let mut out = Value::obj();
    if provider.eq_ignore_ascii_case("ollama") {
        match agent::ollama_reachable() {
            Ok(()) => {
                out.insert("ok", Value::bool(true));
                out.insert("provider", Value::str("ollama"));
            }
            Err(e) => {
                out.insert("ok", Value::bool(false));
                out.insert(
                    "error",
                    Value::str(format!(
                        "Ollama not reachable at 127.0.0.1:11434 ({e}). Start with `ollama serve`."
                    )),
                );
            }
        }
        return Response::json(200, &out);
    }
    if provider.eq_ignore_ascii_case("dottielocal") {
        let (host, port) = agent::dottie_local_endpoint();
        match agent::dottie_local_reachable() {
            Ok(()) => {
                out.insert("ok", Value::bool(true));
                out.insert("provider", Value::str("dottielocal"));
            }
            Err(e) => {
                out.insert("ok", Value::bool(false));
                out.insert(
                    "error",
                    Value::str(format!(
                        "Dottie Local not reachable at {host}:{port} ({e}). Run `dottie-local start`."
                    )),
                );
            }
        }
        return Response::json(200, &out);
    }
    if provider.eq_ignore_ascii_case("xai") {
        let key = body
            .get_str("apiKey")
            .map(|s| s.to_string())
            .or_else(|| std::env::var("XAI_API_KEY").ok())
            .unwrap_or_default();
        if key.is_empty() {
            out.insert("ok", Value::bool(false));
            out.insert("error", Value::str("missing apiKey"));
            return Response::json(200, &out);
        }
        let auth = format!("Bearer {key}");
        match tls::request(
            "GET",
            "https://api.x.ai/v1/models",
            &[("Authorization", auth.as_str())],
            None,
            15,
        ) {
            Ok(r) => {
                out.insert("ok", Value::bool((200..300).contains(&r.status)));
                out.insert("status", Value::num(r.status as f64));
            }
            Err(e) => {
                out.insert("ok", Value::bool(false));
                out.insert("error", Value::str(e));
            }
        }
    } else {
        match token::read_api_token() {
            Ok(t) if !t.is_empty() => {
                out.insert("ok", Value::bool(true));
                out.insert("provider", Value::str("dottiepro"));
            }
            _ => {
                out.insert("ok", Value::bool(false));
                out.insert("error", Value::str("missing api_token"));
            }
        }
    }
    Response::json(200, &out)
}

fn proxy_post(port: u16, path: &str, content_type: &str, body: &[u8]) -> Response {
    match http::http_exchange(
        "POST",
        "127.0.0.1",
        port,
        path,
        &[("Content-Type", content_type)],
        body,
        180_000,
    ) {
        Ok((status, body)) => Response {
            status,
            headers: vec![
                ("Content-Type".into(), "application/json".into()),
                ("Content-Length".into(), body.len().to_string()),
                ("Connection".into(), "close".into()),
            ],
            body,
        },
        Err(e) => {
            log::error("proxy", &e, "NETWORK");
            err503(e)
        }
    }
}

fn parse_body(req: &Request) -> Value {
    match req.body_str() {
        Ok(s) if !s.trim().is_empty() => json::parse(s).unwrap_or_else(|_| Value::obj()),
        _ => Value::obj(),
    }
}

fn ok() -> Response {
    let mut v = Value::obj();
    v.insert("success", Value::bool(true));
    Response::json(200, &v)
}

fn svc_result(r: Result<(), String>) -> Response {
    match r {
        Ok(()) => ok(),
        Err(e) => err500(e),
    }
}

fn result_val(r: Result<Value, String>) -> Response {
    match r {
        Ok(v) => Response::json(200, &v),
        Err(e) => err500(e),
    }
}

fn result_unit(r: Result<(), String>) -> Response {
    match r {
        Ok(()) => ok(),
        Err(e) => err500(e),
    }
}

fn err404() -> Response {
    let mut e = Value::obj();
    e.insert("error", Value::str("not_found"));
    Response::json(404, &e)
}

fn err500(msg: impl Into<String>) -> Response {
    let msg = msg.into();
    log::error("routes", &msg, "SYSTEM");
    let mut e = Value::obj();
    e.insert("error", Value::str(msg));
    Response::json(500, &e)
}

fn err503(msg: impl Into<String>) -> Response {
    let mut e = Value::obj();
    e.insert("error", Value::str(msg.into()));
    Response::json(503, &e)
}

fn health(state: &AppState) -> Response {
    let mut v = Value::obj();
    v.insert("status", Value::str("ok"));
    v.insert("uptime", Value::num(state.started.elapsed().as_secs_f64()));
    Response::json(200, &v)
}
