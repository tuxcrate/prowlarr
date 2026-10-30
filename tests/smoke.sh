#!/bin/sh
set -eu

: "${1:?Expected application version is required}"
grep -Ex 'Branch=(master|develop)' /opt/package_info
grep -Fx 'UpdateMethod=docker' /opt/package_info
test "$(id -u)" -ne 0
test ! -w /opt/prowlarr
test -w /config
test -s /opt/prowlarr/LICENSE
test -s /usr/share/doc/prowlarr/SOURCE
test ! -e /opt/prowlarr/Prowlarr.Update

scratch="$(mktemp -d)"
server_pid=
phase='starting Prowlarr'
finish() {
    status=$?
    if [ -n "$server_pid" ]; then
        kill -TERM "$server_pid" 2>/dev/null || true
        wait "$server_pid" || true
    fi
    if [ "$status" -ne 0 ]; then
        printf 'Prowlarr smoke test failed while %s (exit status %s).\n' "$phase" "$status" >&2
        ls -la "$scratch" >&2 || true
        if [ -f "$scratch/server.log" ]; then
            cat "$scratch/server.log" >&2 || true
        fi
        if [ -f "$scratch/ping.json" ]; then
            cat "$scratch/ping.json" >&2 || true
        fi
    fi
    rm -rf "$scratch"
    exit "$status"
}
trap finish EXIT
trap 'exit 1' INT TERM

printf '<Config><BindAddress>127.0.0.1</BindAddress><Port>0</Port></Config>\n' > "$scratch/config.xml"
/opt/prowlarr/Prowlarr -nobrowser "-data=$scratch" > "$scratch/server.log" 2>&1 &
server_pid=$!
phase='waiting for Prowlarr to respond OK to /ping and create nonempty prowlarr.db and config.xml'
attempt=0
while :; do
    if ! kill -0 "$server_pid" 2>/dev/null; then
        echo 'Prowlarr exited before becoming ready.' >&2
        exit 1
    fi
    port="$(sed -n 's/.*Now listening on: http:\/\/127\.0\.0\.1:\([0-9][0-9]*\).*/\1/p' "$scratch/server.log")"
    if [ -n "$port" ] \
        && wget -T 2 -q -O "$scratch/ping.json" "http://127.0.0.1:$port/ping" \
        && grep -Eq '"status"[[:space:]]*:[[:space:]]*"OK"' "$scratch/ping.json" \
        && test -s "$scratch/prowlarr.db" \
        && test -s "$scratch/config.xml"; then
        break
    fi
    if [ "$attempt" -ge 120 ]; then
        echo 'Timed out waiting for Prowlarr readiness.' >&2
        exit 1
    fi
    attempt=$((attempt + 1))
    sleep 1
done

phase='checking the installed version'
installed_version="$(sed -n 's/.*Bootstrap: Starting Prowlarr .* - Version \([^ ]*\).*/\1/p' "$scratch/server.log")"
test "$installed_version" = "$1"
phase='stopping Prowlarr'
kill -TERM "$server_pid"
if wait "$server_pid"; then
    server_pid=
else
    status=$?
    server_pid=
    printf 'Prowlarr shutdown returned exit status %s.\n' "$status" >&2
    exit "$status"
fi
