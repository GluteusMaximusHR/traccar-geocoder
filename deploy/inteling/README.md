# Inteling branding

Deployment-specific assets for the Inteling instance of traccar-geocoder.
Nothing in this directory is used by the image itself; the files are mounted
into the container and referenced through the `BRAND_*` environment
variables described in [docs/branding.md](../../docs/branding.md).

| File | Used as |
|------|---------|
| `logo.svg` | `BRAND_LOGO` — header logo on light backgrounds |
| `logo-dark.svg` | `BRAND_LOGO_DARK` — header logo when the browser prefers a dark colour scheme |
| `favicon.svg` | `BRAND_FAVICON` — the dots mark alone |
| `docker-compose.yml` | Example compose file wiring everything together |
