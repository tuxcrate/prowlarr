ARG BASE_IMAGE
FROM --platform=$BUILDPLATFORM ${BASE_IMAGE} AS download

SHELL ["/bin/ash", "-o", "pipefail", "-c"]

ARG APP_VERSION
ARG TARGETARCH
ARG UPSTREAM_PRERELEASE
ARG UPSTREAM_URL_AMD64
ARG UPSTREAM_SHA256_AMD64
ARG UPSTREAM_URL_ARM64
ARG UPSTREAM_SHA256_ARM64

RUN set -eux; \
    : "${APP_VERSION:?APP_VERSION must be set}"; \
    apk add --no-cache ca-certificates curl; \
    case "$UPSTREAM_PRERELEASE" in \
        true) branch=develop ;; false) branch=master ;; \
        *) echo "UPSTREAM_PRERELEASE must be true or false" >&2; exit 1 ;; \
    esac; \
    case "$TARGETARCH" in \
        amd64) download_url="$UPSTREAM_URL_AMD64"; checksum="$UPSTREAM_SHA256_AMD64" ;; \
        arm64) download_url="$UPSTREAM_URL_ARM64"; checksum="$UPSTREAM_SHA256_ARM64" ;; \
        *) echo "Unsupported architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    : "${download_url:?upstream asset URL must be set}" "${checksum:?upstream SHA-256 must be set}"; \
    curl --fail --location --retry 3 --proto '=https' --proto-redir '=https' \
        "$download_url" --output /tmp/prowlarr.tar.gz; \
    printf '%s  /tmp/prowlarr.tar.gz\n' "$checksum" | sha256sum -c -; \
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
