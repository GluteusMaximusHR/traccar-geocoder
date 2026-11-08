use axum::extract::{Extension, Form, Path, State};
use axum::http::header::SET_COOKIE;
use axum::http::HeaderMap;
use axum::http::StatusCode;
use axum::response::{Html, IntoResponse, Redirect, Response};
use axum::routing::{get, post};
use axum::Router;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fmt::Write;
use std::fs;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering::Relaxed};
use std::sync::{Arc, RwLock};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::branding::Pages;
use crate::status::Status;

// --- Data model ---

#[derive(Serialize, Deserialize, Clone)]
pub struct User {
    password_hash: String,
    admin: bool,
    rate_per_second: u32,
    rate_per_day: u32,
    #[serde(default)]
    rate_by_ip: bool,
}

pub struct RateState {
    second_count: AtomicU32,
    second_ts: AtomicU64,
    day_count: AtomicU32,
    day_ts: AtomicU32,
}

impl Default for RateState {
    fn default() -> Self {
        Self {
            second_count: AtomicU32::new(0),
            second_ts: AtomicU64::new(0),
            day_count: AtomicU32::new(0),
            day_ts: AtomicU32::new(0),
        }
    }
}

pub type RateLimiter = RwLock<HashMap<String, Arc<RateState>>>;

#[derive(Serialize, Deserialize, Default)]
pub struct Db {
    users: HashMap<String, User>,
    tokens: HashMap<String, String>, // token -> login
    #[serde(skip)]
    sessions: HashMap<String, String>, // session_id -> login (in-memory only)
    #[serde(skip)]
    path: String,
}

impl Db {
    pub fn load(path: &str) -> Self {
        let mut db = match fs::read_to_string(path) {
            Ok(data) => serde_json::from_str(&data).unwrap_or_default(),
            Err(_) => Db::default(),
        };
        db.path = path.to_string();
        db
    }

    fn save(&self) {
        let data = serde_json::to_string_pretty(self).unwrap();
        fs::write(&self.path, data).expect("Failed to save database");
    }

    fn create_user(&mut self, login: &str, password: &str, admin: bool, rate_per_second: u32, rate_per_day: u32, rate_by_ip: bool) {
        let hash = bcrypt::hash(password, bcrypt::DEFAULT_COST).expect("bcrypt hash failed");
        self.users.insert(login.to_string(), User {
            password_hash: hash,
            admin,
            rate_per_second,
            rate_per_day,
            rate_by_ip,
        });
        self.save();
    }

    pub fn validate_token(&self, key: &str) -> Option<(String, u32, u32, bool)> {
        let login = self.tokens.get(key)?;
        let user = self.users.get(login)?;
        Some((login.clone(), user.rate_per_second, user.rate_per_day, user.rate_by_ip))
    }
}

pub fn check_rate(limiter: &RateLimiter, login: &str, rate_per_second: u32, rate_per_day: u32) -> Result<(), &'static str> {
    let state = {
        let map = limiter.read().unwrap();
        if let Some(s) = map.get(login) {
            Arc::clone(s)
        } else {
            drop(map);
            let mut map = limiter.write().unwrap();
            Arc::clone(map.entry(login.to_string()).or_default())
        }
    };

    let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap();
    let now_secs = now.as_secs();
    let now_day = (now_secs / 86400) as u32;

    if state.second_ts.load(Relaxed) != now_secs {
        state.second_ts.store(now_secs, Relaxed);
        state.second_count.store(0, Relaxed);
    }
    if state.day_ts.load(Relaxed) != now_day {
        state.day_ts.store(now_day, Relaxed);
        state.day_count.store(0, Relaxed);
    }

    // Count every request, even for users without limits, so the dashboard
    // can show today's usage. A request rejected by the per-second limit is
    // not counted against the day, as before.
    let second_count = state.second_count.fetch_add(1, Relaxed);
    if rate_per_second > 0 && second_count >= rate_per_second {
        return Err("Rate limit exceeded (per second)");
    }
    let day_count = state.day_count.fetch_add(1, Relaxed);
    if rate_per_day > 0 && day_count >= rate_per_day {
        return Err("Rate limit exceeded (per day)");
    }

    Ok(())
}

fn random_hex(len: usize) -> String {
    let mut bytes = vec![0u8; len];
    getrandom::fill(&mut bytes).expect("getrandom failed");
    let mut s = String::with_capacity(len * 2);
    for b in &bytes {
        write!(s, "{:02x}", b).unwrap();
    }
    s
}

fn get_session_cookie(headers: &HeaderMap) -> Option<String> {
    headers
        .get_all("cookie")
        .iter()
        .filter_map(|v| v.to_str().ok())
        .flat_map(|s| s.split(';'))
        .map(|s| s.trim())
        .find_map(|s| s.strip_prefix("session=").map(|v| v.to_string()))
}

fn set_session_cookie(value: &str) -> ([(axum::http::header::HeaderName, String); 1],) {
    ([(SET_COOKIE, format!("session={}; Path=/; HttpOnly", value))],)
}

fn clear_session_cookie() -> ([(axum::http::header::HeaderName, String); 1],) {
    ([(SET_COOKIE, "session=; Path=/; HttpOnly; Max-Age=0".to_string())],)
}

// --- Router ---

pub fn router() -> Router<Arc<RwLock<Db>>> {
    Router::new()
        .route("/", get(dashboard))
        .route("/login", get(login_page).post(login_submit))
        .route("/logout", get(logout))
        .route("/password", post(change_password))
        .route("/tokens", post(create_token))
        .route("/tokens/{token}/delete", get(delete_token))
        .route("/users", post(create_user_handler))
        .route("/users/{login}/delete", get(delete_user))
}

// --- Handlers ---

#[derive(Deserialize)]
struct LoginForm {
    login: String,
    password: String,
}

async fn login_page(headers: HeaderMap, state: State<Arc<RwLock<Db>>>, pages: Extension<Arc<Pages>>) -> Response {
    if let Some(session_id) = get_session_cookie(&headers) {
        let db = state.read().unwrap();
        if db.sessions.contains_key(&session_id) {
            return Redirect::to("/").into_response();
        }
    }
    Html(pages.login.replace("{error}", "")).into_response()
}

async fn login_submit(state: State<Arc<RwLock<Db>>>, pages: Extension<Arc<Pages>>, Form(form): Form<LoginForm>) -> Response {
    let mut db = state.write().unwrap();

    // First login ever — create admin account
    if db.users.is_empty() {
        db.create_user(&form.login, &form.password, true, 0, 0, false);
    }

    if let Some(user) = db.users.get(&form.login) {
        if bcrypt::verify(&form.password, &user.password_hash).unwrap_or(false) {
            let session_id = random_hex(32);
            db.sessions.insert(session_id.clone(), form.login);
            let (cookie,) = set_session_cookie(&session_id);
            return (cookie, Redirect::to("/")).into_response();
        }
    }
    Html(pages.login.replace("{error}", "<div class=\"error\">Invalid credentials</div>")).into_response()
}

async fn logout(headers: HeaderMap, state: State<Arc<RwLock<Db>>>) -> Response {
    if let Some(session_id) = get_session_cookie(&headers) {
        let mut db = state.write().unwrap();
        db.sessions.remove(&session_id);
    }
    let (cookie,) = clear_session_cookie();
    (cookie, Redirect::to("/login")).into_response()
}

#[derive(Deserialize)]
struct PasswordForm {
    current_password: String,
    new_password: String,
}

async fn change_password(headers: HeaderMap, state: State<Arc<RwLock<Db>>>, Form(form): Form<PasswordForm>) -> Response {
    let mut db = state.write().unwrap();
    let login = get_session_cookie(&headers).and_then(|id| db.sessions.get(&id).cloned());
    if let Some(user) = login.and_then(|login| db.users.get_mut(&login)) {
        if !form.new_password.is_empty() && bcrypt::verify(&form.current_password, &user.password_hash).unwrap_or(false) {
            user.password_hash = bcrypt::hash(&form.new_password, bcrypt::DEFAULT_COST).expect("bcrypt hash failed");
            db.save();
            return Redirect::to("/").into_response();
        }
    }
    StatusCode::BAD_REQUEST.into_response()
}

/// Requests today for a login: its own counter plus, for "by IP" users, one
/// counter per client address (rate keys look like `login:ip`).
fn requests_today(limiter: &RateLimiter, login: &str) -> u64 {
    let now_day = (SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs() / 86400) as u32;
    let prefix = format!("{}:", login);
    let map = limiter.read().unwrap();
    map.iter()
        .filter(|(key, _)| key.as_str() == login || key.starts_with(&prefix))
        .filter(|(_, s)| s.day_ts.load(Relaxed) == now_day)
        .map(|(_, s)| s.day_count.load(Relaxed) as u64)
        .sum()
}

async fn dashboard(
    headers: HeaderMap,
    state: State<Arc<RwLock<Db>>>,
    limiter: Extension<Arc<RateLimiter>>,
    pages: Extension<Arc<Pages>>,
    status: Extension<Arc<Status>>,
) -> Response {
    let session_id = match get_session_cookie(&headers) {
        Some(s) => s,
        None => return Redirect::to("/login").into_response(),
    };

    let db = state.read().unwrap();
    let login = match db.sessions.get(&session_id) {
        Some(l) => l.clone(),
        None => return Redirect::to("/login").into_response(),
    };

    let is_admin = db.users.get(&login).map(|u| u.admin).unwrap_or(false);

    let mut tokens: Vec<&String> = db.tokens.iter().filter(|(_, owner)| *owner == &login).map(|(t, _)| t).collect();
    tokens.sort();
    let mut rows = String::new();
    for token in &tokens {
        let t = html_escape(token);
        rows.push_str(&format!(
            "<tr><td><code data-key=\"{t}\">{t}</code></td>\
             <td class=\"actions\">\
             <button type=\"button\" class=\"btn ghost sm\" data-copy=\"{t}\" onclick=\"copyText(this)\">Copy</button> \
             <a class=\"btn danger sm\" href=\"/tokens/{t}/delete\" onclick=\"return confirm('Delete this API key? Clients using it will get 401.')\">Delete</a>\
             </td></tr>",
        ));
    }
    if tokens.is_empty() {
        rows.push_str("<tr><td class=\"empty\" colspan=\"2\">No API keys yet.</td></tr>");
    }

    let mut user_rows = String::new();
    if is_admin {
        let mut users: Vec<(&String, &User)> = db.users.iter().collect();
        users.sort_by(|a, b| a.0.cmp(b.0));
        for (ulogin, user) in users {
            let role = if user.admin { "Admin" } else { "User" };
            let delete = if ulogin != &login {
                format!(
                    "<a class=\"btn danger sm\" href=\"/users/{}/delete\" onclick=\"return confirm('Delete user {} and all of their API keys?')\">Delete</a>",
                    html_escape(ulogin),
                    html_escape(&ulogin.replace('\'', "\\'")),
                )
            } else {
                String::new()
            };
            let by_ip = if user.rate_by_ip { "Yes" } else { "" };
            let today = requests_today(&limiter, ulogin);
            let meter = if user.rate_per_day > 0 && !user.rate_by_ip {
                let pct = (today * 100 / user.rate_per_day as u64).min(100);
                format!(" <span class=\"meter\" title=\"{}% of the daily limit\"><i style=\"width:{}%\"></i></span>", pct, pct)
            } else {
                String::new()
            };
            user_rows.push_str(&format!(
                "<tr><td>{}</td><td>{}</td><td>{}</td><td>{}</td><td>{}</td><td>{}{}</td><td class=\"actions\">{}</td></tr>",
                html_escape(ulogin), role, user.rate_per_second, user.rate_per_day, by_ip, today, meter, delete
            ));
        }
    }

    let daily_usage = requests_today(&limiter, &login);

    let html = pages
        .dashboard
        .replace("{user}", &html_escape(&login))
        .replace("{rows}", &rows)
        .replace("{user_rows}", &user_rows)
        .replace("{daily_usage}", &daily_usage.to_string())
        .replace("{key_count}", &tokens.len().to_string())
        .replace("{osm_date}", &status.osm_date_html())
        .replace("{uptime}", &status.uptime_html())
        .replace("{hour_bars}", &status.hour_bars_html())
        .replace("{info_rows}", &status.info_rows_html())
        .replace("{users_display}", if is_admin { "" } else { "display:none" });
    Html(html).into_response()
}

async fn create_token(headers: HeaderMap, state: State<Arc<RwLock<Db>>>) -> Response {
    let session_id = match get_session_cookie(&headers) {
        Some(s) => s,
        None => return Redirect::to("/login").into_response(),
    };

    let mut db = state.write().unwrap();
    if let Some(login) = db.sessions.get(&session_id).cloned() {
        let token = random_hex(16);
        db.tokens.insert(token, login);
        db.save();
    }
    Redirect::to("/").into_response()
}

async fn delete_token(
    headers: HeaderMap,
    state: State<Arc<RwLock<Db>>>,
    Path(token): Path<String>,
) -> Response {
    let session_id = match get_session_cookie(&headers) {
        Some(s) => s,
        None => return Redirect::to("/login").into_response(),
    };

    let mut db = state.write().unwrap();
    if let Some(login) = db.sessions.get(&session_id) {
        if db.tokens.get(&token).map(|o| o == login).unwrap_or(false) {
            db.tokens.remove(&token);
            db.save();
        }
    }
    Redirect::to("/").into_response()
}

#[derive(Deserialize)]
struct CreateUserForm {
    login: String,
    password: String,
    rate_per_second: u32,
    rate_per_day: u32,
    #[serde(default)]
    rate_by_ip: Option<String>,
}

async fn create_user_handler(headers: HeaderMap, state: State<Arc<RwLock<Db>>>, Form(form): Form<CreateUserForm>) -> Response {
    let session_id = match get_session_cookie(&headers) {
        Some(s) => s,
        None => return Redirect::to("/login").into_response(),
    };

    let mut db = state.write().unwrap();
    if let Some(login) = db.sessions.get(&session_id).cloned() {
        let is_admin = db.users.get(&login).map(|u| u.admin).unwrap_or(false);
        if is_admin && !form.login.is_empty() && !form.password.is_empty() {
            db.create_user(&form.login, &form.password, false, form.rate_per_second, form.rate_per_day, form.rate_by_ip.as_deref() == Some("on"));
        }
    }
    Redirect::to("/").into_response()
}

async fn delete_user(
    headers: HeaderMap,
    state: State<Arc<RwLock<Db>>>,
    Path(target): Path<String>,
) -> Response {
    let session_id = match get_session_cookie(&headers) {
        Some(s) => s,
        None => return Redirect::to("/login").into_response(),
    };

    let mut db = state.write().unwrap();
    if let Some(login) = db.sessions.get(&session_id).cloned() {
        let is_admin = db.users.get(&login).map(|u| u.admin).unwrap_or(false);
        if is_admin && target != login {
            db.users.remove(&target);
            db.tokens.retain(|_, owner| owner != &target);
            db.save();
        }
    }
    Redirect::to("/").into_response()
}

pub(crate) fn html_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

/// Page templates; `Branding::render_pages` fills the `{brand_*}` placeholders at startup.
pub const LOGIN_HTML: &str = include_str!("web/login.html");
pub const DASHBOARD_HTML: &str = include_str!("web/dashboard.html");
