# Incremental updates

Keep the geocoding index fresh without re-downloading multi-GB PBF files.

The container can apply OSM replication diffs to the cached PBF using
`osmupdate`, rebuild the index into a staging directory, atomically swap it
into place, and restart the server. For a typical weekly cycle on a European
extract this turns a ~32 GB re-download into a ~50–200 MB diff.

## Modes

The container's entrypoint accepts an extra mode `update`, and the existing
`auto` mode learns a new env-var-driven loop:

| Mode     | Behaviour                                                        |
|----------|------------------------------------------------------------------|
| `build`  | Download PBFs (if missing) and build the index. Exits.           |
| `serve`  | Start the query server against an existing index. Foreground.    |
| `update` | Apply diffs to each PBF, rebuild index, atomic swap. Exits.      |
| `auto`   | Download + build + serve. With `UPDATE_INTERVAL` set, loops and  |
|          | refreshes the index on the configured cadence.                   |

`update` is intended as a one-shot. Run it on a host cron or systemd timer
against the same volume as your serve container; the swap is safe with a
running server (see below). For a single-container, no-external-scheduler
setup, use `auto` + `UPDATE_INTERVAL`.

## Environment variables

| Variable             | Default              | Meaning                                                                 |
|----------------------|----------------------|-------------------------------------------------------------------------|
| `PBF_URLS`           | (required)           | Space-separated URLs of PBF extracts to download                        |
| `UPDATE_INTERVAL`    | (unset)              | When set in `auto`, refresh cadence: `30d`, `7d`, `24h`, `60m`, `300s`  |
| `UPDATE_MAX_DIFF_AGE`| `7` (days)           | Passed to `osmupdate --max-merge`. If the PBF is older, osmupdate falls back to a fresh download |
| `STAGING_DIR`        | `$DATA_DIR/index.staging` | Where the new index is built before the atomic swap                |
| `STATE_DIR`          | `$DATA_DIR/state`    | Where per-PBF state files are written                                   |
| `FORCE_REDOWNLOAD`   | (unset)              | If set, re-download every PBF on the next `download_pbf` call           |
| `CHECK_PBF_FRESHNESS`| (unset)              | If set, `curl -z` compares server Last-Modified against local mtime     |
| `REPLICATION_BASE_URL_<basename>` | (unset) | Per-PBF replication URL override for PBFs missing the `osmosis_replication_base_url` header. Non-alphanumerics in the basename become underscores (e.g. `monaco-latest.osm.pbf` → `REPLICATION_BASE_URL_monaco_latest_osm_pbf`) |
| `ENABLE_SANITISE`    | (unset)              | If set, run `osmconvert --drop-broken-refs` on the merged PBF before rebuild. Off by default because it has been observed to strip every way/relation from a clean per-extract merge |

Previously, `download_pbf` would skip any PBF whose filename already existed
on disk, with no way to refresh it short of `rm`. That behaviour is preserved
by default (so existing operators see no change), but `FORCE_REDOWNLOAD=1` or
`CHECK_PBF_FRESHNESS=1` now provide explicit refresh paths.

## Sizing

Per-region rough numbers:

| Region  | Cached PBF | Index    | Steady-state | Peak during update |
|---------|------------|----------|--------------|--------------------|
| Monaco  | ~5 MB      | ~10 MB   | ~50 MB       | ~100 MB            |
| Europe  | ~32 GB     | ~8–10 GB | ~40 GB       | ~50 GB             |
| Planet  | ~86 GB     | ~18 GB   | ~110 GB      | ~140 GB            |

Provision **at least the "peak during update" row** of disk on the volume
backing `/data`. The old index dir is kept as `index.old` until the next
update cycle so any running server's mmaps stay valid; it is removed at the
start of the next cycle, not at the end of the current one.

Network during a typical weekly update is 50–500 MB depending on region,
versus a full re-download of the same PBF.

## Replication state file

One file per cached PBF in `$STATE_DIR`, written after each successful
update:

```
basename=europe-latest.osm.pbf
last_update_timestamp=2026-05-09T20:21:02Z
last_update_unix=1746823262
sequence_number=4567890
update_count=12
```

These are informational — `osmupdate` itself reads
`osmosis_replication_timestamp` from the PBF header.

## Examples

### Self-updating single container

```yaml
services:
  geocoder:
    image: traccar/traccar-geocoder
    environment:
      PBF_URLS: https://download.geofabrik.de/europe/monaco-latest.osm.pbf
      UPDATE_INTERVAL: 24h
    volumes:
      - geocoder-data:/data
    ports:
      - "3000:3000"
    restart: unless-stopped
```

### External cron, two containers sharing a volume

```yaml
services:
  geocoder:
    image: traccar/traccar-geocoder
    command: ["serve"]
    volumes: [geocoder-data:/data]
    ports: ["3000:3000"]
    restart: unless-stopped

  geocoder-updater:
    image: traccar/traccar-geocoder
    command: ["update"]
    volumes: [geocoder-data:/data]
    # Trigger from host cron with: docker compose run --rm geocoder-updater
    profiles: ["manual"]
```

After running `docker compose run --rm geocoder-updater`, restart the serve
container so it picks up the new index:

```sh
docker compose restart geocoder
```

(A future revision may add SIGHUP-driven graceful reload in the server itself
so the restart step disappears. For now, restart-on-update is the contract.)

## Caveats

- **PBFs without replication metadata** cannot be incrementally updated.
  `osmupdate` needs `osmosis_replication_timestamp` in the PBF header.
  Geofabrik extracts include it; some hand-rolled extracts do not. The
  update path logs a warning and skips those files.
- **Multi-PBF deployments** (`PBF_URLS` with several entries) update each
  PBF independently. There is no cross-PBF state.
- **Disk during update**: old index + staging index + PBFs all co-resident.
  See the sizing table.
- **osmupdate diff cache** lives in `$DATA_DIR/.osmupdate-tmp` so it survives
  container restarts and doesn't fill `/tmp`.
