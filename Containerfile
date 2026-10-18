ARG BASE_IMAGE
FROM --platform=$BUILDPLATFORM ${BASE_IMAGE} AS release

SHELL ["/bin/ash", "-o", "pipefail", "-c"]

ARG APP_VERSION

RUN set -eux; \
    : "${APP_VERSION:?APP_VERSION must be set}"; \
    apk add --no-cache ca-certificates curl jq; \
    curl --fail-with-body --location --retry 3 --retry-all-errors --retry-max-time 180 \
        --connect-timeout 15 --max-time 60 \
        "https://api.github.com/repos/Prowlarr/Prowlarr/releases/tags/v${APP_VERSION}" \
        --output /tmp/release.json \
        || { cat /tmp/release.json >&2; exit 1; }; \
    jq -e --arg tag "v${APP_VERSION}" \
        '.tag_name == $tag and .draft == false and (.prerelease | type == "boolean")' /tmp/release.json; \
    jq -r 'if .prerelease then "develop" else "master" end' /tmp/release.json > /tmp/branch

FROM release AS download

ARG APP_VERSION
ARG TARGETARCH

RUN set -eux; \
    case "$TARGETARCH" in \
        amd64) asset_arch=x64 ;; \
        arm64) asset_arch=arm64 ;; \
        *) echo "Unsupported architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    branch="$(cat /tmp/branch)"; \
    jq -ce --arg name "Prowlarr.${branch}.${APP_VERSION}.linux-musl-core-${asset_arch}.tar.gz" \
        '[.assets[] | select(.name == $name)] \
        | if length == 1 then .[0] else error("expected one matching Prowlarr channel asset") end' \
        /tmp/release.json > /tmp/asset.json; \
    checksum="$(jq -er '.digest | select(test("^sha256:[0-9a-f]{64}$"))' /tmp/asset.json)"; \
    download_url="$(jq -er '.browser_download_url' /tmp/asset.json)"; \
    curl --fail --location --retry 3 --proto '=https' --proto-redir '=https' \
        "$download_url" --output /tmp/prowlarr.tar.gz; \
    printf '%s  /tmp/prowlarr.tar.gz\n' "${checksum#sha256:}" | sha256sum -c -; \
    mkdir /prowlarr /notices; \
    tar -xzf /tmp/prowlarr.tar.gz --directory /prowlarr --strip-components=1; \
    test -s /prowlarr/LICENSE; \
    printf 'Prowlarr is distributed under GPL-3.0. See /opt/prowlarr/LICENSE.\nUpstream release: https://github.com/Prowlarr/Prowlarr/releases/tag/v%s\nCorresponding source: https://github.com/Prowlarr/Prowlarr/tree/v%s\nSource archive: https://github.com/Prowlarr/Prowlarr/archive/refs/tags/v%s.tar.gz\n' \
        "$APP_VERSION" "$APP_VERSION" "$APP_VERSION" > /notices/SOURCE; \
    rm -rf /prowlarr/Prowlarr.Update; \
    printf 'UpdateMethod=docker\nBranch=%s\nPackageAuthor=[Tuxcrate](https://tuxcrate.com)\n' "$branch" > /package_info

FROM ${BASE_IMAGE}

SHELL ["/bin/ash", "-o", "pipefail", "-c"]

ARG APP_VERSION

ENV HOME=/config \
    XDG_CONFIG_HOME=/config/xdg \
    COMPlus_EnableDiagnostics=0

RUN set -eux; \
    apk upgrade --no-cache; \
    apk add --no-cache ca-certificates icu-data-full icu-libs libgcc libstdc++ libssl3 sqlite-libs tzdata zlib; \
    addgroup -g 1000 prowlarr; \
    adduser -D -u 1000 -G prowlarr -h /config -s /sbin/nologin prowlarr; \
    mkdir -p /config; \
    chown 1000:1000 /config

COPY --from=download /prowlarr /opt/prowlarr
COPY --from=download /package_info /opt/package_info
COPY --from=download /notices /usr/share/doc/prowlarr
COPY tests/smoke.sh /usr/local/bin/prowlarr-smoke-test

USER 1000:1000
WORKDIR /config

RUN sh /usr/local/bin/prowlarr-smoke-test "${APP_VERSION}"

EXPOSE 9696
ENTRYPOINT ["/opt/prowlarr/Prowlarr", "-nobrowser", "-data=/config"]
