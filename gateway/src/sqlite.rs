//! libsqlite3 FFI — thin wrapper for agent.db.

use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int, c_void};
use std::path::Path;
use std::ptr;
use std::sync::{Mutex, OnceLock};

pub const SQLITE_OK: c_int = 0;
pub const SQLITE_ROW: c_int = 100;
pub const SQLITE_DONE: c_int = 101;
const SQLITE_OPEN_READWRITE: c_int = 0x00000002;
const SQLITE_OPEN_CREATE: c_int = 0x00000004;

#[repr(C)]
pub struct Sqlite3 {
    _private: [u8; 0],
}
#[repr(C)]
pub struct Sqlite3Stmt {
    _private: [u8; 0],
}

#[link(name = "sqlite3")]
unsafe extern "C" {
    fn sqlite3_open_v2(
        filename: *const c_char,
        ppDb: *mut *mut Sqlite3,
        flags: c_int,
        zVfs: *const c_char,
    ) -> c_int;
    fn sqlite3_close(db: *mut Sqlite3) -> c_int;
    fn sqlite3_exec(
        db: *mut Sqlite3,
        sql: *const c_char,
        cb: *const c_void,
        arg: *mut c_void,
        errmsg: *mut *mut c_char,
    ) -> c_int;
    fn sqlite3_prepare_v2(
        db: *mut Sqlite3,
        zSql: *const c_char,
        nByte: c_int,
        ppStmt: *mut *mut Sqlite3Stmt,
        pzTail: *mut *const c_char,
    ) -> c_int;
    fn sqlite3_step(stmt: *mut Sqlite3Stmt) -> c_int;
    fn sqlite3_finalize(stmt: *mut Sqlite3Stmt) -> c_int;
    fn sqlite3_bind_text(
        stmt: *mut Sqlite3Stmt,
        idx: c_int,
        val: *const c_char,
        n: c_int,
        d: *const c_void,
    ) -> c_int;
    fn sqlite3_bind_int64(stmt: *mut Sqlite3Stmt, idx: c_int, val: i64) -> c_int;
    fn sqlite3_bind_null(stmt: *mut Sqlite3Stmt, idx: c_int) -> c_int;
    fn sqlite3_column_text(stmt: *mut Sqlite3Stmt, iCol: c_int) -> *const u8;
    fn sqlite3_column_int64(stmt: *mut Sqlite3Stmt, iCol: c_int) -> i64;
    fn sqlite3_column_type(stmt: *mut Sqlite3Stmt, iCol: c_int) -> c_int;
    fn sqlite3_errmsg(db: *mut Sqlite3) -> *const c_char;
    fn sqlite3_free(p: *mut c_void);
    fn sqlite3_changes(db: *mut Sqlite3) -> c_int;
}

const SQLITE_NULL: c_int = 5;
const SQLITE_TRANSIENT: isize = -1;

pub struct Db {
    ptr: *mut Sqlite3,
}

// Safety: we serialize all access via GLOBAL mutex.
unsafe impl Send for Db {}

static GLOBAL: OnceLock<Mutex<Option<Db>>> = OnceLock::new();

impl Db {
    pub fn open(path: &Path) -> Result<Self, String> {
        let cpath = CString::new(path.to_string_lossy().as_bytes()).map_err(|e| e.to_string())?;
        let mut ptr: *mut Sqlite3 = ptr::null_mut();
        let rc = unsafe {
            sqlite3_open_v2(
                cpath.as_ptr(),
                &mut ptr,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
                ptr::null(),
            )
        };
        if rc != SQLITE_OK || ptr.is_null() {
            return Err(format!("sqlite3_open_v2 failed: {rc}"));
        }
        let db = Db { ptr };
        db.exec("PRAGMA journal_mode=WAL;")?;
        db.exec("PRAGMA synchronous=NORMAL;")?;
        Ok(db)
    }

    pub fn exec(&self, sql: &str) -> Result<(), String> {
        let csql = CString::new(sql).map_err(|e| e.to_string())?;
        let mut errmsg: *mut c_char = ptr::null_mut();
        let rc = unsafe {
            sqlite3_exec(
                self.ptr,
                csql.as_ptr(),
                ptr::null(),
                ptr::null_mut(),
                &mut errmsg,
            )
        };
        if rc != SQLITE_OK {
            let msg = if !errmsg.is_null() {
                let s = unsafe { CStr::from_ptr(errmsg) }
                    .to_string_lossy()
                    .into_owned();
                unsafe { sqlite3_free(errmsg as *mut c_void) };
                s
            } else {
                format!("exec rc={rc}")
            };
            return Err(msg);
        }
        Ok(())
    }

    pub fn errmsg(&self) -> String {
        unsafe {
            CStr::from_ptr(sqlite3_errmsg(self.ptr))
                .to_string_lossy()
                .into_owned()
        }
    }

    pub fn prepare(&self, sql: &str) -> Result<Stmt, String> {
        let csql = CString::new(sql).map_err(|e| e.to_string())?;
        let mut stmt: *mut Sqlite3Stmt = ptr::null_mut();
        let rc = unsafe {
            sqlite3_prepare_v2(
                self.ptr,
                csql.as_ptr(),
                -1,
                &mut stmt,
                ptr::null_mut(),
            )
        };
        if rc != SQLITE_OK || stmt.is_null() {
            return Err(format!("prepare: {}", self.errmsg()));
        }
        Ok(Stmt { ptr: stmt, db: self.ptr })
    }

    pub fn changes(&self) -> i32 {
        unsafe { sqlite3_changes(self.ptr) }
    }
}

impl Drop for Db {
    fn drop(&mut self) {
        let _ = self.exec("PRAGMA wal_checkpoint(TRUNCATE);");
        unsafe {
            sqlite3_close(self.ptr);
        }
    }
}

pub struct Stmt {
    ptr: *mut Sqlite3Stmt,
    db: *mut Sqlite3,
}

unsafe impl Send for Stmt {}

impl Stmt {
    pub fn bind_text(&self, idx: c_int, val: &str) -> Result<(), String> {
        let c = CString::new(val).map_err(|e| e.to_string())?;
        let rc = unsafe {
            sqlite3_bind_text(
                self.ptr,
                idx,
                c.as_ptr(),
                -1,
                SQLITE_TRANSIENT as *const c_void,
            )
        };
        // CString dropped after bind — TRANSIENT copies
        if rc != SQLITE_OK {
            return Err(format!("bind_text {rc}"));
        }
        // keep c alive until after bind — TRANSIENT copies immediately so OK
        drop(c);
        Ok(())
    }

    pub fn bind_i64(&self, idx: c_int, val: i64) -> Result<(), String> {
        let rc = unsafe { sqlite3_bind_int64(self.ptr, idx, val) };
        if rc != SQLITE_OK {
            return Err(format!("bind_int64 {rc}"));
        }
        Ok(())
    }

    pub fn bind_null(&self, idx: c_int) -> Result<(), String> {
        let rc = unsafe { sqlite3_bind_null(self.ptr, idx) };
        if rc != SQLITE_OK {
            return Err(format!("bind_null {rc}"));
        }
        Ok(())
    }

    pub fn step(&self) -> Result<c_int, String> {
        Ok(unsafe { sqlite3_step(self.ptr) })
    }

    pub fn col_text(&self, i: c_int) -> Option<String> {
        unsafe {
            if sqlite3_column_type(self.ptr, i) == SQLITE_NULL {
                return None;
            }
            let p = sqlite3_column_text(self.ptr, i);
            if p.is_null() {
                return None;
            }
            Some(CStr::from_ptr(p as *const c_char).to_string_lossy().into_owned())
        }
    }

    pub fn col_i64(&self, i: c_int) -> i64 {
        unsafe { sqlite3_column_int64(self.ptr, i) }
    }
}

impl Drop for Stmt {
    fn drop(&mut self) {
        unsafe {
            sqlite3_finalize(self.ptr);
        }
    }
}

pub fn init_global(path: &Path) -> Result<(), String> {
    let db = Db::open(path)?;
    migrate(&db)?;
    let slot = GLOBAL.get_or_init(|| Mutex::new(None));
    *slot.lock().map_err(|e| e.to_string())? = Some(db);
    Ok(())
}

pub fn with_db<T>(f: impl FnOnce(&Db) -> Result<T, String>) -> Result<T, String> {
    let slot = GLOBAL.get().ok_or("db not initialized")?;
    let guard = slot.lock().map_err(|e| e.to_string())?;
    let db = guard.as_ref().ok_or("db missing")?;
    f(db)
}

fn migrate(db: &Db) -> Result<(), String> {
    db.exec(
        r#"
CREATE TABLE IF NOT EXISTS sessions (
  id TEXT PRIMARY KEY, owner TEXT NOT NULL, title TEXT DEFAULT '',
  messages TEXT NOT NULL, model TEXT NOT NULL, provider TEXT DEFAULT 'ollama',
  createdAt TEXT NOT NULL, updatedAt TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS idx_sessions_owner_updated ON sessions(owner, updatedAt DESC);
CREATE TABLE IF NOT EXISTS memories (
  id INTEGER PRIMARY KEY AUTOINCREMENT, user_id TEXT NOT NULL, key TEXT NOT NULL,
  value TEXT NOT NULL, app_id TEXT DEFAULT 'agent',
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL, UNIQUE(user_id, key));
CREATE INDEX IF NOT EXISTS idx_memories_user_key ON memories(user_id, key);
CREATE TABLE IF NOT EXISTS tasks (
  id TEXT PRIMARY KEY, user_id TEXT NOT NULL, description TEXT NOT NULL,
  steps TEXT NOT NULL, category TEXT DEFAULT 'general', priority TEXT DEFAULT 'medium',
  deadline INTEGER, mode TEXT DEFAULT 'auto', status TEXT DEFAULT 'pending',
  current_step INTEGER DEFAULT 0, progress INTEGER DEFAULT 0,
  created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, last_worked_at INTEGER);
CREATE INDEX IF NOT EXISTS idx_tasks_user_status ON tasks(user_id, status);
CREATE TABLE IF NOT EXISTS triggers (
  id TEXT PRIMARY KEY, user_id TEXT NOT NULL, event_type TEXT NOT NULL,
  prompt TEXT NOT NULL, cooldown_ms INTEGER DEFAULT 0, metadata TEXT,
  enabled INTEGER DEFAULT 1, last_fired_at INTEGER, fire_count INTEGER DEFAULT 0,
  created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS idx_triggers_user_event ON triggers(user_id, event_type);
CREATE TABLE IF NOT EXISTS events (
  id TEXT PRIMARY KEY, user_id TEXT NOT NULL, type TEXT NOT NULL, data TEXT,
  timestamp INTEGER NOT NULL,
  created_at INTEGER DEFAULT (strftime('%s','now') * 1000));
CREATE INDEX IF NOT EXISTS idx_events_user_type ON events(user_id, type);
CREATE TABLE IF NOT EXISTS config (
  key TEXT PRIMARY KEY, value TEXT,
  updated_at INTEGER DEFAULT (strftime('%s','now') * 1000));
"#,
    )?;
    // goals → tasks migration
    let _ = db.exec(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='goals'",
    );
    Ok(())
}

pub const USER_ID: &str = "desktop:local";

pub fn iso_now() -> String {
    let ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    let secs = (ms / 1000) as i64;
    let millis = ms % 1000;
    // reuse simple UTC format
    let days = secs.div_euclid(86400);
    let tod = secs.rem_euclid(86400) as u32;
    let h = tod / 3600;
    let mi = (tod % 3600) / 60;
    let s = tod % 60;
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
    format!("{y:04}-{m:02}-{d:02}T{h:02}:{mi:02}:{s:02}.{millis:03}Z")
}

pub fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

pub fn new_id() -> String {
    format!(
        "{}-{}",
        now_ms(),
        std::process::id()
    )
}
