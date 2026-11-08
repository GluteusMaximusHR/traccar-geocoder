#!/bin/bash
# Regression tests for entrypoint.sh's update workflow.
#
# Runs the real entrypoint under /bin/sh with stubbed build-index,
# query-server, osmupdate, osmium and curl, so it needs no Docker, no
# network and no OSM data. "PBF" files are small key=value text files the
# osmium stub knows how to read. Run from anywhere:
#
#   bash tests/test-entrypoint.sh
#
# Exit status is non-zero if any check fails.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ENTRYPOINT="$HERE/../entrypoint.sh"
WORK=$(mktemp -d)
STUBS="$WORK/stubs"
mkdir -p "$STUBS"
trap 'rm -rf "$WORK"' EXIT

FAILS=0
CHECKS=0
check() { # check <description> <command...>
    local desc="$1"; shift
    CHECKS=$((CHECKS + 1))
    if "$@"; then
        echo "  ok   $desc"
    else
        echo "  FAIL $desc"
        FAILS=$((FAILS + 1))
    fi
}
grep_log() { grep -q -- "$1" "$LOG"; }
not_grep_log() { ! grep -q -- "$1" "$LOG"; }
not() { ! "$@"; }
file_is() { [ "$(cat "$1" 2>/dev/null)" = "$2" ]; }
stub_called_with() { grep -q -- "$1" "$STUB_LOG"; }

# ---------------------------------------------------------------- stubs
cat > "$STUBS/build-index" <<'EOF'
#!/bin/sh
echo "build-index $*" >> "$STUB_LOG"
[ "${STUB_BUILD_FAIL:-0}" = "1" ] && { echo "stub build failure" >&2; exit 1; }
out="$1"; shift
mkdir -p "$out"
files="geo_cells admin_cells strings"
[ "${STUB_BUILD_NO_PLACE:-0}" = "1" ] || files="$files place_cells"
for f in $files; do
    echo "built-from: $* at $(date +%s%N)" > "$out/$f.bin"
done
[ "${STUB_BUILD_EMPTY:-0}" = "1" ] && : > "$out/geo_cells.bin"
exit 0
EOF
cat > "$STUBS/mv" <<'EOF'
#!/bin/sh
case "$*" in
    *geocoder.json*) [ "${STUB_MV_DB_FAIL:-0}" = "1" ] && exit 1 ;;
esac
exec /bin/mv "$@"
EOF
cat > "$STUBS/cp" <<'EOF'
#!/bin/sh
case "$*" in
    *geocoder.json*) [ "${STUB_CP_DB_FAIL:-0}" = "1" ] && exit 1 ;;
esac
exec /bin/cp "$@"
EOF
cat > "$STUBS/df" <<'EOF'
#!/bin/sh
# STUB_DF_AVAIL=<bytes> fakes the free space the entrypoint sees.
if [ -n "${STUB_DF_AVAIL:-}" ]; then printf 'Avail\n%s\n' "$STUB_DF_AVAIL"; exit 0; fi
exec /bin/df "$@"
EOF
cat > "$STUBS/query-server" <<'EOF'
#!/bin/sh
echo "query-server pid=$$ $*" >> "$STUB_LOG"
if [ "${STUB_SERVER_DIE:-0}" = "1" ]; then sleep 1; exit 3; fi
exec sleep 600
EOF
cat > "$STUBS/osmupdate" <<'EOF'
#!/bin/sh
echo "osmupdate $*" >> "$STUB_LOG"
in=""; out=""
for a in "$@"; do
    case "$a" in --*) ;; *) if [ -z "$in" ]; then in="$a"; else out="$a"; fi ;; esac
done
rc="${STUB_OSMUPDATE_RC:-21}"
if [ "$rc" = "0" ]; then
    # Mimic osmconvert's output: timestamp kept, base_url and seq dropped.
    pre_ways=$(awk -F= '$1=="ways"{print $2}' "$in")
    post_ways="${STUB_POST_WAYS:-$((pre_ways + 1))}"
    grep -v -E '^(base_url|seq|ways|timestamp)=' "$in" > "$out"
    echo "timestamp=2026-11-07T21:21:36Z" >> "$out"
    echo "ways=$post_ways" >> "$out"
fi
exit "$rc"
EOF
cat > "$STUBS/osmium" <<'EOF'
#!/bin/sh
# supports: osmium fileinfo -g header.option.<opt> <file>
#           osmium fileinfo -e <file>
[ "$1" = "fileinfo" ] || { echo "stub osmium: unsupported $*" >&2; exit 1; }
case "$2" in
    -g)
        key=${3#header.option.}
        case "$key" in
            osmosis_replication_timestamp) k=timestamp ;;
            osmosis_replication_base_url) k=base_url ;;
            osmosis_replication_sequence_number) k=seq ;;
            *) k="$key" ;;
        esac
        awk -F= -v k="$k" '$1==k {print $2}' "$4"
        echo
        ;;
    -e)
        for k in nodes ways relations; do
            v=$(awk -F= -v k="$k" '$1==k {print $2}' "$3")
            label=$(echo "$k" | sed 's/^./\U&/')
            printf '  Number of %s: %s\n' "$k" "${v:-0}"
        done
        ;;
esac
EOF
cat > "$STUBS/curl" <<'EOF'
#!/bin/sh
echo "curl $*" >> "$STUB_LOG"
out=""; url=""; ifnewer=0
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift ;;
        -z) ifnewer=1; shift ;;
        --max-time) shift ;;
        -*) ;;
        *) url="$1" ;;
    esac
    shift
done
case "$url" in
    */state.txt) echo "sequenceNumber=4961"; exit 0 ;;
esac
if [ "$ifnewer" = 1 ] && [ "${STUB_CURL_200:-0}" != "1" ]; then
    exit 0   # 304: curl writes nothing
fi
[ "${STUB_CURL_FAIL:-0}" = "1" ] && { echo "stub curl failure" >&2; exit 22; }
printf 'timestamp=2026-11-01T21:21:36Z\nbase_url=https://example.test/updates\nseq=4955\nnodes=100\nways=10\nrelations=1\n' > "$out"
EOF
chmod +x "$STUBS"/*
export PATH="$STUBS:$PATH"

# -------------------------------------------------------------- helpers
DB='{"users":{"admin":{}}}'
legacy_db() { mv "$DATA/geocoder.json" "$DATA/index/geocoder.json"; }
old_format() { rm "$DATA/index/place_cells.bin"; }
new_data() { # fresh DATA_DIR with one PBF and (optionally) an index + geocoder.json
    DATA="$WORK/data-$RANDOM$RANDOM"
    rm -rf "$DATA"; mkdir -p "$DATA/pbf"
    printf 'timestamp=2026-11-01T21:21:36Z\nbase_url=https://example.test/updates\nseq=4955\nnodes=100\nways=10\nrelations=1\n' > "$DATA/pbf/x.osm.pbf"
    if [ "${1:-with-index}" = "with-index" ]; then
        mkdir -p "$DATA/index"
        echo "old-index" > "$DATA/index/geo_cells.bin"
        echo "old-index" > "$DATA/index/place_cells.bin"
        echo "$DB" > "$DATA/geocoder.json"
    fi
    export DATA_DIR="$DATA"
    export STUB_LOG="$DATA/stub.log"; : > "$STUB_LOG"
    LOG="$DATA/run.log"
}
run_ep() { # run_ep <mode> [VAR=value ...] -> RC
    local mode="$1"; shift
    env "$@" sh "$ENTRYPOINT" "$mode" > "$LOG" 2>&1
    RC=$?
}
pbf_ways() { awk -F= '$1=="ways"{print $2}' "$DATA/pbf/x.osm.pbf"; }
state() { awk -F= -v k="$1" '$1==k{print substr($0, length(k)+2)}' "$DATA/state/x.osm.pbf.state.txt" 2>/dev/null; }

# ---------------------------------------------------------------- cases
echo "# 1. update: osmupdate reports up-to-date -> no-op"
new_data; run_ep update
check "exit 0" [ "$RC" = 0 ]
check "logs no-op" grep_log "complete (no-op)"
check "index untouched" file_is "$DATA/index/geo_cells.bin" "old-index"
check "no rebuild marker" [ ! -f "$DATA/state/rebuild-pending" ]
check "no index.old" [ ! -d "$DATA/index.old" ]
check "no --max-merge passed" not stub_called_with "--max-merge"
check "no --max-days passed by default" not stub_called_with "--max-days"
check "base url from header" grep_log "https://example.test/updates (header)"

echo "# 2. update: diffs applied -> rebuild, swap, state, geocoder.json kept"
new_data; run_ep update STUB_OSMUPDATE_RC=0
check "exit 0" [ "$RC" = 0 ]
check "pbf replaced (ways 10 -> 11)" [ "$(pbf_ways)" = 11 ]
check "index rebuilt" not file_is "$DATA/index/geo_cells.bin" "old-index"
check "old index kept as index.old" file_is "$DATA/index.old/geo_cells.bin" "old-index"
check "geocoder.json untouched by the swap" file_is "$DATA/geocoder.json" "$DB"
check "no geocoder.json in the new index" [ ! -f "$DATA/index/geocoder.json" ]
check "state: base url remembered" [ "$(state replication_base_url)" = "https://example.test/updates" ]
check "state: sequence from state.txt" [ "$(state sequence_number)" = 4961 ]
check "state: timestamp" [ "$(state last_update_timestamp)" = "2026-11-07T21:21:36Z" ]
check "state: update_count=1" [ "$(state update_count)" = 1 ]
check "rebuild marker cleared" [ ! -f "$DATA/state/rebuild-pending" ]
check "no raw temp left" [ -z "$(ls -A "$DATA/.osmupdate-tmp")" ]
check "staging dir gone" [ ! -d "$DATA/index.staging" ]
run_ep update   # second cycle: header lost base url -> must come from state file
check "2nd cycle exit 0" [ "$RC" = 0 ]
check "2nd cycle uses state-file base url" grep_log "https://example.test/updates (state-file)"
check "2nd cycle is a no-op" grep_log "complete (no-op)"
check "update_count still 1" [ "$(state update_count)" = 1 ]

echo "# 3. update: build fails after PBF was replaced -> live index kept, retried next cycle"
new_data; run_ep update STUB_OSMUPDATE_RC=0 STUB_BUILD_FAIL=1
check "exit 2" [ "$RC" = 2 ]
check "live index untouched" file_is "$DATA/index/geo_cells.bin" "old-index"
check "geocoder.json untouched" file_is "$DATA/geocoder.json" "$DB"
check "no index.old created" [ ! -d "$DATA/index.old" ]
check "staging removed" [ ! -d "$DATA/index.staging" ]
check "pbf is ahead (ways=11)" [ "$(pbf_ways)" = 11 ]
check "rebuild marker set" [ -f "$DATA/state/rebuild-pending" ]
run_ep update   # osmupdate now says up-to-date, but the marker forces a rebuild
check "retry exit 0" [ "$RC" = 0 ]
check "retry logs reason" grep_log "previous rebuild did not complete"
check "retry rebuilt index" not file_is "$DATA/index/geo_cells.bin" "old-index"
check "retry cleared marker" [ ! -f "$DATA/state/rebuild-pending" ]

echo "# 4. update: osmupdate hard failure -> abort, nothing changed"
new_data; run_ep update STUB_OSMUPDATE_RC=1
check "exit 2" [ "$RC" = 2 ]
check "logs failure" grep_log "osmupdate failed for x.osm.pbf (exit 1)"
check "pbf unchanged" [ "$(pbf_ways)" = 10 ]
check "index unchanged" file_is "$DATA/index/geo_cells.bin" "old-index"
check "no marker" [ ! -f "$DATA/state/rebuild-pending" ]

echo "# 5. update: merged file lost all ways -> refused"
new_data; run_ep update STUB_OSMUPDATE_RC=0 STUB_POST_WAYS=0
check "exit 2" [ "$RC" = 2 ]
check "logs refusal" grep_log "no ways (had 10); refusing"
check "pbf unchanged" [ "$(pbf_ways)" = 10 ]
check "index unchanged" file_is "$DATA/index/geo_cells.bin" "old-index"

echo "# 6. update: replication metadata handling"
new_data; sed -i '/^timestamp=/d' "$DATA/pbf/x.osm.pbf"; run_ep update STUB_OSMUPDATE_RC=0
check "no timestamp -> skipped, exit 0" [ "$RC" = 0 ]
check "no timestamp -> warning" grep_log "no osmosis_replication_timestamp"
check "no timestamp -> osmupdate not called" not stub_called_with osmupdate
new_data; sed -i '/^base_url=/d' "$DATA/pbf/x.osm.pbf"; run_ep update STUB_OSMUPDATE_RC=0
check "no base url anywhere -> skipped, exit 0" [ "$RC" = 0 ]
check "no base url -> names the env var" grep_log "REPLICATION_BASE_URL_x_osm_pbf"
check "no base url -> osmupdate not called (no planet fallback)" not stub_called_with osmupdate
run_ep update STUB_OSMUPDATE_RC=0 REPLICATION_BASE_URL_x_osm_pbf=https://override.test/u
check "env override -> exit 0" [ "$RC" = 0 ]
check "env override -> passed to osmupdate" stub_called_with "--base-url=https://override.test/u"
check "env override -> logged as source" grep_log "(env:REPLICATION_BASE_URL_x_osm_pbf)"
check "env override -> stored in state" [ "$(state replication_base_url)" = "https://override.test/u" ]

echo "# 7. update: PBFs present but no index yet -> builds it"
new_data without-index; run_ep update
check "exit 0" [ "$RC" = 0 ]
check "logs reason" grep_log "no index yet"
check "index built" [ -f "$DATA/index/geo_cells.bin" ]

echo "# 8. update: UPDATE_MAX_DIFF_AGE maps to --max-days"
new_data; run_ep update UPDATE_MAX_DIFF_AGE=30
check "--max-days=30 passed" stub_called_with "--max-days=30"
check "--max-merge not passed" not stub_called_with "--max-merge"

echo "# 9. build: download via .part, marker, skip on second run, freshness check"
new_data without-index; rm -f "$DATA/pbf/x.osm.pbf"
run_ep build PBF_URLS=https://example.test/x.osm.pbf
check "exit 0" [ "$RC" = 0 ]
check "downloaded to .part first" stub_called_with "-o $DATA/pbf/x.osm.pbf.part"
check "pbf in place, no .part left" [ -f "$DATA/pbf/x.osm.pbf" ] && [ ! -f "$DATA/pbf/x.osm.pbf.part" ]
check "index built" [ -f "$DATA/index/geo_cells.bin" ]
check "marker cleared" [ ! -f "$DATA/state/rebuild-pending" ]
run_ep build PBF_URLS=https://example.test/x.osm.pbf
check "second build skips" grep_log "Index already exists"
run_ep build PBF_URLS=https://example.test/x.osm.pbf CHECK_PBF_FRESHNESS=1
check "freshness 304 -> up to date, no rebuild" grep_log "is up to date" && grep_log "Index already exists"
run_ep build PBF_URLS=https://example.test/x.osm.pbf CHECK_PBF_FRESHNESS=1 STUB_CURL_200=1
check "freshness 200 -> refreshed and rebuilt" grep_log "Refreshed x.osm.pbf" && grep_log "Building index into"
run_ep update STUB_OSMUPDATE_RC=0
run_ep build PBF_URLS=https://example.test/x.osm.pbf CHECK_PBF_FRESHNESS=1 STUB_CURL_200=1
check "freshness skipped once osmupdate owns the file" grep_log "maintained by osmupdate"
new_data without-index; rm -f "$DATA/pbf/x.osm.pbf"
run_ep build PBF_URLS=https://example.test/x.osm.pbf STUB_CURL_FAIL=1
check "failed download -> non-zero exit" [ "$RC" != 0 ]
check "failed download -> no pbf under the real name" [ ! -f "$DATA/pbf/x.osm.pbf" ]

echo "# 10. recovery: interrupted swap (index missing, index.old complete)"
new_data; mv "$DATA/index" "$DATA/index.old"; run_ep update
check "exit 0" [ "$RC" = 0 ]
check "index.old restored" file_is "$DATA/index/geo_cells.bin" "old-index"
check "logged" grep_log "restoring it"

echo "# 11. auto loop: no-op cycles keep the server, TERM exits 143"
new_data
env UPDATE_INTERVAL=1 sh "$ENTRYPOINT" auto > "$LOG" 2>&1 &
EP=$!
sleep 4
check "entrypoint still running" kill -0 "$EP"
SPID=$(awk '/^query-server pid=/ {sub("pid=","",$2); print $2; exit}' "$STUB_LOG")
check "server launched once" [ "$(grep -c '^query-server pid=' "$STUB_LOG")" = 1 ]
check "server stub alive" kill -0 "$SPID"
check "at least two update cycles ran" [ "$(grep -c 'Update cycle starting' "$LOG")" -ge 2 ]
check "never restarted" not_grep_log "Restarting server"
kill -TERM "$EP"; wait "$EP"; RC=$?
check "TERM -> exit 143" [ "$RC" = 143 ]
sleep 0.5
check "server stub stopped" not kill -0 "$SPID"

echo "# 12. auto loop: a real update restarts the server exactly once"
new_data
env UPDATE_INTERVAL=1 STUB_OSMUPDATE_RC=0 sh "$ENTRYPOINT" auto > "$LOG" 2>&1 &
EP=$!
sleep 3
kill -TERM "$EP"; wait "$EP" 2>/dev/null
check "restart logged" grep_log "Restarting server against new index"
check "server launched twice" [ "$(grep -c '^query-server pid=' "$STUB_LOG")" -ge 2 ]
check "geocoder.json survived the swap" file_is "$DATA/geocoder.json" "$DB"

echo "# 13. auto loop: server death ends the container with the server's status"
new_data
env UPDATE_INTERVAL=30 STUB_SERVER_DIE=1 sh "$ENTRYPOINT" auto > "$LOG" 2>&1 &
EP=$!
for i in $(seq 1 30); do kill -0 "$EP" 2>/dev/null || break; sleep 0.5; done
wait "$EP"; RC=$?
check "exited within 15s" [ "$i" -lt 30 ]
check "exit status 3 (server's)" [ "$RC" = 3 ]
check "logged" grep_log "Server exited unexpectedly (status 3)"
check "auto loop passes DATA_DIR to the server" stub_called_with "^query-server pid=[0-9]* $DATA 0.0.0.0:3000"

echo "# 14. auto loop: invalid UPDATE_INTERVAL is rejected"
for bad in 1w abc 0 7D 3h0; do
    new_data; run_ep auto UPDATE_INTERVAL="$bad"
    check "UPDATE_INTERVAL='$bad' -> exit 2" [ "$RC" = 2 ]
done
check "rejection message" grep_log "not a positive duration"

echo "# 15. interval_to_seconds"
sed -n '/^interval_to_seconds()/,/^}/p' "$ENTRYPOINT" > "$WORK/f.sh"
its() { sh -c ". '$WORK/f.sh'; interval_to_seconds \"\$1\"" _ "$1"; }
check "30d" [ "$(its 30d)" = 2592000 ]
check "24h" [ "$(its 24h)" = 86400 ]
check "60m" [ "$(its 60m)" = 3600 ]
check "300s" [ "$(its 300s)" = 300 ]
check "bare 42" [ "$(its 42)" = 42 ]
check "1w -> empty" [ -z "$(its 1w)" ]
check "abc -> empty" [ -z "$(its abc)" ]
check "m -> empty" [ -z "$(its m)" ]

echo "# 16. serve: the server gets DATA_DIR and appends /index itself"
new_data; run_ep serve STUB_SERVER_DIE=1
check "serve passes DATA_DIR" stub_called_with "^query-server pid=[0-9]* $DATA 0.0.0.0:3000"

echo "# 17. geocoder.json leaves the index dir at swap time (copy) or when this image serves (move)"
new_data; legacy_db; run_ep update STUB_OSMUPDATE_RC=0
check "update+swap: exit 0" [ "$RC" = 0 ]
check "update+swap: copied to DATA_DIR" file_is "$DATA/geocoder.json" "$DB"
check "update+swap: not in the new index" [ ! -f "$DATA/index/geocoder.json" ]
check "update+swap: original went to index.old (for rollback)" file_is "$DATA/index.old/geocoder.json" "$DB"
check "update+swap: logged" grep_log "Migrating geocoder.json"
new_data; legacy_db; run_ep update
check "no-op update: exit 0" [ "$RC" = 0 ]
check "no-op update leaves the db where the old server reads it" file_is "$DATA/index/geocoder.json" "$DB"
check "no-op update: nothing copied yet" [ ! -f "$DATA/geocoder.json" ]
new_data; legacy_db; run_ep build
check "build with a current index does not touch the db" file_is "$DATA/index/geocoder.json" "$DB"
new_data; legacy_db; run_ep serve STUB_SERVER_DIE=1
check "serve moves it" file_is "$DATA/geocoder.json" "$DB"
check "serve: gone from index" [ ! -f "$DATA/index/geocoder.json" ]
new_data; legacy_db; run_ep auto STUB_SERVER_DIE=1 UPDATE_INTERVAL=30
check "auto with interval moves it before launching the server" file_is "$DATA/geocoder.json" "$DB"
new_data; legacy_db; echo newer > "$DATA/geocoder.json"; run_ep serve STUB_SERVER_DIE=1
check "existing DATA_DIR db is not overwritten" file_is "$DATA/geocoder.json" newer
check "differing copies are reported" grep_log "differ; the server uses"
new_data; legacy_db; mv "$DATA/index" "$DATA/index.old"; run_ep update
check "interrupted swap: restored with its db" file_is "$DATA/index/geocoder.json" "$DB"
new_data; legacy_db; run_ep update STUB_OSMUPDATE_RC=0 STUB_CP_DB_FAIL=1
check "failed copy: exit 2" [ "$RC" = 2 ]
check "failed copy: db still in place" file_is "$DATA/index/geocoder.json" "$DB"
check "failed copy: no swap" [ ! -d "$DATA/index.old" ]
check "failed copy: live index untouched" file_is "$DATA/index/geo_cells.bin" "old-index"
check "failed copy: finished build kept" [ -f "$DATA/index.staging/.complete" ]
check "failed copy: marker set" [ -f "$DATA/state/rebuild-pending" ]
run_ep update
check "failed copy: next cycle completes" [ "$RC" = 0 ]
check "failed copy: next cycle swapped" not file_is "$DATA/index/geo_cells.bin" "old-index"
new_data; legacy_db; run_ep serve STUB_SERVER_DIE=1 STUB_MV_DB_FAIL=1
check "failed move at serve: exit 2" [ "$RC" = 2 ]
check "failed move at serve: db still in place" file_is "$DATA/index/geocoder.json" "$DB"
check "failed move at serve: server not started" not stub_called_with query-server

echo "# 18. INDEX_ALL_ROADS reaches every build path"
new_data; run_ep update STUB_OSMUPDATE_RC=0 INDEX_ALL_ROADS=true
check "update passes --all-roads" stub_called_with "^build-index .*--all-roads"
new_data without-index; run_ep build INDEX_ALL_ROADS=true
check "build passes --all-roads" stub_called_with "^build-index .*--all-roads"
new_data; run_ep update STUB_OSMUPDATE_RC=0
check "unset -> no --all-roads" not stub_called_with "--all-roads"

echo "# 19. an index in the old format is rebuilt once"
new_data; old_format; legacy_db; run_ep build
check "build: exit 0" [ "$RC" = 0 ]
check "build: logs reason" grep_log "built by an older version"
check "build: new format in place" [ -f "$DATA/index/place_cells.bin" ]
check "build: old index kept as index.old" file_is "$DATA/index.old/geo_cells.bin" "old-index"
check "build: db migrated" file_is "$DATA/geocoder.json" "$DB"
run_ep build
check "second build skips" grep_log "Index already exists"
new_data; old_format; run_ep update
check "no-op update: exit 0" [ "$RC" = 0 ]
check "no-op update: logs reason" grep_log "built by an older version"
check "no-op update: new format in place" [ -f "$DATA/index/place_cells.bin" ]
new_data; old_format; legacy_db; run_ep auto STUB_SERVER_DIE=1
check "auto: rebuilt before the server starts" [ "$(head -1 "$STUB_LOG" | cut -d' ' -f1)" = build-index ]
new_data; old_format; legacy_db; run_ep build STUB_BUILD_FAIL=1
check "failed rebuild: exit 2" [ "$RC" = 2 ]
check "failed rebuild: old index kept live" file_is "$DATA/index/geo_cells.bin" "old-index"
check "failed rebuild: db stays with the old index" file_is "$DATA/index/geocoder.json" "$DB"
new_data; run_ep update STUB_OSMUPDATE_RC=0 STUB_BUILD_NO_PLACE=1
check "incomplete build: exit 2" [ "$RC" = 2 ]
check "incomplete build: not swapped" file_is "$DATA/index/geo_cells.bin" "old-index"

echo "# 20. recovery: only a finished staging build is promoted"
new_data without-index; mkdir "$DATA/index.staging"; echo partial > "$DATA/index.staging/geo_cells.bin"
run_ep build
check "partial staging: exit 0" [ "$RC" = 0 ]
check "partial staging: not promoted" not_grep_log "promoting it"
check "partial staging: rebuilt" not file_is "$DATA/index/geo_cells.bin" partial
new_data without-index; mkdir "$DATA/index.staging"
echo finished > "$DATA/index.staging/geo_cells.bin"; echo finished > "$DATA/index.staging/place_cells.bin"
: > "$DATA/index.staging/.complete"
run_ep build
check "finished staging: promoted" grep_log "promoting it"
check "finished staging: live" file_is "$DATA/index/geo_cells.bin" finished
new_data without-index; mkdir "$DATA/index.old" "$DATA/index.staging"
echo "old-index" > "$DATA/index.old/geo_cells.bin"; echo "old-index" > "$DATA/index.old/place_cells.bin"
echo finished > "$DATA/index.staging/geo_cells.bin"; echo finished > "$DATA/index.staging/place_cells.bin"
: > "$DATA/index.staging/.complete"
run_ep build
check "staging beats index.old: promoted" grep_log "promoting it"
check "staging beats index.old: newest index live" file_is "$DATA/index/geo_cells.bin" finished
check "staging beats index.old: not rebuilt" not stub_called_with build-index

echo "# 21. only one build at a time per staging dir"
if command -v flock >/dev/null 2>&1; then
    new_data without-index
    # The holder must be a single process (exec, no child), so killing it
    # really releases the lock.
    ( exec 8>"$DATA/index.staging.lock"; flock 8; exec sleep 20 ) &
    HOLDER=$!
    sleep 0.3
    run_ep build
    check "lock held: exit 2" [ "$RC" = 2 ]
    check "lock held: refused" grep_log "another build is already running"
    check "lock held: build-index not called" not stub_called_with build-index
    kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
    run_ep build
    check "lock released: builds" [ "$RC" = 0 ]
    check "lock released: index in place" [ -f "$DATA/index/geo_cells.bin" ]
    run_ep update STUB_OSMUPDATE_RC=0
    check "lock released after a swap: next update works" [ "$RC" = 0 ]
else
    echo "  skip flock not installed"
fi

echo "# 22. disk-space preflight and truncated output"
new_data; run_ep update STUB_OSMUPDATE_RC=0 STUB_DF_AVAIL=1
check "no space: exit 2" [ "$RC" = 2 ]
check "no space: explained" grep_log "Free disk space or set SKIP_DISK_CHECK=1"
check "no space: build-index not called" not stub_called_with build-index
check "no space: live index untouched" file_is "$DATA/index/geo_cells.bin" "old-index"
check "no space: marker set for retry" [ -f "$DATA/state/rebuild-pending" ]
run_ep update STUB_DF_AVAIL=1 SKIP_DISK_CHECK=1
check "SKIP_DISK_CHECK=1: exit 0" [ "$RC" = 0 ]
check "SKIP_DISK_CHECK=1: rebuilt" not file_is "$DATA/index/geo_cells.bin" "old-index"
new_data; run_ep update STUB_OSMUPDATE_RC=0 STUB_BUILD_EMPTY=1
check "empty geo_cells.bin: exit 2" [ "$RC" = 2 ]
check "empty geo_cells.bin: explained" grep_log "is empty; build-index probably ran out of disk space"
check "empty geo_cells.bin: not swapped" file_is "$DATA/index/geo_cells.bin" "old-index"
check "empty geo_cells.bin: staging removed" [ ! -d "$DATA/index.staging" ]

echo
echo "$CHECKS checks, $FAILS failed"
[ "$FAILS" -eq 0 ]
