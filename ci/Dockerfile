# Toolbox image for every image-factory CI job.
# Pinned tool versions; keep in step with ci/versions.env (used by GitHub Actions).
FROM docker:27-cli AS dockercli

FROM python:3.13-slim-bookworm

ARG PACKER_VERSION=1.15.4
ARG TERRAFORM_VERSION=1.13.4
ARG SYFT_VERSION=1.55.0
ARG GRYPE_VERSION=0.120.0
ARG CRANE_VERSION=0.22.0

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    CHECKPOINT_DISABLE=1

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git jq unzip openssh-client shellcheck \
 && rm -rf /var/lib/apt/lists/*

# HashiCorp tools, checksum-verified against the published SHA256SUMS
RUN set -eux; cd /tmp; \
    for tool in "packer:${PACKER_VERSION}" "terraform:${TERRAFORM_VERSION}"; do \
      name="${tool%%:*}"; ver="${tool#*:}"; \
      curl -fsSLO "https://releases.hashicorp.com/${name}/${ver}/${name}_${ver}_linux_amd64.zip"; \
      curl -fsSLO "https://releases.hashicorp.com/${name}/${ver}/${name}_${ver}_SHA256SUMS"; \
      grep "${name}_${ver}_linux_amd64.zip" "${name}_${ver}_SHA256SUMS" | sha256sum -c -; \
      unzip -o "${name}_${ver}_linux_amd64.zip" -d /usr/local/bin "${name}"; \
      rm -f "${name}_${ver}"_*; \
    done

# Anchore Syft (SBOM) and Grype (vulnerability scan)
RUN set -eux; cd /tmp; \
    for tool in "syft:${SYFT_VERSION}" "grype:${GRYPE_VERSION}"; do \
      name="${tool%%:*}"; ver="${tool#*:}"; \
      base="https://github.com/anchore/${name}/releases/download/v${ver}"; \
      curl -fsSLO "${base}/${name}_${ver}_linux_amd64.tar.gz"; \
      curl -fsSLO "${base}/${name}_${ver}_checksums.txt"; \
      grep " ${name}_${ver}_linux_amd64.tar.gz\$" "${name}_${ver}_checksums.txt" | sha256sum -c -; \
      tar -xzf "${name}_${ver}_linux_amd64.tar.gz" -C /usr/local/bin "${name}"; \
      rm -f "${name}_${ver}"_*; \
    done

# crane: retags container images in the registry without pulling them
RUN set -eux; cd /tmp; \
    base="https://github.com/google/go-containerregistry/releases/download/v${CRANE_VERSION}"; \
    curl -fsSLO "${base}/go-containerregistry_Linux_x86_64.tar.gz"; \
    curl -fsSLO "${base}/checksums.txt"; \
    grep " go-containerregistry_Linux_x86_64.tar.gz\$" checksums.txt | sha256sum -c -; \
    tar -xzf go-containerregistry_Linux_x86_64.tar.gz -C /usr/local/bin crane; \
    rm -f go-containerregistry_Linux_x86_64.tar.gz checksums.txt

# Docker CLI, for Packer's docker builder (talks to the dind service)
COPY --from=dockercli /usr/local/bin/docker /usr/local/bin/docker

# Ansible, cloud CLIs and the renderer's Python dependencies
COPY requirements.txt requirements-core.txt /tmp/pip/
RUN pip install -r /tmp/pip/requirements.txt && rm -rf /tmp/pip

RUN packer version && terraform version && syft version && grype version \
 && crane version && docker --version && ansible --version && az version && aws --version
