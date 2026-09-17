//! Dottie gateway — zero-crate Rust binary on :1317.

mod agent;
mod auth;
mod config_store;
mod http;
mod json;
mod log;
mod memory;
mod paths;
mod ports;
mod realtime;
mod routes;
mod sqlite;
mod supervisor;
mod tls;
mod token;
mod ws;

use std::io::Write;
use std::net::TcpListener;
use std::sync::Arc;
use std::thread;
use std::time::Instant;

use crate::http::read_request;
use crate::routes::AppState;
use crate::supervisor::Supervisor;

fn main() {
    let _ = std::fs::create_dir_all(paths::logs_dir());
    let _ = std::fs::create_dir_all(paths::dottie_dir());

    if let Err(e) = sqlite::init_global(&paths::agent_db_path()) {
        eprintln!("sqlite init failed: {e}");
        std::process::exit(1);
    }

    let gateway_dir = supervisor::resolve_gateway_dir();
    log::info("boot", format!("gateway_dir={}", gateway_dir.display()));

    let supervisor = Arc::new(Supervisor::new(gateway_dir));
    supervisor.start_all();

    let state = Arc::new(AppState {
        supervisor: Arc::clone(&supervisor),
        started: Instant::now(),
    });

    let port = std::env::var("PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(ports::GATEWAY_PORT);
    let addr = format!("127.0.0.1:{port}");
    let listener = TcpListener::bind(&addr).unwrap_or_else(|e| {
        eprintln!("bind {addr}: {e}");
        std::process::exit(1);
    });
    log::info("boot", format!("listening on {addr}"));

    let _ = std::fs::write(
        paths::gateway_pid_path(),
        format!("{}", std::process::id()),
    );

    for conn in listener.incoming() {
        match conn {
            Ok(stream) => {
                let state = Arc::clone(&state);
                thread::spawn(move || {
                    if let Err(e) = handle_client(stream, &state) {
                        log::debug("http", format!("client err: {e}"));
                    }
                });
            }
            Err(e) => log::warn("http", format!("accept: {e}")),
        }
    }
}

fn handle_client(
    mut stream: std::net::TcpStream,
    state: &AppState,
) -> std::io::Result<()> {
    let req = read_request(&mut stream)?;
    if req
        .header("Upgrade")
        .map(|u| u.eq_ignore_ascii_case("websocket"))
        .unwrap_or(false)
        && req.path_only().starts_with("/v1/realtime")
    {
        return ws::handle_upgrade(&mut stream, &req);
    }
    if req.method == "GET" && req.path_only() == "/system/health/stream" {
        if let Err(_) =
            auth::check_auth("GET", "/system/health/stream", req.header("Authorization"))
        {
            let mut err = json::Value::obj();
            err.insert("error", json::Value::str("unauthorized"));
            return crate::http::Response::json(401, &err).write_to(&mut stream);
        }
        write!(
            stream,
            "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n"
        )?;
        for _ in 0..120 {
            let status = state.supervisor.status_json();
            let mut payload = json::Value::obj();
            payload.insert("type", json::Value::str("health"));
            payload.insert("services", status.get("services").cloned().unwrap_or_else(json::Value::obj));
            write!(stream, "data: {}\n\n", payload.stringify())?;
            stream.flush()?;
            thread::sleep(std::time::Duration::from_secs(15));
            write!(stream, ": ping\n\n")?;
            stream.flush()?;
        }
        return Ok(());
    }
    let resp = routes::dispatch(state, &req);
    resp.write_to(&mut stream)
}
