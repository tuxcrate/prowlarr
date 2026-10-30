#!/usr/bin/env bash
set -euo pipefail

image=${1:?A locally loaded image is required}
version=${2:?The expected application version is required}
platform=${3:?The image platform is required}
container=
phase='starting the container with its default entrypoint and user'
cleanup() {
    status=$?
    if [[ -n $container ]]; then
        if ((status != 0)); then
            printf 'Prowlarr smoke test failed while %s (exit status %s).\n' "$phase" "$status" >&2
            docker inspect --format '{{json .State}}' "$container" >&2 || true
            docker logs "$container" >&2 || true
            docker exec "$container" ls -la /config >&2 || true
        fi
        docker rm --force --volumes "$container" > /dev/null || true
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

container=$(docker create --pull=never --platform "$platform" --network none \
    --label "io.tuxcrate.smoke-test=${TUXCRATE_TEST_ID:-manual-prowlarr-$$}" "$image")
docker start "$container" > /dev/null
phase='checking runtime prerequisites as the configured user'
docker exec "$container" sh -eu -c '
    grep -Ex "Branch=(master|develop)" /opt/package_info
    grep -Fx "UpdateMethod=docker" /opt/package_info
    test "$(id -u)" -ne 0
    test ! -w /opt/prowlarr
    test -w /config
    test -s /opt/prowlarr/LICENSE
    test -s /usr/share/doc/prowlarr/SOURCE
    test ! -e /opt/prowlarr/Prowlarr.Update
    test ! -e /usr/local/bin/prowlarr-smoke-test
'

phase='waiting for nonempty prowlarr.db and config.xml and an OK /ping response'
attempt=0
while :; do
    if [[ $(docker inspect --format '{{.State.Running}}' "$container") != true ]]; then
        echo 'Prowlarr exited before becoming ready.' >&2
        exit 1
    fi
    if response=$(docker exec "$container" sh -eu -c '
        test -s /config/prowlarr.db
        test -s /config/config.xml
        wget -T 2 -q -O - http://127.0.0.1:9696/ping
    ' 2>/dev/null) && grep -Eq '"status"[[:space:]]*:[[:space:]]*"OK"' <<< "$response"; then
        break
    fi
    if ((attempt >= 120)); then
        printf 'Timed out waiting for Prowlarr readiness. Last ping response: %s\n' "${response:-[empty]}" >&2
        exit 1
    fi
    attempt=$((attempt + 1))
    sleep 1
done

phase='checking the installed version'
installed_version=$(docker logs "$container" 2>&1 | sed -n 's/.*Bootstrap: Starting Prowlarr .* - Version \([^ ]*\).*/\1/p')
if [[ $installed_version != "$version" ]]; then
    printf 'Expected Prowlarr %s, got %s.\n' "$version" "$installed_version" >&2
    exit 1
fi
phase='checking graceful shutdown'
docker stop --time 30 "$container" > /dev/null
exit_code=$(docker wait "$container")
if [[ $exit_code != 0 ]]; then
    printf 'Prowlarr shutdown returned exit status %s.\n' "$exit_code" >&2
    exit 1
fi
