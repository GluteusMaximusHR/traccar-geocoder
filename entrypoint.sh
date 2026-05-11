#!/bin/sh
set -e

DATA_DIR="${DATA_DIR:-/data}"
STAGING_DIR="${STAGING_DIR:-$DATA_DIR/index.staging}"
STATE_DIR="${STATE_DIR:-$DATA_DIR/state}"
UPDATE_MAX_DIFF_AGE="${UPDATE_MAX_DIFF_AGE:-7}"

SERVER_PID=""
SLEEP_PID=""

cleanup() {
    [ -n "$SLEEP_PID" ] && kill -TERM "$SLEEP_PID" 2>/dev/null || true
    if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill -TERM "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    exit 0
}
trap cleanup TERM INT

download_pbf() {
    mkdir -p "$DATA_DIR/pbf"
    for url in $PBF_URLS; do
        filename=$(basename "$url")
        target="$DATA_DIR/pbf/$filename"
        if [ -n "$FORCE_REDOWNLOAD" ] || [ ! -f "$target" ]; then
            echo "Downloading $url..."
            curl -fSL -o "$target" "$url"
        elif [ -n "$CHECK_PBF_FRESHNESS" ]; then
            echo "Checking freshness of $filename..."
            # -z compares local mtime against server Last-Modified; only downloads if newer
            curl -fSL -R -z "$target" -o "$target" "$url"
        else
            echo "Already downloaded: $filename (set FORCE_REDOWNLOAD=1 or CHECK_PBF_FRESHNESS=1 to refresh)"
        fi
    done
}

list_pbfs() {
    for f in "$DATA_DIR"/pbf/*.osm.pbf; do
        [ -f "$f" ] && printf '%s ' "$f"
    done
}

build_index_into() {
    target_dir="$1"
    files=$(list_pbfs)
    if [ -z "$files" ]; then
        echo "Error: no PBF files found in $DATA_DIR/pbf/" >&2
        return 1
    fi
    rm -rf "$target_dir"
    mkdir -p "$target_dir"
    level_args=""
    [ -n "$STREET_LEVEL" ] && level_args="$level_args --street-level $STREET_LEVEL"
    [ -n "$ADMIN_LEVEL" ] && level_args="$level_args --admin-level $ADMIN_LEVEL"
    echo "Building index into $target_dir..."
    build-index "$target_dir" $files $level_args
}

build_index() {
    if [ -f "$DATA_DIR/index/geo_cells.bin" ]; then
        echo "Index already exists, skipping build"
        return 0
    fi
    build_index_into "$DATA_DIR/index"
    echo "Index built."
}

# Check that osmupdate-required header metadata is present in a PBF.
# Geofabrik extracts include it; some hand-extracted PBFs do not.
# Single-line summary of node/way/relation counts for a PBF, prefixed
# with a stage label. Lets the operator see at a glance where data
# loss happened during an update.
log_counts() {
    label="$1"
    file="$2"
    [ -f "$file" ] || return 0
    counts=$(osmium fileinfo -e "$file" 2>/dev/null \
        | awk '/Number of (nodes|ways|relations):/ {gsub(":",""); printf "%s=%s ", $3, $4}')
    echo "  [$label] $(basename "$file"): ${counts:-(unknown)}"
}

check_replication_header() {
    pbf="$1"
    # osmium-tool exposes PBF header options under the "header.option.*"
    # namespace (not bare "header.*"), see `osmium fileinfo --help`.
    ts=$(osmium fileinfo -g header.option.osmosis_replication_timestamp "$pbf" 2>/dev/null || true)
    if [ -z "$ts" ] || [ "$ts" = "(none)" ]; then
        echo "Warning: $pbf has no osmosis_replication_timestamp header; osmupdate cannot diff it." >&2
        return 1
    fi
    return 0
}

write_state() {
    pbf="$1"
    basename=$(basename "$pbf")
    sf="$STATE_DIR/$basename.state.txt"
    mkdir -p "$STATE_DIR"
    ts=$(osmium fileinfo -g header.option.osmosis_replication_timestamp "$pbf" 2>/dev/null || echo "")
    seq=$(osmium fileinfo -g header.option.osmosis_replication_sequence_number "$pbf" 2>/dev/null || echo "")
    unix_ts=""
    if [ -n "$ts" ] && [ "$ts" != "(none)" ]; then
        unix_ts=$(date -u -d "$ts" +%s 2>/dev/null || echo "")
    fi
    prev_count=0
    if [ -f "$sf" ]; then
        prev_count=$(awk -F= '/^update_count=/{print $2}' "$sf")
        prev_count=${prev_count:-0}
    fi
    count=$((prev_count + 1))
    {
        echo "basename=$basename"
        echo "last_update_timestamp=$ts"
        echo "last_update_unix=$unix_ts"
        echo "sequence_number=$seq"
        echo "update_count=$count"
    } > "$sf"
}

# Apply OSM replication diffs to each cached PBF in place.
# Returns 0 if at least one PBF was updated, 1 if all are already current,
# 2 on hard failure (caller decides whether to abort).
update_pbfs() {
    any_updated=0
    # Separate dir for in-flight output. osmupdate picks the output format
    # from the file extension, so the temp file must keep `.osm.pbf` — and
    # it must live outside $DATA_DIR/pbf/ so a stale temp doesn't get
    # picked up by the *.osm.pbf glob in list_pbfs / build_index_into.
    tmpdir="$DATA_DIR/.osmupdate-tmp"
    mkdir -p "$tmpdir"

    for pbf in "$DATA_DIR"/pbf/*.osm.pbf; do
        [ -f "$pbf" ] || continue
        basename=$(basename "$pbf")
        if ! check_replication_header "$pbf"; then
            echo "Skipping $basename (no replication metadata)"
            continue
        fi

        # Read the replication source from the PBF header. Geofabrik
        # extracts publish per-region replication streams (already clipped
        # to the extract's bbox); without --base-url=, osmupdate falls
        # back to planet replication and merges worldwide changes into a
        # regional file. After drop-broken-refs that destroys the data.
        header_base_url=$(osmium fileinfo -g header.option.osmosis_replication_base_url "$pbf" 2>/dev/null || echo "")
        base_url=""
        base_url_source=""
        if [ -n "$header_base_url" ] && [ "$header_base_url" != "(none)" ]; then
            base_url="$header_base_url"
            base_url_source="header"
        else
            # Operator escape hatch for hand-rolled PBFs that lack the
            # replication header: REPLICATION_BASE_URL_<basename> with
            # non-alphanumerics mapped to underscores. Example:
            # monaco-latest.osm.pbf -> REPLICATION_BASE_URL_monaco_latest_osm_pbf
            var_name=$(printf 'REPLICATION_BASE_URL_%s' "$basename" | tr -c 'A-Za-z0-9_' '_')
            override=$(eval "printf %s \"\${$var_name:-}\"")
            if [ -n "$override" ]; then
                base_url="$override"
                base_url_source="env $var_name"
            fi
        fi

        base_url_arg=""
        if [ -n "$base_url" ]; then
            echo "Replication source for $basename: $base_url ($base_url_source)"
            base_url_arg="--base-url=$base_url"
        else
            echo "Warning: $basename has no osmosis_replication_base_url header and no" >&2
            echo "  REPLICATION_BASE_URL_<basename> override; osmupdate will use planet." >&2
            echo "  For a regional extract this is almost certainly wrong." >&2
        fi

        echo "Running osmupdate on $basename..."
        raw="$tmpdir/raw-$basename"
        new="$tmpdir/$basename"
        rm -f "$raw" "$new"

        # Per-stage object counts let us spot catastrophic data loss
        # (a missing replication URL, a bad sanitisation step, etc.)
        # before the rebuilt index ships.
        log_counts "pre-update" "$pbf"

        # Capture osmupdate's exit code explicitly: 0 = updated, 21 = no
        # new diffs available ("already up-to-date"), other = real error.
        # Use `|| rc=$?` rather than `set +e` / `set -e`, so we don't leak
        # the errexit state back to the caller on function return.
        rc=0
        # shellcheck disable=SC2086
        osmupdate \
            --max-merge="$UPDATE_MAX_DIFF_AGE" \
            --tempfiles="$tmpdir/osm" \
            $base_url_arg \
            "$pbf" "$raw" || rc=$?

        case $rc in
            0)  ;; # fall through and process $raw
            21)
                echo "$basename already current"
                rm -f "$raw"
                continue
                ;;
            *)
                rm -f "$raw"
                echo "osmupdate failed for $basename (exit $rc)" >&2
                return 2
                ;;
        esac

        if [ ! -f "$raw" ]; then
            # osmupdate reported success but produced no file; treat as no-op
            echo "$basename already current"
            continue
        fi

        log_counts "post-osmupdate" "$raw"

        # Snapshot the updated replication metadata from osmupdate's
        # output before passing it through osmium cat (which writes a
        # fresh header).
        new_ts=$(osmium fileinfo -g header.option.osmosis_replication_timestamp "$raw" 2>/dev/null || echo "")
        new_seq=$(osmium fileinfo -g header.option.osmosis_replication_sequence_number "$raw" 2>/dev/null || echo "")

        # Pass the merged file through osmium cat to preserve the
        # replication URL header for the next update cycle.
        # Geofabrik's per-extract replication streams are referentially
        # complete within the extract's bbox, so we do NOT run
        # osmconvert --drop-broken-refs here — earlier experiments
        # showed it dropped every way and relation even on a clean
        # 7-day merge, likely because the merged file's structure
        # confuses osmconvert's two-pass ref check.
        # If a deployment hits "location for one or more nodes not
        # found" during the rebuild, set ENABLE_SANITISE=1 to re-enable
        # the osmconvert pass.
        hdr_args=""
        if [ -n "$base_url" ] && [ "$base_url" != "(none)" ]; then
            hdr_args="$hdr_args --output-header=osmosis_replication_base_url=$base_url"
        fi
        if [ -n "$new_ts" ] && [ "$new_ts" != "(none)" ]; then
            hdr_args="$hdr_args --output-header=osmosis_replication_timestamp=$new_ts"
        fi
        if [ -n "$new_seq" ] && [ "$new_seq" != "(none)" ]; then
            hdr_args="$hdr_args --output-header=osmosis_replication_sequence_number=$new_seq"
        fi

        input_for_cat="$raw"
        if [ -n "$ENABLE_SANITISE" ]; then
            sanitized="$tmpdir/sanitized-$basename"
            rm -f "$sanitized"
            echo "Sanitising $basename (drop broken refs)..."
            hash_mem="${OSMCONVERT_HASH_MEMORY:-2000}"
            if ! osmconvert "$raw" --drop-broken-refs --hash-memory="$hash_mem" "-o=$sanitized"; then
                rc=$?
                rm -f "$raw" "$sanitized"
                echo "osmconvert failed for $basename (exit $rc)" >&2
                return 2
            fi
            log_counts "post-osmconvert" "$sanitized"
            input_for_cat="$sanitized"
        fi

        # shellcheck disable=SC2086
        if ! osmium cat "$input_for_cat" -o "$new" --overwrite $hdr_args; then
            rc=$?
            rm -f "$raw" "$new"
            [ -n "$sanitized" ] && rm -f "$sanitized"
            echo "osmium cat failed for $basename (exit $rc)" >&2
            return 2
        fi
        rm -f "$raw"
        [ -n "$sanitized" ] && rm -f "$sanitized"

        log_counts "post-osmium-cat" "$new"

        mv "$new" "$pbf"
        any_updated=1
        echo "Updated $basename"
    done
    [ "$any_updated" -eq 1 ] && return 0 || return 1
}

do_update() {
    # Set to 1 by the body when the index dir is atomically swapped, so
    # callers (notably serve_with_updates) can tell a real update apart
    # from a no-op without overloading the return code.
    UPDATE_SWAPPED=0
    echo "=== Update cycle starting at $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
    if [ -z "$(list_pbfs)" ]; then
        echo "No PBF files in $DATA_DIR/pbf/; running initial download"
        download_pbf
    fi

    # `|| pbf_rc=$?` keeps errexit happy on non-zero return without us
    # having to toggle set +e / set -e. Use a distinct variable name so
    # we don't clobber any `rc` the caller is tracking (sh has no
    # function-local variables in POSIX, so plain `rc=` leaks).
    pbf_rc=0
    update_pbfs || pbf_rc=$?
    case $pbf_rc in
        0) echo "PBFs updated; rebuilding index" ;;
        1) echo "All PBFs current; no rebuild needed"
           echo "=== Update cycle complete (no-op) ==="
           return 0 ;;
        *) echo "Update aborted" >&2
           return $pbf_rc ;;
    esac

    build_index_into "$STAGING_DIR"

    # Atomic swap. The previous index dir is kept as index.old so any
    # running server keeps mmap'd inodes valid until it restarts. Cleanup
    # happens on the next update cycle.
    if [ -d "$DATA_DIR/index.old" ]; then
        rm -rf "$DATA_DIR/index.old"
    fi
    if [ -d "$DATA_DIR/index" ]; then
        mv "$DATA_DIR/index" "$DATA_DIR/index.old"
    fi
    mv "$STAGING_DIR" "$DATA_DIR/index"
    UPDATE_SWAPPED=1

    # Persist replication state only after a successful swap, so a build
    # crash mid-cycle doesn't leave behind a state file claiming success.
    for pbf in "$DATA_DIR"/pbf/*.osm.pbf; do
        [ -f "$pbf" ] && write_state "$pbf"
    done

    echo "=== Update cycle complete at $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
}

build_server_args() {
    args="$DATA_DIR/index"
    if [ -n "$DOMAIN" ]; then
        args="$args --domain $DOMAIN"
        [ -n "$CACHE_DIR" ] && args="$args --cache $CACHE_DIR"
    else
        args="$args ${BIND_ADDR:-0.0.0.0:3000}"
    fi
    [ -n "$STREET_LEVEL" ] && args="$args --street-level $STREET_LEVEL"
    [ -n "$ADMIN_LEVEL" ] && args="$args --admin-level $ADMIN_LEVEL"
    [ -n "$SEARCH_DISTANCE" ] && args="$args --search-distance $SEARCH_DISTANCE"
    printf '%s' "$args"
}

serve() {
    args=$(build_server_args)
    echo "Starting server..."
    # shellcheck disable=SC2086
    exec query-server $args
}

# Convert "30d", "12h", "45m", "60s", or a bare integer (seconds) to seconds.
interval_to_seconds() {
    v="$1"
    case "$v" in
        *s) echo "${v%s}" ;;
        *m) echo $(( ${v%m} * 60 )) ;;
        *h) echo $(( ${v%h} * 3600 )) ;;
        *d) echo $(( ${v%d} * 86400 )) ;;
        *) echo "$v" ;;
    esac
}

# Run the server in the background, sleep for UPDATE_INTERVAL, then run an
# update cycle, restart the server against the new index when (and only
# when) the index actually changed, repeat. Used when auto mode is
# configured with UPDATE_INTERVAL.
serve_with_updates() {
    interval_sec=$(interval_to_seconds "$UPDATE_INTERVAL")
    args=$(build_server_args)
    while true; do
        # Launch the server only if it isn't already running. After a
        # successful update we kill the server and clear SERVER_PID; on
        # a no-op or failed update we leave it running and skip this
        # block. Without this guard, `continue` paths would race a fresh
        # server against a still-alive one on port 3000 (AddrInUse).
        if [ -z "$SERVER_PID" ] || ! kill -0 "$SERVER_PID" 2>/dev/null; then
            echo "Launching server (background) for ${UPDATE_INTERVAL} cycle..."
            # shellcheck disable=SC2086
            query-server $args &
            SERVER_PID=$!
            echo "Server PID: $SERVER_PID"
        fi

        # Sleep in a way that traps can interrupt us promptly.
        sleep "$interval_sec" &
        SLEEP_PID=$!
        wait "$SLEEP_PID" 2>/dev/null || true
        SLEEP_PID=""

        if ! kill -0 "$SERVER_PID" 2>/dev/null; then
            echo "Server exited unexpectedly; will relaunch on next iteration"
            SERVER_PID=""
            continue
        fi

        # `if do_update; then ...` cleanly captures the return without
        # the `cmd || rc=$?` pattern leaking shell-global state.
        update_rc=0
        if do_update; then
            update_rc=0
        else
            update_rc=$?
        fi

        if [ "$update_rc" -ne 0 ]; then
            echo "Update failed; server continues running on the existing index"
            continue
        fi
        if [ "${UPDATE_SWAPPED:-0}" -ne 1 ]; then
            # No-op cycle — nothing changed, server stays as it is
            continue
        fi

        echo "Restarting server against new index"
        kill -TERM "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
        SERVER_PID=""
        # Top of the loop will relaunch since SERVER_PID is now empty.
    done
}

case "${1:-auto}" in
    build)
        download_pbf
        build_index
        ;;
    serve)
        serve
        ;;
    update)
        do_update
        ;;
    auto)
        download_pbf
        build_index
        if [ -n "$UPDATE_INTERVAL" ]; then
            serve_with_updates
        else
            serve
        fi
        ;;
    *)
        exec "$@"
        ;;
esac
