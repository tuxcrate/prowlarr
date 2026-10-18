#!/bin/sh
set -eu

: "${1:?Expected application version is required}"
grep -Fx 'Branch=master' /opt/package_info
grep -Fx 'UpdateMethod=docker' /opt/package_info
test "$(id -u)" -ne 0
test ! -w /opt/prowlarr
test -w /config
test -s /opt/prowlarr/LICENSE
test -s /usr/share/doc/prowlarr/SOURCE
test ! -e /opt/prowlarr/Prowlarr.Update

scratch="$(mktemp -d)"
server_pid=
finish() {
    if [ -n "$server_pid" ]; then
        kill -TERM "$server_pid" 2>/dev/null || true
        wait "$server_pid" || true
    fi
    rm -rf "$scratch"
}
trap finish EXIT
trap 'exit 1' INT TERM

/opt/prowlarr/Prowlarr -nobrowser "-data=$scratch" > "$scratch/server.log" 2>&1 &
server_pid=$!
for attempt in $(seq 1 120); do
    if grep -q 'Now listening on:' "$scratch/server.log" \
        && wget -q -O "$scratch/ping.json" http://127.0.0.1:9696/ping; then
        installed_version="$(sed -n 's/.*Bootstrap: Starting Prowlarr .* - Version \([^ ]*\).*/\1/p' "$scratch/server.log")"
        test "$installed_version" = "$1"
        grep -Eq '"status"[[:space:]]*:[[:space:]]*"OK"' "$scratch/ping.json"
        test -s "$scratch/prowlarr.db"
        test -s "$scratch/config.xml"
        kill -TERM "$server_pid"
        wait "$server_pid"
        server_pid=
        exit 0
    fi
    if ! kill -0 "$server_pid" 2>/dev/null; then
        break
    fi
    sleep 1
done

cat "$scratch/server.log"
exit 1
