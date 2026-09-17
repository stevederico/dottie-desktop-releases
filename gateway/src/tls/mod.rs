//! libcurl FFI HTTPS client (system libcurl on macOS).

use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_long, c_void};
use std::ptr;
use std::sync::Mutex;

#[repr(C)]
struct Curl {
    _private: [u8; 0],
}

type CurlCode = i32;
const CURLE_OK: CurlCode = 0;
const CURLOPT_URL: c_long = 10002;
const CURLOPT_HTTPHEADER: c_long = 10023;
const CURLOPT_POST: c_long = 47;
const CURLOPT_POSTFIELDS: c_long = 10015;
const CURLOPT_POSTFIELDSIZE: c_long = 60;
const CURLOPT_WRITEFUNCTION: c_long = 20011;
const CURLOPT_WRITEDATA: c_long = 10001;
const CURLOPT_TIMEOUT: c_long = 13;
const CURLOPT_FOLLOWLOCATION: c_long = 52;
const CURLOPT_CUSTOMREQUEST: c_long = 10036;
const CURLOPT_HTTPGET: c_long = 80;
const CURLINFO_RESPONSE_CODE: c_long = 0x200000 + 2;

#[link(name = "curl")]
unsafe extern "C" {
    fn curl_global_init(flags: c_long) -> CurlCode;
    fn curl_easy_init() -> *mut Curl;
    fn curl_easy_cleanup(curl: *mut Curl);
    fn curl_easy_setopt(curl: *mut Curl, option: c_long, ...) -> CurlCode;
    fn curl_easy_perform(curl: *mut Curl) -> CurlCode;
    fn curl_easy_getinfo(curl: *mut Curl, info: c_long, ...) -> CurlCode;
    fn curl_slist_append(list: *mut c_void, hdr: *const c_char) -> *mut c_void;
    fn curl_slist_free_all(list: *mut c_void);
    fn curl_easy_strerror(code: CurlCode) -> *const c_char;
}

static INIT: Mutex<bool> = Mutex::new(false);

pub fn ensure_curl() {
    let mut g = INIT.lock().unwrap();
    if !*g {
        unsafe {
            curl_global_init(3);
        }
        *g = true;
    }
}

unsafe extern "C" fn write_cb(
    data: *mut c_char,
    size: usize,
    nmemb: usize,
    userdata: *mut c_void,
) -> usize {
    let n = size * nmemb;
    if userdata.is_null() || data.is_null() {
        return 0;
    }
    let buf = &mut *(userdata as *mut Vec<u8>);
    buf.extend_from_slice(std::slice::from_raw_parts(data as *const u8, n));
    n
}

struct StreamState {
    on_chunk: Box<dyn FnMut(&[u8]) + Send>,
}

unsafe extern "C" fn stream_cb(
    data: *mut c_char,
    size: usize,
    nmemb: usize,
    userdata: *mut c_void,
) -> usize {
    let n = size * nmemb;
    if userdata.is_null() || data.is_null() {
        return 0;
    }
    let st = &mut *(userdata as *mut StreamState);
    (st.on_chunk)(std::slice::from_raw_parts(data as *const u8, n));
    n
}

pub struct HttpsResponse {
    pub status: u16,
    pub body: Vec<u8>,
}

pub fn request(
    method: &str,
    url: &str,
    headers: &[(&str, &str)],
    body: Option<&[u8]>,
    timeout_secs: i64,
) -> Result<HttpsResponse, String> {
    ensure_curl();
    unsafe {
        let curl = curl_easy_init();
        if curl.is_null() {
            return Err("curl_easy_init failed".into());
        }
        let url_c = CString::new(url).map_err(|e| e.to_string())?;
        curl_easy_setopt(curl, CURLOPT_URL, url_c.as_ptr());
        curl_easy_setopt(curl, CURLOPT_TIMEOUT, timeout_secs as c_long);
        curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1i64);

        let mut list: *mut c_void = ptr::null_mut();
        let mut owned = Vec::new();
        for (k, v) in headers {
            let h = CString::new(format!("{k}: {v}")).map_err(|e| e.to_string())?;
            list = curl_slist_append(list, h.as_ptr());
            owned.push(h);
        }
        if !list.is_null() {
            curl_easy_setopt(curl, CURLOPT_HTTPHEADER, list);
        }

        let method_u = method.to_ascii_uppercase();
        let custom;
        match method_u.as_str() {
            "GET" => {
                curl_easy_setopt(curl, CURLOPT_HTTPGET, 1i64);
            }
            "POST" => {
                curl_easy_setopt(curl, CURLOPT_POST, 1i64);
                if let Some(b) = body {
                    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, b.as_ptr());
                    curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, b.len() as c_long);
                }
            }
            other => {
                custom = CString::new(other).unwrap();
                curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, custom.as_ptr());
                if let Some(b) = body {
                    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, b.as_ptr());
                    curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, b.len() as c_long);
                }
                // keep custom alive via owned
                owned.push(custom);
            }
        }

        let mut buf = Vec::new();
        curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_cb as *const ());
        curl_easy_setopt(curl, CURLOPT_WRITEDATA, &mut buf as *mut _ as *mut c_void);

        let code = curl_easy_perform(curl);
        if code != CURLE_OK {
            let err = CStr::from_ptr(curl_easy_strerror(code))
                .to_string_lossy()
                .into_owned();
            curl_slist_free_all(list);
            curl_easy_cleanup(curl);
            return Err(err);
        }
        let mut status: c_long = 0;
        curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &mut status as *mut c_long);
        curl_slist_free_all(list);
        curl_easy_cleanup(curl);
        drop(owned);
        Ok(HttpsResponse {
            status: status as u16,
            body: buf,
        })
    }
}

pub fn post_stream(
    url: &str,
    headers: &[(&str, &str)],
    body: &[u8],
    timeout_secs: i64,
    on_chunk: impl FnMut(&[u8]) + Send + 'static,
) -> Result<u16, String> {
    ensure_curl();
    unsafe {
        let curl = curl_easy_init();
        if curl.is_null() {
            return Err("curl_easy_init failed".into());
        }
        let url_c = CString::new(url).map_err(|e| e.to_string())?;
        curl_easy_setopt(curl, CURLOPT_URL, url_c.as_ptr());
        curl_easy_setopt(curl, CURLOPT_TIMEOUT, timeout_secs as c_long);
        curl_easy_setopt(curl, CURLOPT_POST, 1i64);
        curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body.as_ptr());
        curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, body.len() as c_long);

        let mut list: *mut c_void = ptr::null_mut();
        let mut owned = Vec::new();
        for (k, v) in headers {
            let h = CString::new(format!("{k}: {v}")).map_err(|e| e.to_string())?;
            list = curl_slist_append(list, h.as_ptr());
            owned.push(h);
        }
        if !list.is_null() {
            curl_easy_setopt(curl, CURLOPT_HTTPHEADER, list);
        }

        let mut state = StreamState {
            on_chunk: Box::new(on_chunk),
        };
        curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, stream_cb as *const ());
        curl_easy_setopt(
            curl,
            CURLOPT_WRITEDATA,
            &mut state as *mut _ as *mut c_void,
        );

        let code = curl_easy_perform(curl);
        if code != CURLE_OK {
            let err = CStr::from_ptr(curl_easy_strerror(code))
                .to_string_lossy()
                .into_owned();
            curl_slist_free_all(list);
            curl_easy_cleanup(curl);
            return Err(err);
        }
        let mut status: c_long = 0;
        curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &mut status as *mut c_long);
        curl_slist_free_all(list);
        curl_easy_cleanup(curl);
        drop(owned);
        Ok(status as u16)
    }
}
