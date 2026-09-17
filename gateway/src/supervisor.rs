//! Child process supervisor — talk (:1320) + mac-use (:1321).

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use crate::http;
use crate::json::Value;
use crate::log;
use crate::paths;
use crate::ports;

#[derive(Clone, Copy, PartialEq, Eq)]
enum State {
    Stopped,
    Starting,
    Running,
    Failed,
}

struct Service {
    name: &'static str,
    port: u16,
    state: State,
    child: Option<Child>,
    restart_count: u32,
    last_error: Option<String>,
    started_at: Option<Instant>,
}

struct Inner {
    services: HashMap<&'static str, Service>,
    gateway_dir: PathBuf,
    bin_dir: PathBuf,
}

pub struct Supervisor {
    inner: Arc<Mutex<Inner>>,
}

impl Supervisor {
    pub fn new(gateway_dir: PathBuf) -> Self {
        let talk_bin = gateway_dir.join("dottie-talk").join("bin");
        let bin_dir = std::env::var("DOTTIE_BIN_DIR")
            .ok()
            .map(PathBuf::from)
            .filter(|p| p.join("parakeet-server").exists())
            .unwrap_or(talk_bin);

        let mut services = HashMap::new();
        for (name, port) in [
            ("talk", ports::TALK_HTTP_PORT),
            ("macuse", ports::MAC_USE_HTTP_PORT),
        ] {
            services.insert(
                name,
                Service {
                    name,
                    port,
                    state: State::Stopped,
                    child: None,
                    restart_count: 0,
                    last_error: None,
                    started_at: None,
                },
            );
        }

        let inner = Arc::new(Mutex::new(Inner {
            services,
            gateway_dir,
            bin_dir,
        }));
        let health = Arc::clone(&inner);
        thread::spawn(move || health_loop(health));
        Supervisor { inner }
    }

    pub fn start_all(&self) {
        let _ = self.start_service("talk");
        let _ = self.start_service("macuse");
    }

    pub fn stop_all(&self) {
        let _ = self.stop_service("talk");
        let _ = self.stop_service("macuse");
    }

    pub fn start_service(&self, name: &str) -> Result<(), String> {
        let mut g = self.inner.lock().map_err(|e| e.to_string())?;
        start_locked(&mut g, name)
    }

    pub fn stop_service(&self, name: &str) -> Result<(), String> {
        let mut g = self.inner.lock().map_err(|e| e.to_string())?;
        stop_locked(&mut g, name)
    }

    pub fn restart_service(&self, name: &str) -> Result<(), String> {
        self.stop_service(name)?;
        thread::sleep(Duration::from_millis(300));
        self.start_service(name)
    }

    pub fn status_json(&self) -> Value {
        let g = self.inner.lock().unwrap();
        let mut services = Value::obj();
        for (name, svc) in &g.services {
            let mut o = Value::obj();
            o.insert(
                "state",
                Value::str(match svc.state {
                    State::Stopped => "stopped",
                    State::Starting => "starting",
                    State::Running => "running",
                    State::Failed => "failed",
                }),
            );
            o.insert("port", Value::num(svc.port as f64));
            o.insert("restartCount", Value::num(svc.restart_count as f64));
            match &svc.last_error {
                Some(err) => o.insert("error", Value::str(err.clone())),
                None => o.insert("error", Value::null()),
            }
            if let Some(child) = &svc.child {
                o.insert("pid", Value::num(child.id() as f64));
            }
            services.insert(*name, o);
        }
        let mut out = Value::obj();
        out.insert("services", services);
        out
    }
}

fn package_dir(gateway: &Path, name: &str) -> PathBuf {
    match name {
        "talk" => gateway.join("dottie-talk"),
        "macuse" => gateway.join("dottie-mac-use"),
        _ => gateway.join(name),
    }
}

fn start_locked(g: &mut Inner, name: &str) -> Result<(), String> {
    let cwd = package_dir(&g.gateway_dir, name);
    let script = cwd.join("http.js");
    if !script.exists() {
        return Err(format!("missing {}", script.display()));
    }
    let port = g
        .services
        .get(name)
        .map(|s| s.port)
        .ok_or_else(|| format!("unknown service {name}"))?;

    let logs = paths::logs_dir();
    let _ = std::fs::create_dir_all(&logs);
    let log_path = logs.join(format!("{name}.log"));
    let log_file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&log_path)
        .map_err(|e| e.to_string())?;
    let log_err = log_file.try_clone().map_err(|e| e.to_string())?;

    let node = find_node();
    let mut cmd = Command::new(&node);
    cmd.arg(script.file_name().unwrap())
        .current_dir(&cwd)
        .stdin(Stdio::null())
        .stdout(Stdio::from(log_file))
        .stderr(Stdio::from(log_err))
        .env("DOTTIE_BIN_DIR", &g.bin_dir)
        .env("DOTTIE_TALK_HTTP_PORT", ports::TALK_HTTP_PORT.to_string())
        .env(
            "DOTTIE_MAC_USE_HTTP_PORT",
            ports::MAC_USE_HTTP_PORT.to_string(),
        )
        .env("DOTTIE_AX_PORT", ports::AX_PORT.to_string())
        .env("DOTTIE_MAC_USE_DATA", paths::dottie_dir())
        .env("PORT", port.to_string());

    log::info(
        "supervisor",
        format!("starting {name} via {}", script.display()),
    );
    let child = cmd.spawn().map_err(|e| format!("spawn {name}: {e}"))?;
    let svc = g.services.get_mut(name).unwrap();
    svc.child = Some(child);
    svc.state = State::Starting;
    svc.started_at = Some(Instant::now());
    svc.last_error = None;
    Ok(())
}

fn stop_locked(g: &mut Inner, name: &str) -> Result<(), String> {
    let svc = g
        .services
        .get_mut(name)
        .ok_or_else(|| format!("unknown service {name}"))?;
    if let Some(mut child) = svc.child.take() {
        let _ = child.kill();
        let _ = child.wait();
    }
    svc.state = State::Stopped;
    Ok(())
}

fn find_node() -> PathBuf {
    if let Ok(p) = std::env::var("DOTTIE_NODE") {
        return PathBuf::from(p);
    }
    for c in [
        PathBuf::from("../node/bin/node"),
        PathBuf::from("../../node/bin/node"),
        PathBuf::from("/usr/local/bin/node"),
        PathBuf::from("/opt/homebrew/bin/node"),
    ] {
        if c.exists() {
            return c;
        }
    }
    PathBuf::from("node")
}

fn health_loop(inner: Arc<Mutex<Inner>>) {
    loop {
        thread::sleep(Duration::from_secs(10));
        let mut g = match inner.lock() {
            Ok(g) => g,
            Err(_) => continue,
        };
        let names: Vec<&str> = g.services.keys().copied().collect();
        for name in names {
            let (port, starting) = {
                let svc = g.services.get(name).unwrap();
                (
                    svc.port,
                    svc.state == State::Starting || svc.state == State::Running,
                )
            };
            if !starting {
                continue;
            }
            {
                let svc = g.services.get_mut(name).unwrap();
                if let Some(child) = svc.child.as_mut() {
                    match child.try_wait() {
                        Ok(Some(status)) => {
                            svc.last_error = Some(format!("exited {status}"));
                            svc.child = None;
                            svc.state = State::Failed;
                            log::warn("supervisor", format!("{name} exited: {status}"));
                        }
                        Ok(None) => {}
                        Err(e) => {
                            svc.last_error = Some(e.to_string());
                            svc.child = None;
                            svc.state = State::Failed;
                        }
                    }
                }
            }
            let up = http::tcp_open("127.0.0.1", port, 1000);
            let svc = g.services.get_mut(name).unwrap();
            if up {
                svc.state = State::Running;
            } else if svc.state == State::Running {
                svc.restart_count += 1;
                log::warn("supervisor", format!("{name} unhealthy — restart"));
                let _ = stop_locked(&mut g, name);
                let _ = start_locked(&mut g, name);
            } else if svc.state == State::Starting {
                if let Some(at) = svc.started_at {
                    if at.elapsed() > Duration::from_secs(180) {
                        svc.state = State::Failed;
                        svc.last_error = Some("startup timeout".into());
                    }
                }
            }
        }
    }
}

pub fn resolve_gateway_dir() -> PathBuf {
    if let Ok(p) = std::env::var("DOTTIE_GATEWAY_DIR") {
        return PathBuf::from(p);
    }
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            if dir.join("dottie-talk").exists() {
                return dir.to_path_buf();
            }
            if let Some(parent) = dir.parent() {
                if parent.join("dottie-talk").exists() {
                    return parent.to_path_buf();
                }
            }
        }
    }
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}
