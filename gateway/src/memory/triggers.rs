//! Trigger store.

use crate::json::{self, Value};
use crate::sqlite::{self, Stmt, SQLITE_DONE, SQLITE_ROW, USER_ID};

pub fn list_triggers() -> Result<Value, String> {
    sqlite::with_db(|db| {
        let stmt = db.prepare(
            "SELECT id, user_id, event_type, prompt, cooldown_ms, metadata, enabled, last_fired_at, fire_count, created_at, updated_at FROM triggers WHERE user_id=? ORDER BY updated_at DESC",
        )?;
        stmt.bind_text(1, USER_ID)?;
        let mut arr = Vec::new();
        loop {
            match stmt.step()? {
                SQLITE_ROW => arr.push(row(&stmt)?),
                SQLITE_DONE => break,
                c => return Err(format!("step {c}")),
            }
        }
        let mut out = Value::obj();
        out.insert("triggers", Value::arr(arr));
        Ok(out)
    })
}

pub fn create_trigger(body: &Value) -> Result<Value, String> {
    let id = sqlite::new_id();
    let now = sqlite::now_ms();
    let event_type = body.get_str("eventType").or_else(|| body.get_str("event_type")).unwrap_or("").to_string();
    let prompt = body.get_str("prompt").unwrap_or("").to_string();
    let cooldown = body.get_i64("cooldownMs").or_else(|| body.get_i64("cooldown_ms")).unwrap_or(0);
    let metadata = body.get("metadata").map(|v| v.stringify()).unwrap_or_else(|| "{}".into());
    let enabled = if body.get_bool("enabled").unwrap_or(true) { 1 } else { 0 };
    sqlite::with_db(|db| {
        let stmt = db.prepare(
            "INSERT INTO triggers (id, user_id, event_type, prompt, cooldown_ms, metadata, enabled, last_fired_at, fire_count, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
        )?;
        stmt.bind_text(1, &id)?;
        stmt.bind_text(2, USER_ID)?;
        stmt.bind_text(3, &event_type)?;
        stmt.bind_text(4, &prompt)?;
        stmt.bind_i64(5, cooldown)?;
        stmt.bind_text(6, &metadata)?;
        stmt.bind_i64(7, enabled)?;
        stmt.bind_null(8)?;
        stmt.bind_i64(9, 0)?;
        stmt.bind_i64(10, now)?;
        stmt.bind_i64(11, now)?;
        if stmt.step()? != SQLITE_DONE { return Err("insert trigger".into()); }
        Ok(())
    })?;
    let mut out = Value::obj();
    out.insert("trigger", get(&id)?.ok_or("missing")?);
    Ok(out)
}

pub fn toggle_trigger(id: &str, enabled: bool) -> Result<(), String> {
    let now = sqlite::now_ms();
    sqlite::with_db(|db| {
        let stmt = db.prepare("UPDATE triggers SET enabled=?, updated_at=? WHERE id=? AND user_id=?")?;
        stmt.bind_i64(1, if enabled { 1 } else { 0 })?;
        stmt.bind_i64(2, now)?;
        stmt.bind_text(3, id)?;
        stmt.bind_text(4, USER_ID)?;
        let _ = stmt.step()?;
        Ok(())
    })
}

pub fn delete_trigger(id: &str) -> Result<(), String> {
    sqlite::with_db(|db| {
        let stmt = db.prepare("DELETE FROM triggers WHERE id=? AND user_id=?")?;
        stmt.bind_text(1, id)?;
        stmt.bind_text(2, USER_ID)?;
        let _ = stmt.step()?;
        Ok(())
    })
}

pub fn find_matching(event_type: &str) -> Result<Vec<Value>, String> {
    sqlite::with_db(|db| {
        let stmt = db.prepare(
            "SELECT id, user_id, event_type, prompt, cooldown_ms, metadata, enabled, last_fired_at, fire_count, created_at, updated_at FROM triggers WHERE user_id=? AND event_type=? AND enabled=1",
        )?;
        stmt.bind_text(1, USER_ID)?;
        stmt.bind_text(2, event_type)?;
        let mut arr = Vec::new();
        let now = sqlite::now_ms();
        loop {
            match stmt.step()? {
                SQLITE_ROW => {
                    let cooldown = stmt.col_i64(4);
                    let last = stmt.col_i64(7);
                    if last > 0 && cooldown > 0 && now - last < cooldown {
                        continue;
                    }
                    arr.push(row(&stmt)?);
                }
                SQLITE_DONE => break,
                c => return Err(format!("step {c}")),
            }
        }
        Ok(arr)
    })
}

pub fn mark_fired(id: &str) -> Result<(), String> {
    let now = sqlite::now_ms();
    sqlite::with_db(|db| {
        let stmt = db.prepare(
            "UPDATE triggers SET last_fired_at=?, fire_count=fire_count+1, updated_at=? WHERE id=? AND user_id=?",
        )?;
        stmt.bind_i64(1, now)?;
        stmt.bind_i64(2, now)?;
        stmt.bind_text(3, id)?;
        stmt.bind_text(4, USER_ID)?;
        let _ = stmt.step()?;
        Ok(())
    })
}

fn get(id: &str) -> Result<Option<Value>, String> {
    sqlite::with_db(|db| {
        let stmt = db.prepare(
            "SELECT id, user_id, event_type, prompt, cooldown_ms, metadata, enabled, last_fired_at, fire_count, created_at, updated_at FROM triggers WHERE id=? AND user_id=?",
        )?;
        stmt.bind_text(1, id)?;
        stmt.bind_text(2, USER_ID)?;
        match stmt.step()? {
            SQLITE_ROW => Ok(Some(row(&stmt)?)),
            SQLITE_DONE => Ok(None),
            c => Err(format!("step {c}")),
        }
    })
}

fn row(stmt: &Stmt) -> Result<Value, String> {
    let mut o = Value::obj();
    o.insert("id", Value::str(stmt.col_text(0).unwrap_or_default()));
    o.insert("userId", Value::str(stmt.col_text(1).unwrap_or_default()));
    o.insert("eventType", Value::str(stmt.col_text(2).unwrap_or_default()));
    o.insert("prompt", Value::str(stmt.col_text(3).unwrap_or_default()));
    o.insert("cooldownMs", Value::num(stmt.col_i64(4) as f64));
    let meta = json::parse(&stmt.col_text(5).unwrap_or_else(|| "{}".into())).unwrap_or_else(|_| Value::obj());
    o.insert("metadata", meta);
    o.insert("enabled", Value::bool(stmt.col_i64(6) != 0));
    o.insert("lastFiredAt", Value::num(stmt.col_i64(7) as f64));
    o.insert("fireCount", Value::num(stmt.col_i64(8) as f64));
    o.insert("createdAt", Value::num(stmt.col_i64(9) as f64));
    o.insert("updatedAt", Value::num(stmt.col_i64(10) as f64));
    Ok(o)
}
