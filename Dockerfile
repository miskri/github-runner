# syntax=docker/dockerfile:1
FROM ubuntu:24.04 AS base

ARG TARGETARCH
ARG RUNNER_VERSION=latest

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    ImageOS=ubuntu24 \
    RUNNER_MANUALLY_TRAP_SIG=1

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git jq procps \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --shell /bin/bash runner \
    && mkdir -p /opt/runner /runners \
    && mkdir -m 700 /etc/github-runner \
    && chown runner:runner /opt/runner /runners

WORKDIR /opt/runner

RUN case "${TARGETARCH}" in \
        arm64) arch=arm64 ;; \
        amd64) arch=x64 ;; \
        *) echo "unsupported arch: ${TARGETARCH}"; exit 1 ;; \
    esac; \
    version="${RUNNER_VERSION}"; \
    if [ "$version" = "latest" ]; then \
        version="$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
            https://github.com/actions/runner/releases/latest | sed 's#.*/v##')"; \
    fi; \
    curl -fsSL "https://github.com/actions/runner/releases/download/v${version}/actions-runner-linux-${arch}-${version}.tar.gz" \
        | tar -xz; \
    ./bin/installdependencies.sh; \
    rm -rf /var/lib/apt/lists/*; \
    chown -R runner:runner /opt/runner

FROM base AS tools
RUN --mount=type=bind,source=config.json,target=/tmp/config.json \
    jq '.tools // {} | {apt: (.apt // []), run: (.run // [])}' /tmp/config.json > /tools.json

FROM base
COPY --from=tools /tools.json /etc/github-runner/tools.json
RUN apt-get update; \
    jq -r '.apt[]' /etc/github-runner/tools.json \
        | xargs -r apt-get install -y --no-install-recommends; \
    rm -rf /var/lib/apt/lists/*; \
    bash -euo pipefail -c "$(jq -r '.run[]' /etc/github-runner/tools.json)"

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
