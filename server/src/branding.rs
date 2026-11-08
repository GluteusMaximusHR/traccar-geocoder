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

//! White-label branding for the web UI.
//!
//! Everything is read once at startup from environment variables, so the
//! defaults (product name "Geocoder", a neutral accent colour, a generic map
//! pin as the logo) are what you get when nothing is configured:
//!
//! | Variable          | Meaning                                                   |
//! |-------------------|-----------------------------------------------------------|
//! | `BRAND_NAME`      | Product name in the page title and header                 |
//! | `BRAND_COLOR`     | CSS colour for buttons, links and the header accent       |
//! | `BRAND_URL`       | Where the header logo links to (default `/`)              |
//! | `BRAND_LOGO`      | Path to an image file shown instead of the name           |
//! | `BRAND_LOGO_DARK` | Optional variant of the logo for dark colour schemes      |
//! | `BRAND_FAVICON`   | Path to the favicon (default: the logo, or the pin)       |
//! | `BRAND_FOOTER`    | Plain-text footer line, e.g. the operator's company name  |
//!
//! Files are read into memory and served from `/brand/logo`,
//! `/brand/logo-dark` and `/brand/favicon`. The HTML templates contain
//! `{brand_*}` placeholders that are filled once, at startup.

use axum::body::Bytes;
use axum::extract::Extension;
use axum::http::header::{CACHE_CONTROL, CONTENT_TYPE};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::Router;
use std::sync::Arc;

use crate::auth::html_escape;

pub const DEFAULT_NAME: &str = "Geocoder";
pub const DEFAULT_COLOR: &str = "#4f6ee0";
const UPSTREAM_URL: &str = "https://github.com/traccar/traccar-geocoder";

const STYLE_CSS: &str = include_str!("web/style.css");

pub struct Asset {
    bytes: Bytes,
    mime: &'static str,
}

pub struct Branding {
    pub name: String,
    pub color: String,
    pub url: String,
    pub footer: String,
    logo: Option<Asset>,
    logo_dark: Option<Asset>,
    favicon: Option<Asset>,
}

/// The two HTML pages with the branding placeholders already filled in.
/// Per-request placeholders (`{user}`, `{rows}`, ...) are left for the handlers.
pub struct Pages {
    pub login: String,
    pub dashboard: String,
}

impl Branding {
    pub fn from_env() -> Self {
        let var = |key: &str| {
            std::env::var(key).ok().map(|v| v.trim().to_string()).filter(|v| !v.is_empty())
        };
        let load = |key: &str| {
            let path = var(key)?;
            match std::fs::read(&path) {
                Ok(bytes) => Some(Asset { bytes: Bytes::from(bytes), mime: mime_for(&path) }),
                Err(e) => {
                    eprintln!("Warning: {}={}: {} (ignored)", key, path, e);
                    None
                }
            }
        };
        let color = match var("BRAND_COLOR") {
            Some(c) if is_safe_color(&c) => c,
            Some(c) => {
                eprintln!("Warning: BRAND_COLOR={:?} is not a plain CSS colour (ignored)", c);
                DEFAULT_COLOR.to_string()
            }
            None => DEFAULT_COLOR.to_string(),
        };
        Self {
            name: var("BRAND_NAME").unwrap_or_else(|| DEFAULT_NAME.to_string()),
            color,
            url: var("BRAND_URL").unwrap_or_else(|| "/".to_string()),
            footer: var("BRAND_FOOTER").unwrap_or_default(),
            logo: load("BRAND_LOGO"),
            logo_dark: load("BRAND_LOGO_DARK"),
            favicon: load("BRAND_FAVICON"),
        }
    }

    pub fn describe(&self) -> String {
        format!(
            "name={:?} color={} logo={} favicon={}",
            self.name,
            self.color,
            if self.logo.is_some() { "custom" } else { "default" },
            if self.favicon.is_some() { "custom" } else if self.logo.is_some() { "logo" } else { "default" },
        )
    }

    /// Fill the `{brand_*}` and `{style}` placeholders of both templates.
    pub fn render_pages(&self, login_template: &str, dashboard_template: &str) -> Pages {
        Pages {
            login: self.render(login_template),
            dashboard: self.render(dashboard_template),
        }
    }

    fn render(&self, template: &str) -> String {
        template
            .replace("{style}", STYLE_CSS)
            .replace("{brand_name}", &html_escape(&self.name))
            .replace("{brand_color}", &self.color)
            .replace("{brand_url}", &html_escape(&self.url))
            .replace("{brand_logo}", &self.logo_html())
            .replace("{brand_favicon}", &self.favicon_html())
            .replace("{brand_footer}", &self.footer_html())
    }

    fn logo_html(&self) -> String {
        let name = html_escape(&self.name);
        match (&self.logo, &self.logo_dark) {
            (Some(_), Some(_)) => format!(
                "<picture><source srcset=\"/brand/logo-dark\" media=\"(prefers-color-scheme: dark)\">\
                 <img src=\"/brand/logo\" alt=\"{}\"></picture>",
                name
            ),
            (Some(_), None) => format!("<img src=\"/brand/logo\" alt=\"{}\">", name),
            (None, _) => format!("{}<span>{}</span>", PIN_SVG, name),
        }
    }

    fn favicon_html(&self) -> String {
        if let Some(f) = &self.favicon {
            format!("<link rel=\"icon\" href=\"/brand/favicon\" type=\"{}\">", f.mime)
        } else if let Some(l) = &self.logo {
            format!("<link rel=\"icon\" href=\"/brand/logo\" type=\"{}\">", l.mime)
        } else {
            // The generic pin in the accent colour, inline so no extra request is needed.
            let svg = PIN_SVG.replace("class=\"mark\"", "").replace("currentColor", &self.color);
            format!("<link rel=\"icon\" href=\"data:image/svg+xml,{}\">", url_encode(&svg))
        }
    }

    fn footer_html(&self) -> String {
        let mut s = String::from("<footer>");
        if !self.footer.is_empty() {
            s.push_str(&html_escape(&self.footer));
            s.push_str(" &middot; ");
        }
        s.push_str(&format!("Powered by <a href=\"{}\">traccar-geocoder</a></footer>", UPSTREAM_URL));
        s
    }
}

const PIN_SVG: &str = "<svg class=\"mark\" xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 24 24\" fill=\"none\" \
stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\" aria-hidden=\"true\">\
<path d=\"M12 22s7-6.1 7-12a7 7 0 1 0-14 0c0 5.9 7 12 7 12z\"/><circle cx=\"12\" cy=\"10\" r=\"2.5\"/></svg>";

/// Only plain colour syntax: hex, named colours, rgb()/hsl() and friends.
/// Keeps a stray `;` or `}` in the variable from reaching the stylesheet.
fn is_safe_color(c: &str) -> bool {
    c.len() <= 64
        && c.chars().all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '#' | '(' | ')' | ',' | '.' | '%' | ' ' | '-' | '/'))
}

fn mime_for(path: &str) -> &'static str {
    match path.rsplit('.').next().map(|e| e.to_ascii_lowercase()).as_deref() {
        Some("svg") => "image/svg+xml",
        Some("png") => "image/png",
        Some("jpg") | Some("jpeg") => "image/jpeg",
        Some("gif") => "image/gif",
        Some("webp") => "image/webp",
        Some("ico") => "image/x-icon",
        _ => "application/octet-stream",
    }
}

fn url_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' | b'/' | b':' | b'=' | b' ' => out.push(b as char),
            _ => out.push_str(&format!("%{:02X}", b)),
        }
    }
    out
}

// --- Asset routes ---

pub fn router<S: Clone + Send + Sync + 'static>() -> Router<S> {
    Router::new()
        .route("/brand/logo", get(|b: Extension<Arc<Branding>>| async move { serve(b.logo.as_ref()) }))
        .route("/brand/logo-dark", get(|b: Extension<Arc<Branding>>| async move { serve(b.logo_dark.as_ref()) }))
        .route("/brand/favicon", get(|b: Extension<Arc<Branding>>| async move { serve(b.favicon.as_ref()) }))
}

fn serve(asset: Option<&Asset>) -> Response {
    match asset {
        Some(a) => (
            [(CONTENT_TYPE, a.mime), (CACHE_CONTROL, "public, max-age=3600")],
            a.bytes.clone(),
        )
            .into_response(),
        None => StatusCode::NOT_FOUND.into_response(),
    }
}
