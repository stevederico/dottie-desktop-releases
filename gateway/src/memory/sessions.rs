//! Session store — SQLite.

use crate::json::{self, Value};
use crate::sqlite::{self, Stmt, SQLITE_DONE, SQLITE_ROW, USER_ID};

pub fn list_sessions() -> Result<Value, String> {
    sqlite::with_db(|db| {
        let stmt = db.prepare(
            "SELECT id, owner, title, messages, model, provider, createdAt, updatedAt FROM sessions WHERE owner=? ORDER BY updatedAt DESC",
        )?;
        stmt.bind_text(1, USER_ID)?;
        let mut arr = Vec::new();
        loop {
            match stmt.step()? {
                SQLITE_ROW => arr.push(row_session(&stmt, true)?),
                SQLITE_DONE => break,
                c => return Err(format!("step {c}")),
            }
        }
        let mut out = Value::obj();
        out.insert("sessions", Value::arr(arr));
        Ok(out)
    })
}

pub fn get_session(id: &str) -> Result<Option<Value>, String> {
    sqlite::with_db(|db| {
        let stmt = db.prepare(
            "SELECT id, owner, title, messages, model, provider, createdAt, updatedAt FROM sessions WHERE id=? AND owner=?",
        )?;
        stmt.bind_text(1, id)?;
        stmt.bind_text(2, USER_ID)?;
        match stmt.step()? {
            SQLITE_ROW => Ok(Some(row_session(&stmt, false)?)),
            SQLITE_DONE => Ok(None),
            c => Err(format!("step {c}")),
        }
    })
}

pub fn create_session(title: Option<&str>, id: Option<&str>) -> Result<Value, String> {
    let id = id.map(|s| s.to_string()).unwrap_or_else(sqlite::new_id);
    let now = sqlite::iso_now();
    let title = title.unwrap_or("").to_string();
    sqlite::with_db(|db| {
        let stmt = db.prepare(
            "INSERT INTO sessions (id, owner, title, messages, model, provider, createdAt, updatedAt) VALUES (?,?,?,?,?,?,?,?)",
        )?;
        stmt.bind_text(1, &id)?;
        stmt.bind_text(2, USER_ID)?;
        stmt.bind_text(3, &title)?;
        stmt.bind_text(4, "[]")?;
        stmt.bind_text(5, "grok")?;
        stmt.bind_text(6, "dottiepro")?;
        stmt.bind_text(7, &now)?;
        stmt.bind_text(8, &now)?;
        if stmt.step()? != SQLITE_DONE {
            return Err("insert session failed".into());
        }
        Ok(())
    })?;
    get_session(&id)?.ok_or_else(|| "session missing after create".into())
}

pub fn upsert_session(
    id: &str,
    title: Option<&str>,
    messages: Option<&Value>,
    model: Option<&str>,
    provider: Option<&str>,
) -> Result<(), String> {
    let now = sqlite::iso_now();
    sqlite::with_db(|db| {
        let exists = {
            let stmt = db.prepare("SELECT id FROM sessions WHERE id=? AND owner=?")?;
            stmt.bind_text(1, id)?;
            stmt.bind_text(2, USER_ID)?;
            matches!(stmt.step()?, SQLITE_ROW)
        };
        if exists {
            if let Some(t) = title {
                let stmt = db.prepare("UPDATE sessions SET title=?, updatedAt=? WHERE id=? AND owner=?")?;
                stmt.bind_text(1, t)?;
                stmt.bind_text(2, &now)?;
                stmt.bind_text(3, id)?;
                stmt.bind_text(4, USER_ID)?;
                let _ = stmt.step()?;
            }
            if let Some(m) = messages {
                let stmt = db.prepare("UPDATE sessions SET messages=?, updatedAt=? WHERE id=? AND owner=?")?;
                stmt.bind_text(1, &m.stringify())?;
                stmt.bind_text(2, &now)?;
                stmt.bind_text(3, id)?;
                stmt.bind_text(4, USER_ID)?;
                let _ = stmt.step()?;
            }
            if let Some(m) = model {
                let stmt = db.prepare("UPDATE sessions SET model=?, updatedAt=? WHERE id=? AND owner=?")?;
                stmt.bind_text(1, m)?;
                stmt.bind_text(2, &now)?;
                stmt.bind_text(3, id)?;
                stmt.bind_text(4, USER_ID)?;
                let _ = stmt.step()?;
            }
            if let Some(pr) = provider {
                let stmt = db.prepare("UPDATE sessions SET provider=?, updatedAt=? WHERE id=? AND owner=?")?;
                stmt.bind_text(1, pr)?;
                stmt.bind_text(2, &now)?;
                stmt.bind_text(3, id)?;
                stmt.bind_text(4, USER_ID)?;
                let _ = stmt.step()?;
            }
        } else {
            let stmt = db.prepare(
                "INSERT INTO sessions (id, owner, title, messages, model, provider, createdAt, updatedAt) VALUES (?,?,?,?,?,?,?,?)",
            )?;
            stmt.bind_text(1, id)?;
            stmt.bind_text(2, USER_ID)?;
            stmt.bind_text(3, title.unwrap_or(""))?;
            stmt.bind_text(4, &messages.map(|m| m.stringify()).unwrap_or_else(|| "[]".into()))?;
            stmt.bind_text(5, model.unwrap_or("grok"))?;
            stmt.bind_text(6, provider.unwrap_or("dottiepro"))?;
            stmt.bind_text(7, &now)?;
            stmt.bind_text(8, &now)?;
            let _ = stmt.step()?;
        }
        Ok(())
    })
}

pub fn delete_session(id: &str) -> Result<(), String> {
    sqlite::with_db(|db| {
        let stmt = db.prepare("DELETE FROM sessions WHERE id=? AND owner=?")?;
        stmt.bind_text(1, id)?;
        stmt.bind_text(2, USER_ID)?;
        let _ = stmt.step()?;
        Ok(())
    })
}

pub fn update_title(id: &str, title: &str) -> Result<(), String> {
    upsert_session(id, Some(title), None, None, None)
}

fn row_session(stmt: &Stmt, summary: bool) -> Result<Value, String> {
    let mut o = Value::obj();
    o.insert("id", Value::str(stmt.col_text(0).unwrap_or_default()));
    o.insert("owner", Value::str(stmt.col_text(1).unwrap_or_default()));
    o.insert("title", Value::str(stmt.col_text(2).unwrap_or_default()));
    let msgs_raw = stmt.col_text(3).unwrap_or_else(|| "[]".into());
    if summary {
        let count = json::parse(&msgs_raw)
            .ok()
            .and_then(|v| v.as_array().map(|a| a.len()))
            .unwrap_or(0);
        o.insert("messageCount", Value::num(count as f64));
    } else {
        let msgs = json::parse(&msgs_raw).unwrap_or_else(|_| Value::arr(vec![]));
        o.insert("messages", msgs);
    }
    o.insert("model", Value::str(stmt.col_text(4).unwrap_or_default()));
    o.insert("provider", Value::str(stmt.col_text(5).unwrap_or_default()));
    o.insert("createdAt", Value::str(stmt.col_text(6).unwrap_or_default()));
    o.insert("updatedAt", Value::str(stmt.col_text(7).unwrap_or_default()));
    Ok(o)
}
