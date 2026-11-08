# Web UI and branding

The server ships a small web UI: a sign-in page and a dashboard for API keys,
users, a request console and server status. It needs no internet access
(the stylesheet is compiled into the binary) and follows the browser's light
or dark colour scheme.

Operators can put their own name, colours and logo on it. Everything is
plain configuration read once at startup; with nothing set the pages show
the neutral defaults ("Geocoder", a map-pin mark, a blue accent).

## Environment variables

| Variable | Meaning | Default |
|----------|---------|---------|
| `BRAND_NAME` | Product name in the page title and, when no logo is set, in the header. | `Geocoder` |
| `BRAND_COLOR` | Accent colour for buttons, links, focus rings and the header line. Any plain CSS colour (`#1a56db`, `rgb(26,86,219)`, `royalblue`). | `#4f6ee0` |
| `BRAND_LOGO` | Path to an image file (SVG, PNG, JPEG, WebP, GIF) shown in the header instead of the name. Served at `/brand/logo`. | (none) |
| `BRAND_LOGO_DARK` | Optional logo variant used when the browser prefers a dark colour scheme. Served at `/brand/logo-dark`. | (none) |
| `BRAND_FAVICON` | Path to the favicon (SVG, PNG or ICO). Served at `/brand/favicon`. | the logo, else the map pin |
| `BRAND_URL` | Where the header logo links to. | `/` |
| `BRAND_FOOTER` | Plain-text footer line, e.g. the operator's company name. A "Powered by traccar-geocoder" link always follows it. | (none) |

Paths are inside the container. Mount a directory with the assets and point
the variables at it:

```yaml
services:
  geocoder:
    image: traccar/traccar-geocoder
    volumes:
      - geocoder-data:/data
      - ./branding:/data/branding:ro
    environment:
      PBF_URLS: https://download.geofabrik.de/europe/monaco-latest.osm.pbf
      BRAND_NAME: Example Geocoder
      BRAND_COLOR: "#1a56db"
      BRAND_LOGO: /data/branding/logo.svg
      BRAND_LOGO_DARK: /data/branding/logo-dark.svg
      BRAND_FAVICON: /data/branding/favicon.svg
      BRAND_FOOTER: Example Ltd.
```

A missing or unreadable file is reported at startup and ignored; the page
falls back to the default for that item. `BRAND_COLOR` is restricted to
plain colour syntax so a stray `;` cannot leak into the stylesheet.

The files behind `BRAND_LOGO`, `BRAND_LOGO_DARK` and `BRAND_FAVICON` are
served to anyone who can reach the server, without a login, so only ever
point them at images meant to be public (never at `geocoder.json` or other
private files). They are sent with `X-Content-Type-Options: nosniff` and a
deny-all `Content-Security-Policy`, so an SVG with embedded script is shown
as an image but cannot run on the dashboard's origin.

A complete, real-world example lives in [`deploy/inteling/`](../deploy/inteling/).

## Logo tips

- The header is 30 px high; a wordmark of roughly 150×30 to 200×40 works
  best. The image is scaled to the header height and keeps its aspect ratio.
- With a logo set, the name is used only in the page title and as the image
  `alt` text. If the logo is a mark without text, put the product name in the
  SVG itself.
- SVG favicons are supported by all current browsers; ship a PNG or ICO if
  very old clients matter.
- The dark-scheme variant should sit on a dark background (`#1a1e28`); light
  text and desaturated accents work well.

## What the dashboard shows

- **API keys** of the signed-in user, with copy and delete buttons.
- **Try it**: a form that calls `/reverse` or `/snap` on this server with one
  of your keys and shows the JSON, the status code, the latency and a link to
  the spot on OpenStreetMap. Nothing is stored server-side.
- **Use it from Traccar**: `traccar.xml` entries and a `curl` command with
  this server's address and your first key filled in.
- **Usage**: requests per hour over the last 24 hours (all users), counted in
  memory since the server started. Admins also see today's count per user.
- **Server & data**: version, uptime, index size and build time, and, when
  the incremental-update workflow is in use, the OSM data timestamp and
  update count per extract (read from `STATE_DIR`, by default
  `/data/state`), plus the approximate time of the next scheduled update when
  `UPDATE_INTERVAL` is set.
- **Users** (admins): create and delete users, with per-second and per-day
  rate limits applied per user or per client IP.
- **Change password** for the signed-in user.

## `/health`

A liveness endpoint for monitoring. Without a login it returns only:

```bash
curl -s http://localhost:3000/health
# {"status":"ok","version":"0.1.0"}
```

The full picture (request counts, extract names, OSM timestamps, the time of
the next scheduled update) is returned when the request carries a valid
dashboard session cookie, or for everyone when the server is started with
`HEALTH_DETAILS=1`. Set that only where `/health` is not reachable from the
public internet, or when you are fine with that information being visible:

```bash
curl -s -b "session=..." http://localhost:3000/health
```

```json
{
  "status": "ok",
  "version": "0.1.0",
  "uptime_seconds": 86400,
  "requests_since_start": 12480,
  "requests_last_24h": [0, 0, 3, 12, 40, 55, 71, 90, 112, 95, 80, 66, 50, 41, 33, 28, 22, 18, 14, 9, 6, 4, 2, 1],
  "index": { "files": 14, "size_bytes": 10094236872, "built_unix": 1794532320 },
  "data": [
    { "basename": "europe-latest.osm.pbf", "osm_timestamp": "2026-11-06T00:00:00Z",
      "osm_unix": 1794528000, "update_count": 12, "sequence_number": "4567890" }
  ],
  "update_interval": "30d",
  "next_update_unix": 1797120000
}
```

`requests_last_24h` is oldest first; the last element is the current hour.
`data` is empty until the first incremental update has written a state file
(`STATE_DIR`, by default the `state` directory next to the index); the
directory is read on every request, so it appears without a restart.

## Security notes

- The session cookie is `HttpOnly; SameSite=Lax`, plus `Secure` when the
  server terminates TLS itself (`--domain`). `SameSite=Lax` keeps the cookie
  off cross-site form posts, so a hostile page cannot create users or keys
  with an admin's session. Behind a TLS-terminating reverse proxy the cookie
  is not marked `Secure`; keep the proxy-to-server hop on a private network.
- All state-changing actions (create/delete key, create/delete user, change
  password) are `POST` forms.
- Logins may not contain `:` or `/` and are at most 64 characters.
