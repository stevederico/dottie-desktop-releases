//! Key/value memory store.

use crate::json::{self, Value};
use crate::sqlite::{self, Stmt, SQLITE_DONE, SQLITE_ROW, USER_ID};

pub fn list_memories() -> Result<Value, String> {
    sqlite::with_db(|db| {
        let stmt = db.prepare(
            "SELECT key, value, updated_at FROM memories WHERE user_id=? ORDER BY updated_at DESC",
        )?;
        stmt.bind_text(1, USER_ID)?;
        let mut arr = Vec::new();
        loop {
            match stmt.step()? {
                SQLITE_ROW => {
                    let mut o = Value::obj();
                    o.insert("key", Value::str(stmt.col_text(0).unwrap_or_default()));
                    let val = stmt.col_text(1).unwrap_or_default();
                    o.insert("value", json::parse(&val).unwrap_or_else(|_| Value::str(val)));
                    o.insert("updatedAt", Value::str(stmt.col_text(2).unwrap_or_default()));
                    arr.push(o);
                }
                SQLITE_DONE => break,
                c => return Err(format!("step {c}")),
            }
        }
        let mut out = Value::obj();
        out.insert("memories", Value::arr(arr));
        Ok(out)
    })
}

pub fn write_memory(key: &str, value: &Value) -> Result<Value, String> {
    let now = sqlite::iso_now();
    let val = value.stringify();
    sqlite::with_db(|db| {
        let stmt = db.prepare(
            "INSERT INTO memories (user_id, key, value, app_id, created_at, updated_at) VALUES (?,?,?,?,?,?)
             ON CONFLICT(user_id, key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at",
        )?;
        stmt.bind_text(1, USER_ID)?;
        stmt.bind_text(2, key)?;
        stmt.bind_text(3, &val)?;
        stmt.bind_text(4, "agent")?;
        stmt.bind_text(5, &now)?;
        stmt.bind_text(6, &now)?;
        if stmt.step()? != SQLITE_DONE { return Err("upsert memory".into()); }
        Ok(())
    })?;
    let mut mem = Value::obj();
    mem.insert("key", Value::str(key));
    mem.insert("value", value.clone());
    mem.insert("updatedAt", Value::str(&now));
    let mut out = Value::obj();
    out.insert("memory", mem);
    Ok(out)
}

pub fn delete_memory(key: &str) -> Result<(), String> {
    sqlite::with_db(|db| {
        let stmt = db.prepare("DELETE FROM memories WHERE user_id=? AND key=?")?;
        stmt.bind_text(1, USER_ID)?;
        stmt.bind_text(2, key)?;
        let _ = stmt.step()?;
        Ok(())
    })
}
