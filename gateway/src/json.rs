//! Minimal JSON value + parse/serialize — no serde.

use std::collections::BTreeMap;
use std::fmt;

#[derive(Clone, Debug, PartialEq)]
pub enum Value {
    Null,
    Bool(bool),
    Number(f64),
    String(String),
    Array(Vec<Value>),
    Object(BTreeMap<String, Value>),
}

impl Value {
    pub fn obj() -> Self {
        Value::Object(BTreeMap::new())
    }

    pub fn arr(items: Vec<Value>) -> Self {
        Value::Array(items)
    }

    pub fn str(s: impl Into<String>) -> Self {
        Value::String(s.into())
    }

    pub fn bool(b: bool) -> Self {
        Value::Bool(b)
    }

    pub fn num(n: f64) -> Self {
        Value::Number(n)
    }

    pub fn null() -> Self {
        Value::Null
    }

    pub fn insert(&mut self, k: impl Into<String>, v: Value) {
        if let Value::Object(map) = self {
            map.insert(k.into(), v);
        }
    }

    pub fn get(&self, k: &str) -> Option<&Value> {
        match self {
            Value::Object(m) => m.get(k),
            _ => None,
        }
    }

    pub fn get_str(&self, k: &str) -> Option<&str> {
        match self.get(k)? {
            Value::String(s) => Some(s.as_str()),
            _ => None,
        }
    }

    pub fn get_bool(&self, k: &str) -> Option<bool> {
        match self.get(k)? {
            Value::Bool(b) => Some(*b),
            _ => None,
        }
    }

    pub fn get_f64(&self, k: &str) -> Option<f64> {
        match self.get(k)? {
            Value::Number(n) => Some(*n),
            _ => None,
        }
    }

    pub fn get_i64(&self, k: &str) -> Option<i64> {
        self.get_f64(k).map(|n| n as i64)
    }

    pub fn as_object(&self) -> Option<&BTreeMap<String, Value>> {
        match self {
            Value::Object(m) => Some(m),
            _ => None,
        }
    }

    pub fn as_array(&self) -> Option<&[Value]> {
        match self {
            Value::Array(a) => Some(a),
            _ => None,
        }
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            Value::String(s) => Some(s),
            _ => None,
        }
    }

    pub fn stringify(&self) -> String {
        let mut out = String::new();
        write_value(self, &mut out);
        out
    }
}

impl fmt::Display for Value {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.stringify())
    }
}

fn write_value(v: &Value, out: &mut String) {
    match v {
        Value::Null => out.push_str("null"),
        Value::Bool(true) => out.push_str("true"),
        Value::Bool(false) => out.push_str("false"),
        Value::Number(n) => {
            if n.fract() == 0.0 && n.abs() < 1e15 {
                out.push_str(&format!("{}", *n as i64));
            } else {
                out.push_str(&format!("{n}"));
            }
        }
        Value::String(s) => write_string(s, out),
        Value::Array(a) => {
            out.push('[');
            for (i, item) in a.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                write_value(item, out);
            }
            out.push(']');
        }
        Value::Object(m) => {
            out.push('{');
            for (i, (k, val)) in m.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                write_string(k, out);
                out.push(':');
                write_value(val, out);
            }
            out.push('}');
        }
    }
}

fn write_string(s: &str, out: &mut String) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
}

pub fn parse(input: &str) -> Result<Value, String> {
    let mut p = Parser {
        s: input.as_bytes(),
        i: 0,
    };
    p.skip_ws();
    let v = p.parse_value()?;
    p.skip_ws();
    if p.i != p.s.len() {
        return Err("trailing junk".into());
    }
    Ok(v)
}

struct Parser<'a> {
    s: &'a [u8],
    i: usize,
}

impl<'a> Parser<'a> {
    fn skip_ws(&mut self) {
        while self.i < self.s.len() && self.s[self.i].is_ascii_whitespace() {
            self.i += 1;
        }
    }

    fn peek(&self) -> Option<u8> {
        self.s.get(self.i).copied()
    }

    fn bump(&mut self) -> Option<u8> {
        let c = self.peek()?;
        self.i += 1;
        Some(c)
    }

    fn parse_value(&mut self) -> Result<Value, String> {
        self.skip_ws();
        match self.peek() {
            Some(b'n') => self.parse_lit(b"null", Value::Null),
            Some(b't') => self.parse_lit(b"true", Value::Bool(true)),
            Some(b'f') => self.parse_lit(b"false", Value::Bool(false)),
            Some(b'"') => Ok(Value::String(self.parse_string()?)),
            Some(b'[') => self.parse_array(),
            Some(b'{') => self.parse_object(),
            Some(b'-') | Some(b'0'..=b'9') => self.parse_number(),
            _ => Err("unexpected token".into()),
        }
    }

    fn parse_lit(&mut self, lit: &[u8], v: Value) -> Result<Value, String> {
        for &b in lit {
            if self.bump() != Some(b) {
                return Err("bad literal".into());
            }
        }
        Ok(v)
    }

    fn parse_string(&mut self) -> Result<String, String> {
        if self.bump() != Some(b'"') {
            return Err("expected \"".into());
        }
        let mut out = String::new();
        loop {
            match self.bump() {
                None => return Err("unterminated string".into()),
                Some(b'"') => return Ok(out),
                Some(b'\\') => match self.bump() {
                    Some(b'"') => out.push('"'),
                    Some(b'\\') => out.push('\\'),
                    Some(b'/') => out.push('/'),
                    Some(b'n') => out.push('\n'),
                    Some(b'r') => out.push('\r'),
                    Some(b't') => out.push('\t'),
                    Some(b'u') => {
                        let mut hex = 0u32;
                        for _ in 0..4 {
                            let c = self.bump().ok_or("bad \\u")?;
                            hex = hex * 16
                                + match c {
                                    b'0'..=b'9' => (c - b'0') as u32,
                                    b'a'..=b'f' => (c - b'a' + 10) as u32,
                                    b'A'..=b'F' => (c - b'A' + 10) as u32,
                                    _ => return Err("bad \\u".into()),
                                };
                        }
                        out.push(char::from_u32(hex).unwrap_or('\u{FFFD}'));
                    }
                    _ => return Err("bad escape".into()),
                },
                Some(c) => out.push(c as char),
            }
        }
    }

    fn parse_number(&mut self) -> Result<Value, String> {
        let start = self.i;
        if self.peek() == Some(b'-') {
            self.i += 1;
        }
        while matches!(self.peek(), Some(b'0'..=b'9')) {
            self.i += 1;
        }
        if self.peek() == Some(b'.') {
            self.i += 1;
            while matches!(self.peek(), Some(b'0'..=b'9')) {
                self.i += 1;
            }
        }
        if matches!(self.peek(), Some(b'e' | b'E')) {
            self.i += 1;
            if matches!(self.peek(), Some(b'+' | b'-')) {
                self.i += 1;
            }
            while matches!(self.peek(), Some(b'0'..=b'9')) {
                self.i += 1;
            }
        }
        let s = std::str::from_utf8(&self.s[start..self.i]).map_err(|_| "bad num utf8")?;
        let n: f64 = s.parse().map_err(|_| "bad number")?;
        Ok(Value::Number(n))
    }

    fn parse_array(&mut self) -> Result<Value, String> {
        self.bump(); // [
        let mut items = Vec::new();
        self.skip_ws();
        if self.peek() == Some(b']') {
            self.bump();
            return Ok(Value::Array(items));
        }
        loop {
            items.push(self.parse_value()?);
            self.skip_ws();
            match self.bump() {
                Some(b',') => {
                    self.skip_ws();
                    continue;
                }
                Some(b']') => return Ok(Value::Array(items)),
                _ => return Err("bad array".into()),
            }
        }
    }

    fn parse_object(&mut self) -> Result<Value, String> {
        self.bump(); // {
        let mut map = BTreeMap::new();
        self.skip_ws();
        if self.peek() == Some(b'}') {
            self.bump();
            return Ok(Value::Object(map));
        }
        loop {
            self.skip_ws();
            let key = self.parse_string()?;
            self.skip_ws();
            if self.bump() != Some(b':') {
                return Err("expected :".into());
            }
            let val = self.parse_value()?;
            map.insert(key, val);
            self.skip_ws();
            match self.bump() {
                Some(b',') => continue,
                Some(b'}') => return Ok(Value::Object(map)),
                _ => return Err("bad object".into()),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_object() {
        let v = parse(r#"{"a":1,"b":"x","c":true,"d":null,"e":[1,2]}"#).unwrap();
        let s = v.stringify();
        let v2 = parse(&s).unwrap();
        assert_eq!(v, v2);
    }
}
