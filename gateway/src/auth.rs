//! Bearer-token auth — mirrors `auth.js` (constant-time, fail-closed).

use crate::token;

/// Constant-time UTF-8 equality. Length mismatch returns false without byte compare.
pub fn constant_time_equal(a: &str, b: &str) -> bool {
    let ab = a.as_bytes();
    let bb = b.as_bytes();
    if ab.len() != bb.len() {
        return false;
    }
    let mut diff: u8 = 0;
    for i in 0..ab.len() {
        diff |= ab[i] ^ bb[i];
    }
    diff == 0
}

/// Requires `Authorization: Bearer <token>`; rejects empty/whitespace tokens.
pub fn bearer_token_matches(auth_header: Option<&str>, token: &str) -> bool {
    let Some(header) = auth_header else {
        return false;
    };
    let Some(presented) = header.strip_prefix("Bearer ") else {
        return false;
    };
    if presented.trim().is_empty() || token.trim().is_empty() {
        return false;
    }
    constant_time_equal(presented, token)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AuthFail {
    TokenUnreadable,
    BadToken,
}

/// GET /health is auth-exempt. Token file unreadable → fail closed.
pub fn check_auth(method: &str, path: &str, auth_header: Option<&str>) -> Result<(), AuthFail> {
    if method == "GET" && path == "/health" {
        return Ok(());
    }
    let token = match token::read_agent_token_cached() {
        Ok(t) => t,
        Err(_) => return Err(AuthFail::TokenUnreadable),
    };
    if !bearer_token_matches(auth_header, &token) {
        return Err(AuthFail::BadToken);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bearer_rejects_missing_prefix() {
        assert!(!bearer_token_matches(Some("tok"), "tok"));
    }

    #[test]
    fn bearer_rejects_empty() {
        assert!(!bearer_token_matches(Some("Bearer "), "abc"));
        assert!(!bearer_token_matches(Some("Bearer abc"), ""));
        assert!(!bearer_token_matches(Some("Bearer   "), "abc"));
    }

    #[test]
    fn bearer_accepts_exact() {
        assert!(bearer_token_matches(Some("Bearer secret"), "secret"));
    }

    #[test]
    fn bearer_rejects_mismatch() {
        assert!(!bearer_token_matches(Some("Bearer secret"), "secreX"));
        assert!(!bearer_token_matches(Some("Bearer short"), "longer-token"));
    }

    #[test]
    fn health_exempt() {
        assert!(check_auth("GET", "/health", None).is_ok());
    }

    #[test]
    fn constant_time_length_guard() {
        assert!(!constant_time_equal("a", "ab"));
        assert!(constant_time_equal("same", "same"));
    }
}
