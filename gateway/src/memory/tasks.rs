use crate::json::Value;
use crate::sqlite::{self, SQLITE_DONE, SQLITE_ROW, USER_ID};

pub fn list_tasks() -> Result<Value, String> {
    sqlite::with_db(|db| {
        let stmt = db.prepare(
            "SELECT id, user_id, description, steps, category, priority, deadline, mode, status, current_step, progress, created_at, updated_at, last_worked_at FROM tasks WHERE user_id=? ORDER BY updated_at DESC",
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
        out.insert("tasks", Value::arr(arr));
        Ok(out)
    })
}

pub fn create_task(body: &Value) -> Result<Value, String> {
    let id = sqlite::new_id();
    let now = sqlite::now_ms();
    let desc = body.get_str("description").unwrap_or("").to_string();
    let steps = body.get("steps").map(|v| v.stringify()).unwrap_or_else(|| "[]".into());
    let category = body.get_str("category").unwrap_or("general").to_string();
    let priority = body.get_str("priority").unwrap_or("medium").to_string();
    let mode = body.get_str("mode").unwrap_or("auto").to_string();
    let deadline = body.get_i64("deadline");
    sqlite::with_db(|db| {
        let stmt = db.prepare(
            "INSERT INTO tasks (id, user_id, description, steps, category, priority, deadline, mode, status, current_step, progress, created_at, updated_at, last_worked_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        )?;
        stmt.bind_text(1, &id)?;
        stmt.bind_text(2, USER_ID)?;
        stmt.bind_text(3, &desc)?;
        stmt.bind_text(4, &steps)?;
        stmt.bind_text(5, &category)?;
        stmt.bind_text(6, &priority)?;
        if let Some(d) = deadline { stmt.bind_i64(7, d)?; } else { stmt.bind_null(7)?; }
        stmt.bind_text(8, &mode)?;
        stmt.bind_text(9, "pending")?;
        stmt.bind_i64(10, 0)?;
        stmt.bind_i64(11, 0)?;
        stmt.bind_i64(12, now)?;
        stmt.bind_i64(13, now)?;
        stmt.bind_null(14)?;
        let c = stmt.step()?;
        if c != SQLITE_DONE { return Err(format!("insert task {c}")); }
        Ok(())
    })?;
    let mut out = Value::obj();
    out.insert("task", get_task(&id)?.ok_or("missing")?);
    Ok(out)
}

pub fn update_task(id: &str, body: &Value) -> Result<(), String> {
    let now = sqlite::now_ms();
    sqlite::with_db(|db| {
        if let Some(d) = body.get_str("description") {
            let stmt = db.prepare("UPDATE tasks SET description=?, updated_at=? WHERE id=? AND user_id=?")?;
            stmt.bind_text(1, d)?; stmt.bind_i64(2, now)?; stmt.bind_text(3, id)?; stmt.bind_text(4, USER_ID)?;
            let _ = stmt.step()?;
        }
        if let Some(s) = body.get_str("status") {
            let stmt = db.prepare("UPDATE tasks SET status=?, updated_at=? WHERE id=? AND user_id=?")?;
            stmt.bind_text(1, s)?; stmt.bind_i64(2, now)?; stmt.bind_text(3, id)?; stmt.bind_text(4, USER_ID)?;
            let _ = stmt.step()?;
        }
        if let Some(p) = body.get_i64("progress") {
            let stmt = db.prepare("UPDATE tasks SET progress=?, updated_at=? WHERE id=? AND user_id=?")?;
            stmt.bind_i64(1, p)?; stmt.bind_i64(2, now)?; stmt.bind_text(3, id)?; stmt.bind_text(4, USER_ID)?;
            let _ = stmt.step()?;
        }
        Ok(())
    })
}

pub fn delete_task(id: &str) -> Result<(), String> {
    sqlite::with_db(|db| {
        let stmt = db.prepare("DELETE FROM tasks WHERE id=? AND user_id=?")?;
        stmt.bind_text(1, id)?; stmt.bind_text(2, USER_ID)?;
        let _ = stmt.step()?;
        Ok(())
    })
}

fn get_task(id: &str) -> Result<Option<Value>, String> {
    sqlite::with_db(|db| {
        let stmt = db.prepare(
            "SELECT id, user_id, description, steps, category, priority, deadline, mode, status, current_step, progress, created_at, updated_at, last_worked_at FROM tasks WHERE id=? AND user_id=?",
        )?;
        stmt.bind_text(1, id)?; stmt.bind_text(2, USER_ID)?;
        match stmt.step()? {
            SQLITE_ROW => Ok(Some(row(&stmt)?)),
            SQLITE_DONE => Ok(None),
            c => Err(format!("step {c}")),
        }
    })
}

fn row(stmt: &sqlite::Stmt) -> Result<Value, String> {
    let mut o = Value::obj();
    o.insert("id", Value::str(stmt.col_text(0).unwrap_or_default()));
    o.insert("userId", Value::str(stmt.col_text(1).unwrap_or_default()));
    o.insert("description", Value::str(stmt.col_text(2).unwrap_or_default()));
    let steps = crate::json::parse(&stmt.col_text(3).unwrap_or_else(|| "[]".into())).unwrap_or_else(|_| Value::arr(vec![]));
    o.insert("steps", steps);
    o.insert("category", Value::str(stmt.col_text(4).unwrap_or_default()));
    o.insert("priority", Value::str(stmt.col_text(5).unwrap_or_default()));
    o.insert("deadline", Value::num(stmt.col_i64(6) as f64));
    o.insert("mode", Value::str(stmt.col_text(7).unwrap_or_default()));
    o.insert("status", Value::str(stmt.col_text(8).unwrap_or_default()));
    o.insert("currentStep", Value::num(stmt.col_i64(9) as f64));
    o.insert("progress", Value::num(stmt.col_i64(10) as f64));
    o.insert("createdAt", Value::num(stmt.col_i64(11) as f64));
    o.insert("updatedAt", Value::num(stmt.col_i64(12) as f64));
    o.insert("lastWorkedAt", Value::num(stmt.col_i64(13) as f64));
    Ok(o)
}
