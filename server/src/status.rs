// Copyright 2026 Traccar Geocoder contributors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

//! Server status for the dashboard and the `/health` endpoint: uptime,
//! request counts per hour, index size and age, and the replication state
//! written by the incremental-update workflow (`<STATE_DIR>/*.state.txt`).

use axum::extract::Extension;
use axum::response::{IntoResponse, Response};
use serde_json::json;
use std::path::Path;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering::Relaxed};
use std::sync::Arc;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use crate::auth::html_escape;

// --- Request counting ---

struct Bucket {
    hour: AtomicU64,
    count: AtomicU32,
}

/// Requests per hour for the last 24 hours, plus a total since start.
/// Each bucket remembers which hour it counts, so a stale bucket from a
/// day ago reads as zero instead of leaking into the chart.
pub struct Stats {
    hours: Vec<Bucket>,
    total: AtomicU64,
}

impl Stats {
    fn new() -> Self {
        Self {
            hours: (0..24).map(|_| Bucket { hour: AtomicU64::new(0), count: AtomicU32::new(0) }).collect(),
            total: AtomicU64::new(0),
        }
    }

    pub fn record(&self) {
        let hour = now_unix() / 3600;
        let b = &self.hours[(hour % 24) as usize];
        if b.hour.load(Relaxed) != hour {
            b.hour.store(hour, Relaxed);
            b.count.store(0, Relaxed);
        }
        b.count.fetch_add(1, Relaxed);
        self.total.fetch_add(1, Relaxed);
    }

    /// Counts for the last 24 hours, oldest first, current hour last.
    pub fn hourly(&self) -> Vec<u32> {
        let now = now_unix() / 3600;
        (0..24)
            .map(|i| {
                let hour = now - 23 + i;
                let b = &self.hours[(hour % 24) as usize];
                if b.hour.load(Relaxed) == hour { b.count.load(Relaxed) } else { 0 }
            })
            .collect()
    }

    pub fn total(&self) -> u64 {
        self.total.load(Relaxed)
    }
}

// --- Status ---

pub struct Status {
    started: Instant,
    started_unix: u64,
    index_dir: String,
    state_dir: Option<String>,
    update_interval: Option<String>,
    pub stats: Stats,
}

pub struct IndexInfo {
    pub files: usize,
    pub size_bytes: u64,
    pub built_unix: Option<u64>,
}

/// One `<basename>.state.txt` written by the entrypoint after an incremental update.
pub struct DataInfo {
    pub basename: String,
    pub osm_timestamp: String,
    pub osm_unix: Option<u64>,
    pub update_count: u32,
    pub sequence_number: String,
}

impl Status {
    /// `index_dir` is where the `.bin` files live. The state directory comes
    /// from `STATE_DIR` or, matching the Docker layout, `<index_dir>/../state`.
    pub fn new(index_dir: &str) -> Self {
        let env = |k: &str| std::env::var(k).ok().map(|v| v.trim().to_string()).filter(|v| !v.is_empty());
        let state_dir = env("STATE_DIR").or_else(|| {
            let sibling = Path::new(index_dir).parent()?.join("state");
            sibling.is_dir().then(|| sibling.to_string_lossy().into_owned())
        });
        Self {
            started: Instant::now(),
            started_unix: now_unix(),
            index_dir: index_dir.to_string(),
            state_dir,
            update_interval: env("UPDATE_INTERVAL"),
            stats: Stats::new(),
        }
    }

    pub fn uptime_secs(&self) -> u64 {
        self.started.elapsed().as_secs()
    }

    pub fn index_info(&self) -> IndexInfo {
        let mut info = IndexInfo { files: 0, size_bytes: 0, built_unix: None };
        if let Ok(entries) = std::fs::read_dir(&self.index_dir) {
            for entry in entries.flatten() {
                if entry.path().extension().map(|e| e == "bin").unwrap_or(false) {
                    if let Ok(meta) = entry.metadata() {
                        info.files += 1;
                        info.size_bytes += meta.len();
                        let mtime = meta.modified().ok().and_then(|t| t.duration_since(UNIX_EPOCH).ok()).map(|d| d.as_secs());
                        if mtime > info.built_unix {
                            info.built_unix = mtime;
                        }
                    }
                }
            }
        }
        info
    }

    pub fn data_info(&self) -> Vec<DataInfo> {
        let mut out = Vec::new();
        let Some(dir) = &self.state_dir else { return out };
        let Ok(entries) = std::fs::read_dir(dir) else { return out };
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            let Some(basename) = name.strip_suffix(".state.txt") else { continue };
            let Ok(text) = std::fs::read_to_string(entry.path()) else { continue };
            let value = |key: &str| {
                text.lines()
                    .find_map(|l| l.strip_prefix(key).and_then(|r| r.strip_prefix('=')))
                    .map(|v| v.trim().to_string())
                    .unwrap_or_default()
            };
            out.push(DataInfo {
                basename: basename.to_string(),
                osm_timestamp: value("last_update_timestamp"),
                osm_unix: value("last_update_unix").parse().ok(),
                update_count: value("update_count").parse().unwrap_or(0),
                sequence_number: value("sequence_number"),
            });
        }
        out.sort_by(|a, b| a.basename.cmp(&b.basename));
        out
    }

    /// Seconds in `UPDATE_INTERVAL` (`30d`, `24h`, `60m`, `300s`), if set and valid.
    fn interval_secs(&self) -> Option<u64> {
        parse_interval(self.update_interval.as_deref()?)
    }

    /// Rough time of the next scheduled update: the entrypoint sleeps one
    /// interval after the server starts or after the previous update.
    fn next_update_unix(&self) -> Option<u64> {
        let interval = self.interval_secs()?;
        let last = self.data_info().iter().filter_map(|d| d.osm_unix).max().unwrap_or(0);
        Some(last.max(self.started_unix) + interval)
    }

    // --- Dashboard fragments ---

    /// Newest OSM data timestamp across all extracts, with a freshness pill.
    pub fn osm_date_html(&self) -> String {
        let data = self.data_info();
        let Some(newest) = data.iter().filter_map(|d| d.osm_unix).max() else {
            return "<span class=\"muted\">n/a</span> <span class=\"pill muted\">no update yet</span>".to_string();
        };
        format!("{} {}", format_date(newest), freshness_pill(newest))
    }

    pub fn uptime_html(&self) -> String {
        html_escape(&format_duration(self.uptime_secs()))
    }

    pub fn hour_bars_html(&self) -> String {
        let hourly = self.stats.hourly();
        let max = hourly.iter().copied().max().unwrap_or(0).max(1);
        let now_hour = now_unix() / 3600;
        let mut s = String::new();
        for (i, n) in hourly.iter().enumerate() {
            let hour = (now_hour - 23 + i as u64) % 24;
            let pct = (*n as f64 / max as f64 * 100.0).round() as u32;
            s.push_str(&format!(
                "<i style=\"height:{}%\" title=\"{:02}:00 UTC: {} request{}\"></i>",
                pct, hour, n, if *n == 1 { "" } else { "s" }
            ));
        }
        s
    }

    pub fn info_rows_html(&self) -> String {
        let mut rows = Vec::new();
        let kv = |k: &str, v: String| format!("<div><b>{}</b>{}</div>", k, v);
        rows.push(kv("Version", html_escape(&format!("query-server {}", env!("CARGO_PKG_VERSION")))));
        rows.push(kv("Uptime", self.uptime_html()));
        rows.push(kv("Requests since start", self.stats.total().to_string()));

        let idx = self.index_info();
        rows.push(kv("Index size", format!("{} &middot; {} files", format_bytes(idx.size_bytes), idx.files)));
        rows.push(kv("Index built", idx.built_unix.map(format_datetime).unwrap_or_else(|| "n/a".to_string())));

        let data = self.data_info();
        if data.is_empty() {
            rows.push(kv(
                "Incremental updates",
                "<span class=\"muted\">none recorded</span>".to_string(),
            ));
        }
        for d in &data {
            rows.push(kv("Extract", html_escape(&d.basename)));
            let when = d.osm_unix.map(format_datetime).unwrap_or_else(|| html_escape(&d.osm_timestamp));
            rows.push(kv(
                "OSM data as of",
                format!("{} {}", when, d.osm_unix.map(freshness_pill).unwrap_or_default()),
            ));
            let seq = if d.sequence_number.is_empty() { String::new() } else { format!(" &middot; seq {}", html_escape(&d.sequence_number)) };
            rows.push(kv("Incremental updates", format!("{} applied{}", d.update_count, seq)));
        }
        match (&self.update_interval, self.next_update_unix()) {
            (Some(iv), Some(next)) => rows.push(kv(
                "Update interval",
                format!("{} &middot; next &asymp; {}", html_escape(iv), format_datetime(next)),
            )),
            (Some(iv), None) => rows.push(kv("Update interval", html_escape(iv))),
            (None, _) => {}
        }
        rows.concat()
    }
}

// --- /health ---

pub async fn health(status: Extension<Arc<Status>>) -> Response {
    let idx = status.index_info();
    let data: Vec<_> = status
        .data_info()
        .iter()
        .map(|d| {
            json!({
                "basename": d.basename,
                "osm_timestamp": d.osm_timestamp,
                "osm_unix": d.osm_unix,
                "update_count": d.update_count,
                "sequence_number": d.sequence_number,
            })
        })
        .collect();
    let body = json!({
        "status": "ok",
        "version": env!("CARGO_PKG_VERSION"),
        "uptime_seconds": status.uptime_secs(),
        "requests_since_start": status.stats.total(),
        "requests_last_24h": status.stats.hourly(),
        "index": {
            "files": idx.files,
            "size_bytes": idx.size_bytes,
            "built_unix": idx.built_unix,
        },
        "data": data,
        "update_interval": status.update_interval,
        "next_update_unix": status.next_update_unix(),
    });
    ([(axum::http::header::CONTENT_TYPE, "application/json")], body.to_string()).into_response()
}

// --- Formatting helpers (no chrono dependency) ---

fn now_unix() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

fn freshness_pill(osm_unix: u64) -> String {
    let age = now_unix().saturating_sub(osm_unix);
    if age < 8 * 86400 {
        "<span class=\"pill\">fresh</span>".to_string()
    } else {
        format!("<span class=\"pill warn\">{} old</span>", format_duration_coarse(age))
    }
}

pub fn parse_interval(s: &str) -> Option<u64> {
    let s = s.trim();
    let (num, mult) = match s.chars().last()? {
        'd' => (&s[..s.len() - 1], 86400),
        'h' => (&s[..s.len() - 1], 3600),
        'm' => (&s[..s.len() - 1], 60),
        's' => (&s[..s.len() - 1], 1),
        _ => (s, 1),
    };
    let n: u64 = num.parse().ok()?;
    (n > 0).then_some(n * mult)
}

/// Days since 1970-01-01 to a civil date (Howard Hinnant's algorithm).
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = (if z >= 0 { z } else { z - 146_096 }) / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

pub fn format_date(unix: u64) -> String {
    let (y, m, d) = civil_from_days((unix / 86400) as i64);
    format!("{:04}-{:02}-{:02}", y, m, d)
}

pub fn format_datetime(unix: u64) -> String {
    let rem = unix % 86400;
    format!("{} {:02}:{:02} UTC", format_date(unix), rem / 3600, (rem % 3600) / 60)
}

pub fn format_duration(secs: u64) -> String {
    let (d, h, m) = (secs / 86400, (secs % 86400) / 3600, (secs % 3600) / 60);
    if d > 0 {
        format!("{} d {} h", d, h)
    } else if h > 0 {
        format!("{} h {} min", h, m)
    } else {
        format!("{} min", m)
    }
}

fn format_duration_coarse(secs: u64) -> String {
    let d = secs / 86400;
    if d >= 60 {
        format!("{} months", d / 30)
    } else if d >= 1 {
        format!("{} days", d)
    } else {
        format!("{} h", secs / 3600)
    }
}

pub fn format_bytes(n: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KB", "MB", "GB", "TB"];
    let mut v = n as f64;
    let mut i = 0;
    while v >= 1024.0 && i < UNITS.len() - 1 {
        v /= 1024.0;
        i += 1;
    }
    if i == 0 { format!("{} B", n) } else { format!("{:.1} {}", v, UNITS[i]) }
}
