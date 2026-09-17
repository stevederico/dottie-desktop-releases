//! Minimal WebSocket (RFC6455) for /v1/realtime.

use std::io::{Read, Write};
use std::net::TcpStream;

use crate::auth;
use crate::json::{self, Value};
use crate::log;
use crate::agent;

/// Handle an HTTP Upgrade request already parsed as `req` on `stream`.
pub fn handle_upgrade(stream: &mut TcpStream, req: &crate::http::Request) -> std::io::Result<()> {
    if let Err(_) = auth::check_auth("GET", "/v1/realtime", req.header("Authorization")) {
        let body = b"unauthorized";
        write!(
            stream,
            "HTTP/1.1 401 Unauthorized\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            body.len()
        )?;
        stream.write_all(body)?;
        return Ok(());
    }

    let key = req
        .header("Sec-WebSocket-Key")
        .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::InvalidData, "missing WS key"))?;
    let accept = accept_key(key);
    write!(
        stream,
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {}\r\n\r\n",
        accept
    )?;

    // Send ready
    let mut ready = Value::obj();
    ready.insert("type", Value::str("ready"));
    send_text(stream, &ready.stringify())?;

    let mut session_id: Option<String> = None;

    loop {
        let frame = match read_frame(stream) {
            Ok(f) => f,
            Err(e) => {
                log::warn("ws", format!("read end: {e}"));
                break;
            }
        };
        match frame.opcode {
            0x8 => {
                // close
                let _ = send_close(stream);
                break;
            }
            0x9 => {
                // ping -> pong
                let _ = send_frame(stream, 0xA, &frame.payload);
            }
            0x1 => {
                // text
                let text = String::from_utf8_lossy(&frame.payload);
                if let Ok(msg) = json::parse(&text) {
                    handle_message(stream, &msg, &mut session_id);
                }
            }
            0x2 => {
                // binary PCM — acknowledge; STT proxy is follow-on work
                let mut ack = Value::obj();
                ack.insert("type", Value::str("input_audio_buffer.committed"));
                let _ = send_text(stream, &ack.stringify());
            }
            _ => {}
        }
    }
    Ok(())
}

fn handle_message(stream: &mut TcpStream, msg: &Value, session_id: &mut Option<String>) {
    let ty = msg.get_str("type").unwrap_or("");
    match ty {
        "ping" => {
            let mut pong = Value::obj();
            pong.insert("type", Value::str("pong"));
            let _ = send_text(stream, &pong.stringify());
        }
        "session.update" | "config" => {
            if let Some(id) = msg.get_str("sessionId").or_else(|| msg.get_str("id")) {
                *session_id = Some(id.to_string());
            }
            if let Err(e) = agent::apply_chat_config_fields(msg) {
                log::warn("ws", format!("config persist: {e}"));
            }
            let mut ok = Value::obj();
            ok.insert("type", Value::str("session.updated"));
            let _ = send_text(stream, &ok.stringify());
        }
        "text.message" => {
            let text = msg.get_str("text").or_else(|| msg.get_str("content")).unwrap_or("");
            let sid = session_id.clone().unwrap_or_else(|| {
                crate::memory::sessions::create_session(Some("Realtime"), None)
                    .ok()
                    .and_then(|s| s.get_str("id").map(|s| s.to_string()))
                    .unwrap_or_else(|| crate::sqlite::new_id())
            });
            *session_id = Some(sid.clone());
            match agent::chat_once(&sid, text) {
                Ok(reply) => {
                    let mut delta = Value::obj();
                    delta.insert("type", Value::str("response.delta"));
                    delta.insert("delta", Value::str(&reply));
                    let _ = send_text(stream, &delta.stringify());
                    let mut done = Value::obj();
                    done.insert("type", Value::str("response.done"));
                    done.insert("text", Value::str(&reply));
                    let _ = send_text(stream, &done.stringify());
                }
                Err(e) => {
                    let mut err = Value::obj();
                    err.insert("type", Value::str("error"));
                    err.insert("error", Value::str(e));
                    let _ = send_text(stream, &err.stringify());
                }
            }
        }
        "conversation.clear" => {
            let mut ok = Value::obj();
            ok.insert("type", Value::str("conversation.cleared"));
            let _ = send_text(stream, &ok.stringify());
        }
        _ => {
            log::debug("ws", format!("unhandled type {ty}"));
        }
    }
}

struct Frame {
    opcode: u8,
    payload: Vec<u8>,
}

fn read_frame(stream: &mut TcpStream) -> std::io::Result<Frame> {
    let mut hdr = [0u8; 2];
    stream.read_exact(&mut hdr)?;
    let opcode = hdr[0] & 0x0f;
    let masked = (hdr[1] & 0x80) != 0;
    let mut len = (hdr[1] & 0x7f) as u64;
    if len == 126 {
        let mut ext = [0u8; 2];
        stream.read_exact(&mut ext)?;
        len = u16::from_be_bytes(ext) as u64;
    } else if len == 127 {
        let mut ext = [0u8; 8];
        stream.read_exact(&mut ext)?;
        len = u64::from_be_bytes(ext);
    }
    let mut mask = [0u8; 4];
    if masked {
        stream.read_exact(&mut mask)?;
    }
    let mut payload = vec![0u8; len as usize];
    if len > 0 {
        stream.read_exact(&mut payload)?;
    }
    if masked {
        for i in 0..payload.len() {
            payload[i] ^= mask[i % 4];
        }
    }
    Ok(Frame { opcode, payload })
}

fn send_text(stream: &mut TcpStream, text: &str) -> std::io::Result<()> {
    send_frame(stream, 0x1, text.as_bytes())
}

fn send_close(stream: &mut TcpStream) -> std::io::Result<()> {
    send_frame(stream, 0x8, &[])
}

fn send_frame(stream: &mut TcpStream, opcode: u8, payload: &[u8]) -> std::io::Result<()> {
    let mut out = Vec::with_capacity(payload.len() + 10);
    out.push(0x80 | (opcode & 0x0f));
    let len = payload.len();
    if len < 126 {
        out.push(len as u8);
    } else if len < 65536 {
        out.push(126);
        out.extend_from_slice(&(len as u16).to_be_bytes());
    } else {
        out.push(127);
        out.extend_from_slice(&(len as u64).to_be_bytes());
    }
    out.extend_from_slice(payload);
    stream.write_all(&out)
}

fn accept_key(key: &str) -> String {
    // SHA1(key + magic) then base64 — hand-rolled
    const MAGIC: &str = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    let mut data = Vec::new();
    data.extend_from_slice(key.as_bytes());
    data.extend_from_slice(MAGIC.as_bytes());
    let hash = sha1(&data);
    base64_encode(&hash)
}

fn sha1(message: &[u8]) -> [u8; 20] {
    // Minimal SHA-1 (FIPS 180-1)
    let mut msg = message.to_vec();
    let bit_len = (message.len() as u64) * 8;
    msg.push(0x80);
    while (msg.len() % 64) != 56 {
        msg.push(0);
    }
    msg.extend_from_slice(&bit_len.to_be_bytes());

    let mut h0: u32 = 0x67452301;
    let mut h1: u32 = 0xEFCDAB89;
    let mut h2: u32 = 0x98BADCFE;
    let mut h3: u32 = 0x10325476;
    let mut h4: u32 = 0xC3D2E1F0;

    for chunk in msg.chunks(64) {
        let mut w = [0u32; 80];
        for i in 0..16 {
            w[i] = u32::from_be_bytes([
                chunk[i * 4],
                chunk[i * 4 + 1],
                chunk[i * 4 + 2],
                chunk[i * 4 + 3],
            ]);
        }
        for i in 16..80 {
            w[i] = (w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]).rotate_left(1);
        }
        let (mut a, mut b, mut c, mut d, mut e) = (h0, h1, h2, h3, h4);
        for i in 0..80 {
            let (f, k) = match i {
                0..=19 => ((b & c) | ((!b) & d), 0x5A827999),
                20..=39 => (b ^ c ^ d, 0x6ED9EBA1),
                40..=59 => ((b & c) | (b & d) | (c & d), 0x8F1BBCDC),
                _ => (b ^ c ^ d, 0xCA62C1D6),
            };
            let temp = a
                .rotate_left(5)
                .wrapping_add(f)
                .wrapping_add(e)
                .wrapping_add(k)
                .wrapping_add(w[i]);
            e = d;
            d = c;
            c = b.rotate_left(30);
            b = a;
            a = temp;
        }
        h0 = h0.wrapping_add(a);
        h1 = h1.wrapping_add(b);
        h2 = h2.wrapping_add(c);
        h3 = h3.wrapping_add(d);
        h4 = h4.wrapping_add(e);
    }
    let mut out = [0u8; 20];
    out[0..4].copy_from_slice(&h0.to_be_bytes());
    out[4..8].copy_from_slice(&h1.to_be_bytes());
    out[8..12].copy_from_slice(&h2.to_be_bytes());
    out[12..16].copy_from_slice(&h3.to_be_bytes());
    out[16..20].copy_from_slice(&h4.to_be_bytes());
    out
}

fn base64_encode(data: &[u8]) -> String {
    const T: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    let mut i = 0;
    while i + 3 <= data.len() {
        let n = ((data[i] as u32) << 16) | ((data[i + 1] as u32) << 8) | (data[i + 2] as u32);
        out.push(T[((n >> 18) & 63) as usize] as char);
        out.push(T[((n >> 12) & 63) as usize] as char);
        out.push(T[((n >> 6) & 63) as usize] as char);
        out.push(T[(n & 63) as usize] as char);
        i += 3;
    }
    let rem = data.len() - i;
    if rem == 1 {
        let n = (data[i] as u32) << 16;
        out.push(T[((n >> 18) & 63) as usize] as char);
        out.push(T[((n >> 12) & 63) as usize] as char);
        out.push('=');
        out.push('=');
    } else if rem == 2 {
        let n = ((data[i] as u32) << 16) | ((data[i + 1] as u32) << 8);
        out.push(T[((n >> 18) & 63) as usize] as char);
        out.push(T[((n >> 12) & 63) as usize] as char);
        out.push(T[((n >> 6) & 63) as usize] as char);
        out.push('=');
    }
    out
}
