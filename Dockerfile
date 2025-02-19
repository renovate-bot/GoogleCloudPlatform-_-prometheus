ARG IMAGE_BUILD_NODEJS=launcher.gcr.io/google/nodejs
ARG IMAGE_BUILD_GO=docker.io/library/golang:1.23.4-bookworm@sha256:ef30001eeadd12890c7737c26f3be5b3a8479ccdcdc553b999c84879875a27ce

ARG IMAGE_BASE_DEBUG=gcr.io/distroless/static-debian12:debug
ARG IMAGE_BASE=gcr.io/distroless/base-nossl@sha256:c2977db459c8763ee3d739f68b547d2193af92267f989754c09153919757d36a

FROM ${IMAGE_BUILD_GO} AS gobase

# Compile the UI assets.
FROM ${IMAGE_BUILD_NODEJS} as assets
# To build the UI we need a recent node version and the go toolchain.
RUN install_node v17.9.0
COPY --from=gobase /usr/local/go /usr/local/
ENV PATH="/usr/local/go/bin:${PATH}"
WORKDIR /app
COPY . ./
RUN pwd
# Only build the UI but don't run ui-install as we vendor node_modules.
RUN make ui-build
RUN scripts/compress_assets.sh
RUN make npm_licenses

# Build the actual Go binary.
FROM gobase as buildbase
WORKDIR /app
COPY --from=assets /app ./
RUN CGO_ENABLED=1 GOEXPERIMENT=boringcrypto go build \
    -tags boring,builtinassets -mod=vendor \
    -ldflags="-X github.com/prometheus/common/version.Version=$(cat VERSION) \
    -X github.com/prometheus/common/version.BuildDate=$(date --iso-8601=seconds)" \
    ./cmd/prometheus

# Configure distroless base image like the upstream Prometheus image.
# Since the directory and symlink setup needs shell access, we need yet another
# intermediate stage.
FROM ${IMAGE_BASE_DEBUG} as appbase

COPY documentation/examples/prometheus.yml  /etc/prometheus/prometheus.yml
COPY console_libraries/                     /usr/share/prometheus/console_libraries/
COPY consoles/                              /usr/share/prometheus/consoles/
RUN ["/busybox/sh", "-c", "ln -s /usr/share/prometheus/console_libraries /usr/share/prometheus/consoles/ /etc/prometheus/"]
RUN ["/busybox/sh", "-c", "mkdir -p /prometheus"]

FROM ${IMAGE_BASE}

COPY --from=buildbase /app/prometheus /bin/prometheus
COPY --from=appbase --chown=nobody:nobody /etc/prometheus /etc/prometheus
COPY --from=appbase --chown=nobody:nobody /prometheus /prometheus
COPY --from=appbase /usr/share/prometheus /usr/share/prometheus
COPY LICENSE /LICENSE
COPY NOTICE /NOTICE
COPY --from=assets /app/npm_licenses.tar.bz2 /npm_licenses.tar.bz2

USER       nobody
EXPOSE     9090
VOLUME     [ "/prometheus" ]
ENTRYPOINT [ "/bin/prometheus" ]
CMD        [ "--config.file=/etc/prometheus/prometheus.yml", \
             "--storage.tsdb.path=/prometheus", \
             "--web.console.libraries=/usr/share/prometheus/console_libraries", \
             "--web.console.templates=/usr/share/prometheus/consoles" ]
