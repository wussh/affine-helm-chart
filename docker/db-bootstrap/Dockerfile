# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
# --------------------------------------------------------------------------
# AFFiNE DB Bootstrap image
# Provides: wait-and-load-secrets, wait-postgres, provision-db
# No credentials baked in. Non-root. CA certs. kubectl + psql.
# --------------------------------------------------------------------------
FROM alpine@sha256:48b0309ca019d89d40f670aa1bc06e426dc0931948452e8491e3d65087abc07d AS base

LABEL org.opencontainers.image.title="affine-db-bootstrap" \
      org.opencontainers.image.description="Kubernetes Secret waiter and PostgreSQL DB provisioner for AFFiNE" \
      org.opencontainers.image.source="https://github.com/wussh/affine-helm-chart" \
      org.opencontainers.image.licenses="MIT"

# --------------------------------------------------------------------------
# Download kubectl in a separate stage so the cache layer is reusable
# --------------------------------------------------------------------------
FROM base AS kubectl-dl

ARG KUBECTL_VERSION=v1.32.13
ARG KUBECTL_SHA256=db2ae479a63f3665d7f704ab18c0d4d4050144237980763221835b7305703c4c

RUN apk add --no-cache ca-certificates=20260413-r0 curl=8.14.1-r2 && \
    curl -fsSL \
      "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
      -o /usr/local/bin/kubectl && \
    echo "${KUBECTL_SHA256}  /usr/local/bin/kubectl" | sha256sum -c - && \
    chmod 0755 /usr/local/bin/kubectl

# --------------------------------------------------------------------------
# Final image
# --------------------------------------------------------------------------
FROM base AS final

RUN apk add --no-cache \
      ca-certificates=20260413-r0 \
      postgresql17-client=17.11-r0 \
    && rm -rf /var/cache/apk/*

COPY --from=kubectl-dl /usr/local/bin/kubectl /usr/local/bin/kubectl

# Non-root user
RUN addgroup -S appgroup && adduser -S -G appgroup -u 10001 appuser

COPY --chown=appuser:appgroup scripts/ /scripts/
RUN chmod 0555 /scripts/*.sh

USER 10001

# /run/affine-secrets must be mounted as emptyDir medium:Memory by Kubernetes
# Dockerfile cannot create it (read-only rootfs); container entrypoint creates it.
WORKDIR /scripts

# Default: show available commands
CMD ["sh", "-c", "echo 'Available: /scripts/wait-and-load-secrets.sh  /scripts/wait-postgres.sh  /scripts/provision-db.sh'"]
