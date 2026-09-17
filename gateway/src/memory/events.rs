//! Event log store.

use crate::json::{self, Value};
use crate::sqlite::{self, SQLITE_DONE, USER_ID};

pub fn log_event(event_type: &str, data: Option<&Value>) -> Result<Value, String> {
    let id = sqlite::new_id();
    let now = sqlite::now_ms();
    let data_s = data.map(|v| v.stringify()).unwrap_or_else(|| "{}".into());
    sqlite::with_db(|db| {
        let stmt = db.prepare(
            "INSERT INTO events (id, user_id, type, data, timestamp, created_at) VALUES (?,?,?,?,?,?)",
        )?;
        stmt.bind_text(1, &id)?;
        stmt.bind_text(2, USER_ID)?;
        stmt.bind_text(3, event_type)?;
        stmt.bind_text(4, &data_s)?;
        stmt.bind_i64(5, now)?;
        stmt.bind_i64(6, now)?;
        if stmt.step()? != SQLITE_DONE { return Err("insert event".into()); }
        Ok(())
    })?;
    let mut ev = Value::obj();
    ev.insert("id", Value::str(&id));
    ev.insert("type", Value::str(event_type));
    ev.insert("data", data.cloned().unwrap_or_else(Value::obj));
    ev.insert("timestamp", Value::num(now as f64));
    let mut out = Value::obj();
    out.insert("success", Value::bool(true));
    out.insert("event", ev);
    Ok(out)
}
