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

Exit codes of `update`: `0` success or nothing to do, `2` the cycle was
aborted and the live index was left untouched, `143` interrupted by SIGTERM.

## Environment variables

| Variable             | Default              | Meaning                                                                 |
|----------------------|----------------------|-------------------------------------------------------------------------|
| `PBF_URLS`           | (required)           | Space-separated URLs of PBF extracts to download                        |
| `UPDATE_INTERVAL`    | (unset)              | When set in `auto`, refresh cadence: `30d`, `7d`, `24h`, `60m`, `300s`. Anything else aborts at start-up |
| `UPDATE_MAX_DIFF_AGE`| (unset = osmupdate's 250) | Passed to `osmupdate --max-days`: the widest range of daily diffs it will assemble in one run. There is **no** automatic fall-back to a full download; a PBF older than the replication server keeps diffs for (Geofabrik: ~100 days) has to be re-fetched with `FORCE_REDOWNLOAD=1` |
| `STAGING_DIR`        | `$DATA_DIR/index.staging` | Where the new index is built before the atomic swap. Keep it on the same filesystem as `$DATA_DIR/index` so the swap is a rename |
| `STATE_DIR`          | `$DATA_DIR/state`    | Where per-PBF state files and the `rebuild-pending` marker are written |
| `FORCE_REDOWNLOAD`   | (unset)              | If set, re-download every PBF on the next `download_pbf` call           |
| `CHECK_PBF_FRESHNESS`| (unset)              | If set, `curl -z` compares server Last-Modified against local mtime. Skipped for PBFs that osmupdate already maintains (they have a state file) |
| `REPLICATION_BASE_URL_<basename>` | (unset) | Replication URL for a PBF whose header lacks `osmosis_replication_base_url` and that has no state file yet. Non-alphanumerics in the basename become underscores (e.g. `monaco-latest.osm.pbf` → `REPLICATION_BASE_URL_monaco_latest_osm_pbf`) |

Previously, `download_pbf` would skip any PBF whose filename already existed
on disk, with no way to refresh it short of `rm`. That behaviour is preserved
by default (so existing operators see no change), but `FORCE_REDOWNLOAD=1` or
`CHECK_PBF_FRESHNESS=1` now provide explicit refresh paths. Downloads go to a
`.part` file first, so a failed transfer never leaves a truncated PBF under
the real name.

## What an update cycle does

1. For each `/data/pbf/*.osm.pbf`:
   - Skip it (with a warning) if the header has no
     `osmosis_replication_timestamp`; osmupdate needs it.
   - Resolve the replication stream: header `osmosis_replication_base_url`,
     else `replication_base_url=` from the PBF's state file, else the
     `REPLICATION_BASE_URL_<basename>` env. If none is known the PBF is
     skipped: osmupdate would otherwise fall back to planet replication and
     merge worldwide changes into a regional extract.
   - Run `osmupdate <pbf> <tmp>` with that `--base-url`. Exit 21 means
     "already up-to-date"; anything else non-zero aborts the cycle.
   - Log node/way/relation counts before and after, and refuse the result
     if a file that had ways now has none.
   - Replace the PBF, set the `rebuild-pending` marker, write the state file.
2. If any PBF changed, or the marker is set from an earlier failed rebuild,
   or there is no index yet, or the index is in an older format: build into
   `$STAGING_DIR`, then
   `mv index index.old && mv index.staging index`. If the second rename
   fails, the first is rolled back. The marker is cleared only after a
   successful swap, so a build that dies (OOM, `docker stop`, disk full)
   is retried on the next cycle even though osmupdate then reports nothing
   new.
3. In `auto` mode, restart the server only if the swap happened.

A PBF that an update has touched no longer carries the base URL in its
header (osmupdate's output keeps only the timestamp); the state file holds
it from then on. Keep `$STATE_DIR` on the same volume as the PBFs.

## Sizing

Per-region rough numbers:

| Region  | Cached PBF | Index    | Steady-state | Peak during update |
|---------|------------|----------|--------------|--------------------|
| Monaco  | ~1 MB      | ~0.2 MB  | ~2 MB        | ~4 MB              |
| Europe  | ~32 GB     | ~8–10 GB | ~40 GB       | ~85 GB             |
| Planet  | ~86 GB     | ~21 GB   | ~110 GB      | ~220 GB            |

During an update the old PBF and osmupdate's merged output coexist (2× PBF),
plus the old index and the staging index (2× index), plus the downloaded
diffs. Provision **at least the "peak during update" row** of disk on the
volume backing `/data`. The old index dir is kept as `index.old` until the
next swap so any running server's mmaps stay valid; it is removed at the
start of the next rebuild, not at the end of the current one.

Network during a typical weekly update is 50–500 MB depending on region,
versus a full re-download of the same PBF. osmupdate deletes its downloaded
diffs after a successful merge; `$DATA_DIR/.osmupdate-tmp` only holds
in-flight files.

## Replication state file

One file per cached PBF in `$STATE_DIR`, written after each applied update:

```
basename=europe-latest.osm.pbf
replication_base_url=https://download.geofabrik.de/europe-updates
last_update_timestamp=2026-05-09T20:21:02Z
last_update_unix=1746823262
sequence_number=4567890
update_count=12
```

`replication_base_url` is read back on later cycles (see above); the rest is
informational. `sequence_number` is the stream's `state.txt` value at the time
of the update and is empty if that fetch failed. `osmupdate` itself only needs
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
    init: true
    restart: unless-stopped
```

`init: true` gives osmupdate's helper processes (wget, gzip) a proper reaper.
If the server process dies, the container exits with its status so
`restart: unless-stopped` brings it back; the loop does not try to relaunch
it internally.

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
    profiles: ["manual"]
```

From host cron, run the update and restart the serve container in one go so
it picks up the new index before the next cycle deletes `index.old`:

```sh
docker compose run --rm geocoder-updater && docker compose restart geocoder
```

Restarting is safe at any time: the server is stateless apart from
`$DATA_DIR/geocoder.json` (users and API keys), which lives outside the index
directory and is not touched by the swap.

(A future revision may add SIGHUP-driven graceful reload in the server itself
so the restart step disappears. For now, restart-on-update is the contract.)

## Upgrading from an older image

The index format changed: `place_cells.bin` was added and node counts widened
to 16 bits. The new server cannot load an index built by an older builder, so
`build`, `auto` and `update` detect a missing `place_cells.bin` and rebuild
once. `geocoder.json` moves from `index/` to `$DATA_DIR` at the same time.

**In `auto` mode the server is down during that first rebuild** (hours for
Europe), because it cannot serve the old index in the meantime. To keep the
outage to a restart, build first with a one-off container while the old one
keeps serving, and switch immediately afterwards:

```sh
docker run --rm -v geocoder-data:/data -e PBF_URLS="$PBF_URLS" <new-image> build
docker stop geocoder && docker rm geocoder   # then start the new image
```

Until the switch, do not change users or API keys, and do not let the old
container restart: it can no longer find its `geocoder.json` or read the new
index.

Rolling back to the old image needs both the old index and the database back
in their old places:

```sh
mv /data/index /data/index.new && mv /data/index.old /data/index
mv /data/geocoder.json /data/index/geocoder.json
```

Only a missing `place_cells.bin` is detected. An index built by an upstream
image from between May and October 2026 has that file but the old node
counts; force its rebuild with `touch /data/state/rebuild-pending`.

## Caveats

- **PBFs without replication metadata** cannot be incrementally updated by
  this image. It requires `osmosis_replication_timestamp` in the PBF header
  (Geofabrik extracts include it; some hand-rolled extracts do not) and skips
  such files with a warning.
- **Multi-PBF deployments** (`PBF_URLS` with several entries) update each
  PBF independently. There is no cross-PBF state. If one PBF fails, the
  cycle aborts; PBFs already replaced are picked up by the next rebuild via
  the `rebuild-pending` marker.
- **Disk during update**: old PBF + merged PBF + old index + staging index
  all co-resident. See the sizing table.
- **No graceful shutdown in the server**: the restart after a swap closes
  in-flight requests. Expect tens of milliseconds of connection errors.
- **`docker stop` during a long rebuild**: the TERM trap only runs once the
  foreground `build-index` finishes, so Docker's default 10 s grace period
  will SIGKILL the container mid-build. Nothing is lost (the staging dir is
  rebuilt next time), but set `stop_grace_period` generously if you want
  the build to complete.
