//! Structured logging — mirrors logger.js line format.

use std::fs::OpenOptions;
use std::io::Write;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::json::Value;
use crate::paths;

#[derive(Clone)]
struct ErrorEntry {
    timestamp: String,
    epoch: u64,
    message: String,
    category: String,
    prefix: String,
}

static ERRORS: Mutex<Vec<ErrorEntry>> = Mutex::new(Vec::new());
static COUNTS: Mutex<(u32, u32, u32, u32)> = Mutex::new((0, 0, 0, 0)); // N T L S

fn now_stamp() -> String {
    // Local-ish wall clock via UTC offset unavailable without crate — use epoch ms + ISO-ish UTC.
    let ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    let secs = (ms / 1000) as i64;
    let millis = ms % 1000;
    let (y, mo, d, h, mi, s) = civil_from_days(secs);
    format!("{y:04}-{mo:02}-{d:02} {h:02}:{mi:02}:{s:02}.{millis:03}")
}

fn iso_now() -> (String, u64) {
    let ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0);
    let secs = (ms / 1000) as i64;
    let (y, mo, d, h, mi, s) = civil_from_days(secs);
    let millis = ms % 1000;
    (
        format!("{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}.{millis:03}Z"),
        ms,
    )
}

/// Days since Unix epoch → Y-M-D h:m:s (UTC).
fn civil_from_days(secs: i64) -> (i32, u32, u32, u32, u32, u32) {
    let days = secs.div_euclid(86400);
    let tod = secs.rem_euclid(86400) as u32;
    let h = tod / 3600;
    let mi = (tod % 3600) / 60;
    let s = tod % 60;
    // Howard Hinnant civil_from_days
    let z = days + 719468;
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = (z - era * 146097) as u32;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = (yoe as i64) + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    (y as i32, m, d, h, mi, s)
}

fn emit(level: &str, prefix: &str, msg: &str) {
    let line = format!("[{}] [{}] [{}] {}\n", now_stamp(), level, prefix, msg);
    let _ = std::io::stderr().write_all(line.as_bytes());
    if let Ok(mut f) = OpenOptions::new()
        .create(true)
        .append(true)
        .open(paths::gateway_log_path())
    {
        let _ = f.write_all(line.as_bytes());
    }
}

pub fn info(prefix: &str, msg: impl AsRef<str>) {
    emit("INFO", prefix, msg.as_ref());
}

pub fn warn(prefix: &str, msg: impl AsRef<str>) {
    emit("WARN", prefix, msg.as_ref());
}

pub fn debug(prefix: &str, msg: impl AsRef<str>) {
    if std::env::var("DEBUG_AGENT").ok().as_deref() == Some("true") {
        emit("DEBUG", prefix, msg.as_ref());
    }
}

pub fn error(prefix: &str, message: impl AsRef<str>, category: &str) {
    let message = message.as_ref().to_string();
    emit("ERROR", prefix, &message);
    let (ts, epoch) = iso_now();
    if let Ok(mut buf) = ERRORS.lock() {
        buf.push(ErrorEntry {
            timestamp: ts,
            epoch,
            message,
            category: category.to_string(),
            prefix: prefix.to_string(),
        });
        if buf.len() > 200 {
            let drain = buf.len() - 200;
            buf.drain(0..drain);
        }
    }
    if let Ok(mut c) = COUNTS.lock() {
        match category {
            "NETWORK" => c.0 += 1,
            "TOOL" => c.1 += 1,
            "LLM" => c.2 += 1,
            _ => c.3 += 1,
        }
    }
}

pub fn get_error_stats(limit: usize) -> Value {
    let recent = ERRORS
        .lock()
        .map(|b| {
            b.iter()
                .rev()
                .take(limit)
                .map(|e| {
                    let mut o = Value::obj();
                    o.insert("timestamp", Value::str(&e.timestamp));
                    o.insert("epoch", Value::num(e.epoch as f64));
                    o.insert("message", Value::str(&e.message));
                    o.insert("category", Value::str(&e.category));
                    o.insert("prefix", Value::str(&e.prefix));
                    o.insert("stack", Value::null());
                    o.insert("context", Value::null());
                    o
                })
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    let counts = COUNTS.lock().map(|c| *c).unwrap_or((0, 0, 0, 0));
    let mut counts_obj = Value::obj();
    counts_obj.insert("NETWORK", Value::num(counts.0 as f64));
    counts_obj.insert("TOOL", Value::num(counts.1 as f64));
    counts_obj.insert("LLM", Value::num(counts.2 as f64));
    counts_obj.insert("SYSTEM", Value::num(counts.3 as f64));
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0);
    let hour_ago = now.saturating_sub(3_600_000);
    let errors_last_hour = ERRORS
        .lock()
        .map(|b| b.iter().filter(|e| e.epoch >= hour_ago).count())
        .unwrap_or(0);
    let mut out = Value::obj();
    out.insert("recent", Value::arr(recent));
    out.insert("counts", counts_obj);
    out.insert("errorsLastHour", Value::num(errors_last_hour as f64));
    out.insert(
        "errorsPerMinute",
        Value::num(errors_last_hour as f64 / 60.0),
    );
    out.insert(
        "total",
        Value::num((counts.0 + counts.1 + counts.2 + counts.3) as f64),
    );
    out
}
