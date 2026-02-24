FROM alpine:3.19

RUN apk add --no-cache \
    curl \
    jq \
    iproute2

# Install yggdrasil from the official release
ARG YGGDRASIL_VERSION=0.5.6
ARG TARGETARCH=amd64

RUN ARCH=$(uname -m) && \
    case "$ARCH" in \
      x86_64)  YGG_ARCH="amd64" ;; \
      aarch64) YGG_ARCH="arm64" ;; \
      armv7l)  YGG_ARCH="armv6" ;; \
      *) echo "Unsupported architecture: $ARCH" && exit 1 ;; \
    esac && \
    curl -fsSL "https://github.com/yggdrasil-network/yggdrasil-go/releases/download/v${YGGDRASIL_VERSION}/yggdrasil-${YGGDRASIL_VERSION}-linux-${YGG_ARCH}.tar.gz" \
      -o /tmp/yggdrasil.tar.gz && \
    tar -xzf /tmp/yggdrasil.tar.gz -C /usr/local/bin yggdrasil yggdrasilctl && \
    rm /tmp/yggdrasil.tar.gz

RUN mkdir -p /etc/yggdrasil

COPY coordinator-entrypoint.sh /coordinator-entrypoint.sh
COPY storage-entrypoint.sh /storage-entrypoint.sh
RUN chmod +x /coordinator-entrypoint.sh /storage-entrypoint.sh
