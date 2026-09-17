//! HTTP/1.1 request/response — zero-crate.

use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::TcpStream;

#[derive(Debug, Clone)]
pub struct Request {
    pub method: String,
    pub path: String,
    pub query: String,
    pub headers: HashMap<String, String>,
    pub body: Vec<u8>,
}

impl Request {
    pub fn header(&self, name: &str) -> Option<&str> {
        let lower = name.to_ascii_lowercase();
        self.headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(&lower))
            .map(|(_, v)| v.as_str())
    }

    pub fn path_only(&self) -> &str {
        &self.path
    }

    pub fn body_str(&self) -> Result<&str, std::str::Utf8Error> {
        std::str::from_utf8(&self.body)
    }
}

#[derive(Debug)]
pub struct Response {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl Response {
    pub fn json(status: u16, body: &crate::json::Value) -> Self {
        let bytes = body.stringify().into_bytes();
        Self {
            status,
            headers: vec![
                ("Content-Type".into(), "application/json; charset=utf-8".into()),
                ("Content-Length".into(), bytes.len().to_string()),
                ("Connection".into(), "close".into()),
            ],
            body: bytes,
        }
    }

    pub fn text(status: u16, body: &str, content_type: &str) -> Self {
        let bytes = body.as_bytes().to_vec();
        Self {
            status,
            headers: vec![
                ("Content-Type".into(), content_type.into()),
                ("Content-Length".into(), bytes.len().to_string()),
                ("Connection".into(), "close".into()),
            ],
            body: bytes,
        }
    }

    pub fn empty(status: u16) -> Self {
        Self {
            status,
            headers: vec![
                ("Content-Length".into(), "0".into()),
                ("Connection".into(), "close".into()),
            ],
            body: Vec::new(),
        }
    }

    pub fn write_to(&self, stream: &mut TcpStream) -> std::io::Result<()> {
        let reason = reason_phrase(self.status);
        write!(stream, "HTTP/1.1 {} {}\r\n", self.status, reason)?;
        for (k, v) in &self.headers {
            write!(stream, "{}: {}\r\n", k, v)?;
        }
        write!(stream, "\r\n")?;
        stream.write_all(&self.body)?;
        Ok(())
    }
}

fn reason_phrase(status: u16) -> &'static str {
    match status {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        500 => "Internal Server Error",
        503 => "Service Unavailable",
        _ => "OK",
    }
}

pub fn read_request(stream: &mut TcpStream) -> std::io::Result<Request> {
    stream.set_read_timeout(Some(std::time::Duration::from_secs(120)))?;
    let mut buf = Vec::with_capacity(8192);
    let mut tmp = [0u8; 4096];
    // Read until headers end
    loop {
        let n = stream.read(&mut tmp)?;
        if n == 0 {
            break;
        }
        buf.extend_from_slice(&tmp[..n]);
        if buf.windows(4).any(|w| w == b"\r\n\r\n") {
            break;
        }
        if buf.len() > 1024 * 1024 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "headers too large",
            ));
        }
    }
    let header_end = buf
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::UnexpectedEof, "no header end"))?;
    let header_bytes = &buf[..header_end];
    let mut body = buf[header_end + 4..].to_vec();

    let header_str = std::str::from_utf8(header_bytes)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
    let mut lines = header_str.split("\r\n");
    let request_line = lines
        .next()
        .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::InvalidData, "empty req"))?;
    let mut parts = request_line.split_whitespace();
    let method = parts.next().unwrap_or("GET").to_string();
    let target = parts.next().unwrap_or("/").to_string();
    let (path, query) = match target.split_once('?') {
        Some((p, q)) => (p.to_string(), q.to_string()),
        None => (target, String::new()),
    };

    let mut headers = HashMap::new();
    for line in lines {
        if let Some((k, v)) = line.split_once(':') {
            headers.insert(k.trim().to_string(), v.trim().to_string());
        }
    }

    let content_length = headers
        .iter()
        .find(|(k, _)| k.eq_ignore_ascii_case("Content-Length"))
        .and_then(|(_, v)| v.parse::<usize>().ok())
        .unwrap_or(0);

    while body.len() < content_length {
        let n = stream.read(&mut tmp)?;
        if n == 0 {
            break;
        }
        body.extend_from_slice(&tmp[..n]);
    }
    body.truncate(content_length);

    Ok(Request {
        method,
        path,
        query,
        headers,
        body,
    })
}

/// Plain HTTP client to localhost (talk/mac-use).
pub fn http_exchange(
    method: &str,
    host: &str,
    port: u16,
    path: &str,
    headers: &[(&str, &str)],
    body: &[u8],
    timeout_ms: u64,
) -> Result<(u16, Vec<u8>), String> {
    let mut stream = TcpStream::connect((host, port)).map_err(|e| e.to_string())?;
    stream
        .set_read_timeout(Some(std::time::Duration::from_millis(timeout_ms)))
        .ok();
    stream
        .set_write_timeout(Some(std::time::Duration::from_millis(timeout_ms)))
        .ok();
    write!(
        stream,
        "{} {} HTTP/1.1\r\nHost: {}:{}\r\nConnection: close\r\nContent-Length: {}\r\n",
        method,
        path,
        host,
        port,
        body.len()
    )
    .map_err(|e| e.to_string())?;
    for (k, v) in headers {
        write!(stream, "{}: {}\r\n", k, v).map_err(|e| e.to_string())?;
    }
    write!(stream, "\r\n").map_err(|e| e.to_string())?;
    stream.write_all(body).map_err(|e| e.to_string())?;

    let mut buf = Vec::new();
    stream.read_to_end(&mut buf).map_err(|e| e.to_string())?;
    let header_end = buf
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .ok_or("no response headers")?;
    let header_str = std::str::from_utf8(&buf[..header_end]).map_err(|e| e.to_string())?;
    let status = header_str
        .lines()
        .next()
        .and_then(|l| l.split_whitespace().nth(1))
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    Ok((status, buf[header_end + 4..].to_vec()))
}

pub fn tcp_open(host: &str, port: u16, timeout_ms: u64) -> bool {
    let addr = format!("{host}:{port}");
    let Ok(addrs) = std::net::ToSocketAddrs::to_socket_addrs(&addr) else {
        return false;
    };
    for a in addrs {
        if let Ok(s) = TcpStream::connect_timeout(&a, std::time::Duration::from_millis(timeout_ms))
        {
            drop(s);
            return true;
        }
    }
    false
}
