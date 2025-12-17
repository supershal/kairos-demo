#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

# Discover script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

function print() {
  if [ -t 0 ]; then
    prefix='\033[34;1m▶\033[0m'
  else
    prefix='=>'
  fi
  printf "${prefix} ${1}\n"
}
readonly PLATFORM="linux/amd64"

print "Building CIS hardened base image..."
docker buildx build --progress=plain \
  --platform="${PLATFORM}" \
  --pull \
  --output=type=registry \
  --file="${SCRIPT_DIR}/dockerfiles/Dockerfile.base" \
  --build-arg=VERSION="${VERSION}" \
	--secret="id=ubuntu-pro-token,env=UBUNTU_PRO_TOKEN" \
  --tag="${OCI_REGISTRY}/base-image:${VERSION}" \
  "${SCRIPT_DIR}"

print "Building bootstrap image..."
docker buildx build --progress=plain \
  --platform="${PLATFORM}" \
  --pull \
  --output=type=registry \
  --file="${SCRIPT_DIR}/dockerfiles/Dockerfile.bootstrap" \
  --build-arg="BASE_IMAGE_VERSION=${VERSION}" \
  --build-arg="BASE_IMAGE_REGISTRY=${OCI_REGISTRY}" \
  --tag="${OCI_REGISTRY}/bootstrap-image:${VERSION}" "${SCRIPT_DIR}"

print "Building final image..."
docker buildx build --progress=plain \
  --platform="${PLATFORM}" \
  --pull \
  --output=type=registry \
  --file="${SCRIPT_DIR}/dockerfiles/Dockerfile.final" \
  --build-arg="BASE_IMAGE_VERSION=${VERSION}" \
  --build-arg="BASE_IMAGE_REGISTRY=${OCI_REGISTRY}" \
  --tag="${OCI_REGISTRY}/final-image:${VERSION}" "${SCRIPT_DIR}"

mkdir -p "$SCRIPT_DIR"/build
docker run --platform "${PLATFORM}" --rm -ti \
  -v "$SCRIPT_DIR"/cloud-config.yaml:/config.yaml \
  -v "$SCRIPT_DIR/build":/tmp \
  quay.io/kairos/auroraboot \
  --set "container_image=${OCI_REGISTRY}/final-image:${VERSION}" \
  --set "disable_http_server=true" \
  --set "disable_netboot=true" \
  --cloud-config /config.yaml

# Copy or override the bootstrap.iso file
cp "$SCRIPT_DIR/build/auroraboot/kairos-*.iso" "$SCRIPT_DIR/bootstrap.iso"
