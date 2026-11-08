#!/bin/sh
set -e

DATA_DIR="${DATA_DIR:-/data}"
STAGING_DIR="${STAGING_DIR:-$DATA_DIR/index.staging}"
STATE_DIR="${STATE_DIR:-$DATA_DIR/state}"
# Marker that says "a PBF changed but the index was not rebuilt yet". Set
# whenever a PBF is replaced on disk, cleared after a successful swap, so a
# failed or interrupted rebuild is retried on the next cycle/start even
# when osmupdate then reports "already up-to-date".
REBUILD_MARKER="$STATE_DIR/rebuild-pending"

SERVER_PID=""
SLEEP_PID=""

cleanup() {
    [ -n "$SLEEP_PID" ] && kill -TERM "$SLEEP_PID" 2>/dev/null || true
    if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill -TERM "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    # 143 = terminated by SIGTERM; a cron job running `update` must not
    # see success when it was interrupted mid-cycle.
    exit 143
}
trap cleanup TERM INT

mark_rebuild_pending() {
    mkdir -p "$STATE_DIR"
    : > "$REBUILD_MARKER"
}

download_pbf() {
    mkdir -p "$DATA_DIR/pbf"
    for url in $PBF_URLS; do
        filename=$(basename "$url")
        target="$DATA_DIR/pbf/$filename"
        part="$target.part"
        rm -f "$part"
        if [ -n "$FORCE_REDOWNLOAD" ] || [ ! -f "$target" ]; then
            echo "Downloading $url..."
            # Download to a temp name so a failed transfer never leaves a
            # truncated file under the real name (which the basename cache
            # would then treat as a good download forever).
            curl -fSL -o "$part" "$url"
            mv "$part" "$target"
            mark_rebuild_pending
        elif [ -n "$CHECK_PBF_FRESHNESS" ]; then
            if [ -f "$STATE_DIR/$filename.state.txt" ]; then
                # osmupdate has touched this file: its mtime no longer
                # tracks the server's Last-Modified, so a full re-download
                # would be triggered on every publish. Diffs keep it fresh.
                echo "Skipping freshness check for $filename (maintained by osmupdate)"
                continue
            fi
            echo "Checking freshness of $filename..."
            # -z compares local mtime against server Last-Modified; curl only
            # writes the output file when the server answers 200.
            curl -fSL -R -z "$target" -o "$part" "$url"
            if [ -f "$part" ]; then
                mv "$part" "$target"
                echo "Refreshed $filename"
                mark_rebuild_pending
            else
                echo "$filename is up to date"
            fi
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
    # shellcheck disable=SC2086
    build-index "$target_dir" $files $level_args || return 1
    if [ ! -f "$target_dir/geo_cells.bin" ]; then
        echo "Error: build-index finished but $target_dir/geo_cells.bin is missing" >&2
        return 1
    fi
}

# Build into $STAGING_DIR and swap it into $DATA_DIR/index. Every step is
# guarded explicitly because `set -e` is disabled while this runs inside
# an `if`/`||` context (POSIX errexit rules), which is exactly how the
# auto-mode loop calls it. Returns 2 on any failure, leaving the live
# index untouched.
rebuild_and_swap() {
    if ! build_index_into "$STAGING_DIR"; then
        echo "Index build failed; keeping the current index" >&2
        rm -rf "$STAGING_DIR"
        return 2
    fi

    # The server keeps its users/API keys in geocoder.json inside the
    # index directory it was started with. A freshly built staging dir
    # does not have it, so carry it over or every update logs everyone
    # out and invalidates every key.
    if [ -f "$DATA_DIR/index/geocoder.json" ]; then
        cp -p "$DATA_DIR/index/geocoder.json" "$STAGING_DIR/geocoder.json" || return 2
    fi

    # The previous index dir is kept as index.old so a running server
    # keeps its mmap'd inodes until it restarts. It is removed at the
    # start of the next swap, not at the end of this one.
    rm -rf "$DATA_DIR/index.old"
    if [ -d "$DATA_DIR/index" ]; then
        mv "$DATA_DIR/index" "$DATA_DIR/index.old" || return 2
    fi
    if ! mv "$STAGING_DIR" "$DATA_DIR/index"; then
        echo "Swap failed; rolling back to the previous index" >&2
        [ -d "$DATA_DIR/index.old" ] && mv "$DATA_DIR/index.old" "$DATA_DIR/index"
        return 2
    fi
    rm -f "$REBUILD_MARKER"
    return 0
}

# If a previous swap was interrupted between its two renames, the live
# index is gone while index.old (or a complete staging dir) still holds
# a full copy. Promote it instead of rebuilding from scratch.
recover_index() {
    [ -f "$DATA_DIR/index/geo_cells.bin" ] && return 0
    if [ -f "$DATA_DIR/index.old/geo_cells.bin" ]; then
        echo "No live index but index.old is complete; restoring it"
        rm -rf "$DATA_DIR/index"
        mv "$DATA_DIR/index.old" "$DATA_DIR/index"
    elif [ -f "$STAGING_DIR/geo_cells.bin" ]; then
        echo "No live index but a complete staging index exists; promoting it"
        rm -rf "$DATA_DIR/index"
        mv "$STAGING_DIR" "$DATA_DIR/index"
    fi
}

build_index() {
    recover_index
    if [ -f "$DATA_DIR/index/geo_cells.bin" ] && [ ! -f "$REBUILD_MARKER" ]; then
        echo "Index already exists, skipping build"
        return 0
    fi
    if [ -f "$REBUILD_MARKER" ]; then
        echo "PBF data changed since the index was built; rebuilding"
    fi
    rebuild_and_swap || return $?
    echo "Index built."
}

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

way_count() {
    osmium fileinfo -e "$1" 2>/dev/null | awk '/Number of ways:/ {print $4}'
}

# osmium-tool exposes PBF header options under the "header.option.*"
# namespace (not bare "header.*"), see `osmium fileinfo --help`. It
# prints an empty line when the option is absent.
header_option() {
    osmium fileinfo -g "header.option.$1" "$2" 2>/dev/null || echo ""
}

# Check that osmupdate-required header metadata is present in a PBF.
# Geofabrik extracts include it; some hand-extracted PBFs do not.
check_replication_header() {
    pbf="$1"
    ts=$(header_option osmosis_replication_timestamp "$pbf")
    if [ -z "$ts" ]; then
        echo "Warning: $pbf has no osmosis_replication_timestamp header; osmupdate cannot diff it." >&2
        return 1
    fi
    return 0
}

state_file_for() {
    printf '%s/%s.state.txt' "$STATE_DIR" "$(basename "$1")"
}

state_value() { # state_value <key> <state-file>
    [ -f "$2" ] || return 0
    awk -F= -v k="$1" '$1 == k {print substr($0, length(k) + 2); exit}' "$2"
}

# Resolve the replication source for a PBF, in priority order:
#   1. osmosis_replication_base_url header (Geofabrik ships it)
#   2. replication_base_url= from this PBF's state file (osmupdate's
#      output does not carry the header, so we remember it there)
#   3. REPLICATION_BASE_URL_<basename> env, non-alphanumerics mapped to
#      underscores, e.g. monaco-latest.osm.pbf ->
#      REPLICATION_BASE_URL_monaco_latest_osm_pbf
# Prints "<url> <source>" or nothing.
resolve_base_url() {
    pbf="$1"
    basename=$(basename "$pbf")
    url=$(header_option osmosis_replication_base_url "$pbf")
    if [ -n "$url" ]; then
        printf '%s header\n' "$url"
        return 0
    fi
    url=$(state_value replication_base_url "$(state_file_for "$pbf")")
    if [ -n "$url" ]; then
        printf '%s state-file\n' "$url"
        return 0
    fi
    var_name=$(printf 'REPLICATION_BASE_URL_%s' "$basename" | tr -c 'A-Za-z0-9_' '_')
    url=$(eval "printf %s \"\${$var_name:-}\"")
    if [ -n "$url" ]; then
        printf '%s env:%s\n' "$url" "$var_name"
        return 0
    fi
    return 1
}

# Fetch the current sequence number of a replication stream (informational
# only, recorded in the state file). Empty on any failure.
fetch_sequence_number() {
    curl -fsSL --max-time 20 "${1%/}/state.txt" 2>/dev/null \
        | awk -F= '/^sequenceNumber=/ {print $2}' | tr -d '\r'
}

write_state() { # write_state <pbf> <base_url> <sequence>
    pbf="$1"
    basename=$(basename "$pbf")
    sf=$(state_file_for "$pbf")
    mkdir -p "$STATE_DIR"
    ts=$(header_option osmosis_replication_timestamp "$pbf")
    unix_ts=""
    if [ -n "$ts" ]; then
        unix_ts=$(date -u -d "$ts" +%s 2>/dev/null || echo "")
    fi
    prev_count=$(state_value update_count "$sf" | tr -cd '0-9')
    count=$(( ${prev_count:-0} + 1 ))
    {
        echo "basename=$basename"
        echo "replication_base_url=$2"
        echo "last_update_timestamp=$ts"
        echo "last_update_unix=$unix_ts"
        echo "sequence_number=$3"
        echo "update_count=$count"
    } > "$sf.tmp"
    mv "$sf.tmp" "$sf"
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

        # Geofabrik extracts publish per-region replication streams
        # (already clipped to the extract's bbox). Without a base URL
        # osmupdate would fall back to planet replication and merge
        # worldwide changes into a regional file, so refuse instead.
        resolved=$(resolve_base_url "$pbf") || resolved=""
        if [ -z "$resolved" ]; then
            var_name=$(printf 'REPLICATION_BASE_URL_%s' "$basename" | tr -c 'A-Za-z0-9_' '_')
            echo "Warning: no replication URL known for $basename (no header, no state file," >&2
            echo "  no $var_name env). Skipping it; set the env var to update this PBF." >&2
            continue
        fi
        base_url=${resolved% *}
        echo "Replication source for $basename: $base_url (${resolved##* })"

        echo "Running osmupdate on $basename..."
        raw="$tmpdir/$basename"
        rm -f "$raw"

        # Per-stage object counts let us spot catastrophic data loss
        # (a wrong replication URL, a broken merge, etc.) before the
        # rebuilt index ships.
        log_counts "pre-update" "$pbf"
        pre_ways=$(way_count "$pbf")

        max_days_arg=""
        [ -n "$UPDATE_MAX_DIFF_AGE" ] && max_days_arg="--max-days=$UPDATE_MAX_DIFF_AGE"

        # Capture osmupdate's exit code explicitly: 0 = updated, 21 = no
        # new diffs available ("already up-to-date"), other = real error.
        # Use `|| rc=$?` rather than `set +e` / `set -e`, so we don't leak
        # the errexit state back to the caller on function return.
        rc=0
        # shellcheck disable=SC2086
        osmupdate \
            --base-url="$base_url" \
            --tempfiles="$tmpdir/osm" \
            $max_days_arg \
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
        post_ways=$(way_count "$raw")
        if [ "${pre_ways:-0}" -gt 0 ] && [ "${post_ways:-0}" -eq 0 ]; then
            rm -f "$raw"
            echo "Update of $basename produced a file with no ways (had $pre_ways); refusing to use it" >&2
            return 2
        fi

        # osmupdate's output keeps osmosis_replication_timestamp (which is
        # all osmupdate needs next time) but drops the base URL and the
        # sequence number. Those go into the state file instead of
        # re-encoding the whole PBF through `osmium cat`.
        seq=$(fetch_sequence_number "$base_url")

        mv "$raw" "$pbf"
        mark_rebuild_pending
        write_state "$pbf" "$base_url" "$seq"
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
    recover_index

    # `|| pbf_rc=$?` keeps errexit happy on non-zero return without us
    # having to toggle set +e / set -e. Use a distinct variable name so
    # we don't clobber any `rc` the caller is tracking (sh has no
    # function-local variables in POSIX, so plain `rc=` leaks).
    pbf_rc=0
    update_pbfs || pbf_rc=$?
    case $pbf_rc in
        0) echo "PBFs updated; rebuilding index" ;;
        1)
            if [ -f "$REBUILD_MARKER" ]; then
                echo "All PBFs current, but a previous rebuild did not complete; rebuilding"
            elif [ ! -f "$DATA_DIR/index/geo_cells.bin" ]; then
                echo "All PBFs current, but there is no index yet; building"
            else
                echo "All PBFs current; no rebuild needed"
                echo "=== Update cycle complete (no-op) ==="
                return 0
            fi
            ;;
        *) echo "Update aborted" >&2
           return "$pbf_rc" ;;
    esac

    rebuild_and_swap || { echo "Update aborted" >&2; return 2; }
    UPDATE_SWAPPED=1

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
# Prints nothing for anything else.
interval_to_seconds() {
    v="$1"
    case "$v" in
        *[!0-9smhd]*|"") return 0 ;;
    esac
    n=${v%[smhd]}
    case "$n" in
        ""|*[!0-9]*) return 0 ;;
    esac
    case "$v" in
        *s) echo "$n" ;;
        *m) echo $(( n * 60 )) ;;
        *h) echo $(( n * 3600 )) ;;
        *d) echo $(( n * 86400 )) ;;
        *) echo "$n" ;;
    esac
}

# Interruptible sleep: a background `sleep` plus `wait`, so the TERM/INT
# trap runs promptly instead of after the whole interval.
sleep_interruptible() {
    sleep "$1" &
    SLEEP_PID=$!
    wait "$SLEEP_PID" 2>/dev/null || true
    SLEEP_PID=""
}

# Run the server in the background, wait for UPDATE_INTERVAL while
# watching the server, then run an update cycle, restart the server
# against the new index when (and only when) the index actually changed,
# repeat. Used when auto mode is configured with UPDATE_INTERVAL.
serve_with_updates() {
    interval_sec=$(interval_to_seconds "$UPDATE_INTERVAL")
    if [ -z "$interval_sec" ] || [ "$interval_sec" -le 0 ]; then
        echo "Error: UPDATE_INTERVAL='$UPDATE_INTERVAL' is not a positive duration (use e.g. 7d, 24h, 30m, 300s)" >&2
        exit 2
    fi
    # Poll the server every 10 s (or every interval if that is shorter).
    poll_sec=10
    [ "$interval_sec" -lt "$poll_sec" ] && poll_sec=$interval_sec
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

        # Wait out the interval, but notice a dead server within
        # poll_sec rather than at the end of a multi-day sleep. A server
        # that dies takes the container down with its exit status, the
        # same as plain `serve` mode, so Docker's restart policy applies.
        elapsed=0
        while [ "$elapsed" -lt "$interval_sec" ]; do
            sleep_interruptible "$poll_sec"
            elapsed=$(( elapsed + poll_sec ))
            if ! kill -0 "$SERVER_PID" 2>/dev/null; then
                server_rc=0
                wait "$SERVER_PID" 2>/dev/null || server_rc=$?
                echo "Server exited unexpectedly (status $server_rc); stopping" >&2
                SERVER_PID=""
                exit "${server_rc:-1}"
            fi
        done

        # `if do_update; then ...` cleanly captures the return without
        # the `cmd || rc=$?` pattern leaking shell-global state. Note that
        # errexit is suspended inside do_update because of this; every
        # step in there is guarded explicitly.
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
