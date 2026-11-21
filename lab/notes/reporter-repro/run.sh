#!/usr/bin/env bash
# Reproduces the lab reporter's response-size limit without a cluster:
# runs the lab image (APP_MODE=reporter) against fake_api.py, which returns a
# PodList of an exact byte size, and prints what /report returns for each size.
# Needs: docker, openssl, curl. Uses host port 18080.
set -euo pipefail
cd "$(dirname "$0")"

LAB_IMAGE="docker.io/ebinterview/eb-debug-app:1.0.1"
PY_IMAGE="python:3.12.16-slim-trixie"
NET="reporter-repro"
WORK="$(mktemp -d)"

cleanup() {
  docker rm -f repro-fakeapi repro-reporter >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# Self-signed cert for kubernetes.default.svc, used as the "cluster CA" too
mkdir -p "$WORK/sa"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -subj "/CN=kubernetes.default.svc" \
  -addext "subjectAltName=DNS:kubernetes.default.svc" 2>/dev/null
cp "$WORK/cert.pem" "$WORK/sa/ca.crt"
printf 'fake-token' > "$WORK/sa/token"
printf 'test' > "$WORK/sa/namespace"
cp fake_api.py "$WORK/"
chmod -R a+rX "$WORK"   # the lab image runs as UID 65532

docker network create "$NET" >/dev/null

for size in 500 1000 1024 1025 1100 6000 45000; do
  docker rm -f repro-fakeapi repro-reporter >/dev/null 2>&1 || true
  docker run -d --name repro-fakeapi --network "$NET" \
    --network-alias kubernetes.default.svc \
    -v "$WORK:/w:ro" "$PY_IMAGE" python /w/fake_api.py "$size" >/dev/null
  docker run -d --name repro-reporter --network "$NET" -p 18080:8080 \
    -e APP_MODE=reporter -e PORT=8080 -e NAMESPACE=test \
    -e SSL_CERT_FILE=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
    -v "$WORK/sa:/var/run/secrets/kubernetes.io/serviceaccount:ro" \
    "$LAB_IMAGE" >/dev/null
  sleep 3
  printf 'body=%-6s bytes -> %s\n' "$size" "$(curl -s localhost:18080/report)"
done
