#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# local-test.sh
# Brings up the full Docker Compose stack, waits for all services to be ready,
# runs end-to-end tests, then tears everything down.
#
# Prerequisites:
#   - docker compose v2  (docker compose, not docker-compose)
#   - curl, grpcurl (optional – skipped if not installed)
#   - openssl
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
CERTS_DIR="$ROOT/certs"
COMPOSE="docker compose -f $ROOT/docker-compose.yaml"

# ── colour helpers ────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
pass() { echo -e "${GREEN}  PASS${NC}  $*"; }
fail() { echo -e "${RED}  FAIL${NC}  $*"; FAILED=$((FAILED+1)); }
info() { echo -e "${YELLOW}  ----${NC}  $*"; }
FAILED=0

# ── 1. Generate certs if missing ──────────────────────────────────────────────
if [ ! -f "$CERTS_DIR/ca.crt" ]; then
  info "Certificates not found – generating..."
  bash "$SCRIPT_DIR/gen-certs.sh"
else
  info "Certificates already present in $CERTS_DIR"
fi

# ── 2. Build images and start stack ───────────────────────────────────────────
info "Building images..."
$COMPOSE build --quiet

info "Starting stack..."
$COMPOSE up -d

# ── 3. Wait for Spring Boot to be ready ───────────────────────────────────────
# app shares envoy's network namespace, so port 8080 is published on the host
# via the envoy container's port mapping. Reach actuator directly over plain HTTP.
info "Waiting for Spring Boot app to become healthy (max 120s)..."
for i in $(seq 1 24); do
  if curl -sf http://localhost:8080/actuator/health/readiness > /dev/null 2>&1; then
    pass "Spring Boot is ready"
    break
  fi
  if [ "$i" -eq 24 ]; then
    fail "Spring Boot did not become ready in time"
    info "--- envoy logs ---"
    $COMPOSE logs envoy | tail -30
    info "--- app logs ---"
    $COMPOSE logs app | tail -30
    $COMPOSE down
    exit 1
  fi
  echo "  ... waiting ($((i*5))s elapsed)"
  sleep 5
done

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Running end-to-end tests"
echo "═══════════════════════════════════════════════════════════"

# ── 4. Envoy admin sanity check ────────────────────────────────────────────────
info "4.1 Envoy /ready"
STATUS=$(curl -so /dev/null -w "%{http_code}" http://localhost:9901/ready)
[ "$STATUS" = "200" ] && pass "Envoy admin /ready → $STATUS" || fail "Envoy admin /ready → $STATUS"

info "4.2 Envoy cluster membership"
CLUSTERS=$(curl -s http://localhost:9901/clusters)
for C in springboot_cluster grpc_mock_cluster rest_mock_cluster; do
  echo "$CLUSTERS" | grep -q "$C" && pass "Cluster present: $C" || fail "Cluster missing: $C"
done

# ── 5. Ingress – mTLS HTTP via Envoy :8443 ────────────────────────────────────
info "5. Ingress mTLS /api/ping"
RESP=$(curl -s -o /dev/null -w "%{http_code}" \
  --cacert "$CERTS_DIR/ca.crt" \
  --cert   "$CERTS_DIR/client.crt" \
  --key    "$CERTS_DIR/client.key" \
  https://localhost:8443/api/ping)
[ "$RESP" = "200" ] && pass "Ingress mTLS /api/ping → $RESP" || fail "Ingress mTLS /api/ping → $RESP"

info "5b. Ingress mTLS – verify peer cert header forwarded"
BODY=$(curl -s \
  --cacert "$CERTS_DIR/ca.crt" \
  --cert   "$CERTS_DIR/client.crt" \
  --key    "$CERTS_DIR/client.key" \
  https://localhost:8443/api/ping)
echo "$BODY" | grep -q '"status":"ok"' && pass "Response body contains status:ok" || fail "Unexpected body: $BODY"

# ── 6. Egress gRPC via Envoy :9090 -> grpc-echo :50051 ────────────────────────
info "6. Egress gRPC /api/identity/:id (via Envoy egress listener → grpc-echo mock)"
RESP=$(curl -s -o /dev/null -w "%{http_code}" \
  --cacert "$CERTS_DIR/ca.crt" \
  --cert   "$CERTS_DIR/client.crt" \
  --key    "$CERTS_DIR/client.key" \
  https://localhost:8443/api/identity/user-42)
[ "$RESP" = "200" ] && pass "Egress gRPC /api/identity/user-42 → $RESP" || fail "Egress gRPC /api/identity/user-42 → $RESP"

info "6b. Egress gRPC Echo"
RESP=$(curl -s -o /dev/null -w "%{http_code}" \
  --cacert "$CERTS_DIR/ca.crt" \
  --cert   "$CERTS_DIR/client.crt" \
  --key    "$CERTS_DIR/client.key" \
  -X POST https://localhost:8443/api/echo \
  -H "Content-Type: application/json" \
  -d '{"message":"hello-from-test"}')
[ "$RESP" = "200" ] && pass "Egress gRPC /api/echo → $RESP" || fail "Egress gRPC /api/echo → $RESP"

# ── 7. Egress HTTP via Envoy :9091 -> rest-mock :8080 ─────────────────────────
info "7. Egress HTTP /api/external/resource/:id (via Envoy egress listener → wiremock)"
RESP=$(curl -s -o /dev/null -w "%{http_code}" \
  --cacert "$CERTS_DIR/ca.crt" \
  --cert   "$CERTS_DIR/client.crt" \
  --key    "$CERTS_DIR/client.key" \
  https://localhost:8443/api/external/resource/res-99)
[ "$RESP" = "200" ] && pass "Egress HTTP /api/external/resource/res-99 → $RESP" || fail "Egress HTTP /api/external/resource/res-99 → $RESP"

info "7b. Egress HTTP POST /api/external/resource"
RESP=$(curl -s -o /dev/null -w "%{http_code}" \
  --cacert "$CERTS_DIR/ca.crt" \
  --cert   "$CERTS_DIR/client.crt" \
  --key    "$CERTS_DIR/client.key" \
  -X POST https://localhost:8443/api/external/resource \
  -H "Content-Type: application/json" \
  -d '{"name":"test","value":"data"}')
[ "$RESP" = "201" ] && pass "Egress HTTP POST /api/external/resource → $RESP" || fail "Egress HTTP POST /api/external/resource → $RESP"

# ── 8. Optional: grpcurl direct to grpc-echo ──────────────────────────────────
if command -v grpcurl &>/dev/null; then
  info "8. Direct grpcurl to grpc-echo mock (plaintext)"
  grpcurl -plaintext -d '{"subject_id":"grpcurl-test"}' \
    localhost:50051 identity.IdentityService/GetIdentity \
    && pass "grpcurl direct to grpc-echo" \
    || fail "grpcurl direct to grpc-echo"
else
  info "8. grpcurl not installed – skipping direct gRPC test (install with: go install github.com/fullstorydev/grpcurl/cmd/grpcurl@latest)"
fi

# ── 9. Circuit breaker stats ───────────────────────────────────────────────────
info "9. Circuit breaker stats"
curl -s "http://localhost:9901/stats?filter=circuit_breakers" | head -20

# ── 10. Summary ───────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════"
if [ "$FAILED" -eq 0 ]; then
  echo -e "${GREEN}  All tests passed!${NC}"
else
  echo -e "${RED}  $FAILED test(s) failed.${NC}"
fi
echo "═══════════════════════════════════════════════════════════"
echo ""
info "Stack is still running. To stop: docker compose -f $ROOT/docker-compose.yaml down"
info "Logs:                            docker compose -f $ROOT/docker-compose.yaml logs -f"
echo ""

exit $FAILED
