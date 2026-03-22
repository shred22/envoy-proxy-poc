#!/usr/bin/env bash
# =============================================================================
# deploy-crc.sh
# Deploy the Envoy mTLS sidecar PoC to a local OpenShift CRC cluster.
#
# Prerequisites:
#   - crc start  (CRC running at https://console-openshift-console.apps-crc.testing)
#   - oc CLI authenticated  (oc login ...)
#   - docker or podman available
#   - openssl available
#
# Usage:
#   ./scripts/deploy-crc.sh [BRANCH]
#
#   BRANCH defaults to "main".  It is used as the BRANCH_NAME_HY parameter
#   (hyphens preserved) and as part of route hostnames.
#
# What it does (in order):
#   1.  Validate required tools
#   2.  Login to CRC cluster (prompts for credentials if not already logged in)
#   3.  Create / switch to the 'envoy-poc' OCP project
#   4.  Build the Spring Boot app image and push to CRC's internal registry
#   5.  Generate self-signed mTLS certificates  (skipped if certs already exist)
#   6.  Create the TLS Secret in OCP from the generated certs
#   7.  Apply SCC RoleBinding
#   8.  Apply ConfigMap template  (Envoy config + SDS files)
#   9.  Apply Deployment template  (Pod + Service + Route)
#  10.  Wait for rollout and print status + access URLs
# =============================================================================
set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
BRANCH="${1:-main}"
# Sanitise branch name: replace '/' and '_' with '-' for k8s names
BRANCH_HY="${BRANCH//\//-}"
BRANCH_HY="${BRANCH_HY//_/-}"

NAMESPACE="envoy-poc1"
PROJECT_NAME="envoy-poc1"
APP_NAME="${PROJECT_NAME}-${BRANCH_HY}"

# CRC internal registry (accessible from within the cluster)
CRC_INTERNAL_REGISTRY="image-registry.openshift-image-registry.svc:5000"
# CRC external registry (accessible from the host machine for docker push)
CRC_EXTERNAL_REGISTRY="default-route-openshift-image-registry.apps-crc.testing"

IMAGE_TAG="latest"
IMAGE_REPO="${CRC_EXTERNAL_REGISTRY}/${NAMESPACE}/${PROJECT_NAME}"
# The deployment template references the image via the internal registry hostname
DEPLOY_IMAGE="${CRC_INTERNAL_REGISTRY}/${NAMESPACE}/${PROJECT_NAME}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OPENSHIFT_DIR="${REPO_ROOT}/openshift"
CERT_DIR="${REPO_ROOT}/certs"
SPRING_APP_DIR="${REPO_ROOT}/spring-boot-app"

# External service mocks – for CRC we use placeholder hostnames.
# Override these env vars before running if you have real services:
GRPC_SERVICE_HOST="${GRPC_SERVICE_HOST:-grpc-mock.${NAMESPACE}.svc.cluster.local}"
REST_SERVICE_HOST="${REST_SERVICE_HOST:-rest-mock.${NAMESPACE}.svc.cluster.local}"

ROUTE_HOST="${APP_NAME}.apps-crc.testing"

# ─── Colour helpers ───────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
# 1. Validate prerequisites
# ─────────────────────────────────────────────────────────────────────────────
info "Checking prerequisites..."
for cmd in oc openssl mvn; do
  command -v "$cmd" &>/dev/null || die "'$cmd' not found in PATH. Please install it."
done

# Prefer podman on CRC hosts, fall back to docker
if command -v podman &>/dev/null; then
  CONTAINER_CLI="podman"
elif command -v docker &>/dev/null; then
  CONTAINER_CLI="docker"
else
  die "Neither 'podman' nor 'docker' found in PATH."
fi
success "Using container CLI: ${CONTAINER_CLI}"

# ─────────────────────────────────────────────────────────────────────────────
# 2. Ensure oc is connected to CRC
# ─────────────────────────────────────────────────────────────────────────────
info "Checking OCP cluster connection..."
if ! oc whoami &>/dev/null; then
  warn "Not logged in to OCP. Attempting login to CRC cluster..."
  echo ""
  echo "  Console: https://console-openshift-console.apps-crc.testing"
  echo "  Default credentials:  developer / developer  OR  kubeadmin / <password from 'crc console --credentials'>"
  echo ""
  oc login https://api.crc.testing:6443 --insecure-skip-tls-verify=true
fi
CURRENT_USER="$(oc whoami)"
success "Logged in as: ${CURRENT_USER}"

# ─────────────────────────────────────────────────────────────────────────────
# 3. Create / switch project
# ─────────────────────────────────────────────────────────────────────────────
info "Setting up project '${NAMESPACE}'..."
if oc get project "${NAMESPACE}" &>/dev/null; then
  info "Project '${NAMESPACE}' already exists – switching to it."
  oc project "${NAMESPACE}"
else
  oc new-project "${NAMESPACE}" \
    --description="Envoy mTLS sidecar PoC" \
    --display-name="Envoy PoC"
  success "Created project '${NAMESPACE}'."
fi

# ─────────────────────────────────────────────────────────────────────────────
# 4. Build Spring Boot image and push to CRC internal registry
# ─────────────────────────────────────────────────────────────────────────────
info "Building Spring Boot application..."
mvn -f "${SPRING_APP_DIR}/pom.xml" clean package -DskipTests -q
success "Maven build complete."

info "Building container image: ${IMAGE_REPO}:${IMAGE_TAG}"
"${CONTAINER_CLI}" build \
  -t "${IMAGE_REPO}:${IMAGE_TAG}" \
  "${SPRING_APP_DIR}"

info "Logging in to CRC image registry (${CRC_EXTERNAL_REGISTRY})..."
# oc registry login exposes the route-based registry for host-side push
oc registry login --insecure=true 2>/dev/null || true
"${CONTAINER_CLI}" login \
  --tls-verify=false \
  -u "$(oc whoami)" \
  -p "$(oc whoami -t)" \
  "${CRC_EXTERNAL_REGISTRY}"

info "Pushing image..."
"${CONTAINER_CLI}" push --tls-verify=false "${IMAGE_REPO}:${IMAGE_TAG}"
success "Image pushed to internal registry."

# ─────────────────────────────────────────────────────────────────────────────
# 5. Generate self-signed certificates (skip if already present)
# ─────────────────────────────────────────────────────────────────────────────
if [[ -f "${CERT_DIR}/tls.crt" && -f "${CERT_DIR}/tls.key" && -f "${CERT_DIR}/ca.crt" ]]; then
  info "Certificates already present in ${CERT_DIR} – skipping generation."
else
  info "Generating self-signed mTLS certificates..."
  bash "${SCRIPT_DIR}/gen-certs.sh" "${CERT_DIR}"
  success "Certificates generated in ${CERT_DIR}."
fi

# ─────────────────────────────────────────────────────────────────────────────
# 6. Create / update TLS Secret in OCP
# ─────────────────────────────────────────────────────────────────────────────
TLS_SECRET_NAME="${APP_NAME}-tls"
info "Creating TLS Secret '${TLS_SECRET_NAME}' in namespace '${NAMESPACE}'..."
oc create secret generic "${TLS_SECRET_NAME}" \
  --from-file=tls.crt="${CERT_DIR}/tls.crt" \
  --from-file=tls.key="${CERT_DIR}/tls.key" \
  --from-file=ca.crt="${CERT_DIR}/ca.crt" \
  -n "${NAMESPACE}" \
  --dry-run=client -o yaml | oc apply -f -
success "Secret '${TLS_SECRET_NAME}' applied."

# ─────────────────────────────────────────────────────────────────────────────
# 7. Apply SCC RoleBinding
# ─────────────────────────────────────────────────────────────────────────────
info "Applying SCC RoleBinding..."
# Patch the namespace in the file on the fly (it already targets envoy-poc)
oc apply -f "${OPENSHIFT_DIR}/scc-binding.yaml" -n "${NAMESPACE}"
success "SCC RoleBinding applied."

# ─────────────────────────────────────────────────────────────────────────────
# 8. Apply ConfigMap template (Envoy config + SDS files)
# ─────────────────────────────────────────────────────────────────────────────
info "Processing and applying Envoy ConfigMap template..."
oc process -f "${OPENSHIFT_DIR}/configmap-template.yaml" \
  -p PROJECT_NAME="${PROJECT_NAME}" \
  -p BRANCH_NAME_HY="${BRANCH_HY}" \
  -p GRPC_SERVICE_HOST="${GRPC_SERVICE_HOST}" \
  -p REST_SERVICE_HOST="${REST_SERVICE_HOST}" \
  | oc apply -n "${NAMESPACE}" -f -
success "Envoy ConfigMap applied."

# ─────────────────────────────────────────────────────────────────────────────
# 9. Apply Deployment template (Pod + Service + Route + ServiceAccount)
# ─────────────────────────────────────────────────────────────────────────────
info "Processing and applying Deployment template..."
oc process -f "${OPENSHIFT_DIR}/deployment-template.yaml" \
  -p PROJECT_NAME="${PROJECT_NAME}" \
  -p BRANCH_NAME_HY="${BRANCH_HY}" \
  -p APP_IMAGE="${DEPLOY_IMAGE}" \
  -p IMAGE_TAG="${IMAGE_TAG}" \
  -p ROUTE_HOST="${ROUTE_HOST}" \
  -p REPLICAS="1" \
  | oc apply -n "${NAMESPACE}" -f -
success "Deployment applied."

# ─────────────────────────────────────────────────────────────────────────────
# 10. Wait for rollout and print summary
# ─────────────────────────────────────────────────────────────────────────────
info "Waiting for rollout of '${APP_NAME}' (timeout 3 min)..."
oc rollout status deployment/"${APP_NAME}" \
  -n "${NAMESPACE}" \
  --timeout=3m

echo ""
success "=== Deployment complete ==="
echo ""
echo -e "  ${CYAN}Namespace:${NC}      ${NAMESPACE}"
echo -e "  ${CYAN}App name:${NC}       ${APP_NAME}"
echo -e "  ${CYAN}Image:${NC}          ${IMAGE_REPO}:${IMAGE_TAG}"
echo -e "  ${CYAN}Route (mTLS):${NC}   https://${ROUTE_HOST}"
echo -e "  ${CYAN}OCP Console:${NC}    https://console-openshift-console.apps-crc.testing/k8s/ns/${NAMESPACE}/deployments/${APP_NAME}"
echo ""
echo -e "  ${CYAN}Quick smoke-test (requires certs in ${CERT_DIR}):${NC}"
echo "  curl -v --cacert ${CERT_DIR}/ca.crt \\"
echo "       --cert   ${CERT_DIR}/client.crt \\"
echo "       --key    ${CERT_DIR}/client.key \\"
echo "       https://${ROUTE_HOST}/api/ping"
echo ""
echo -e "  ${CYAN}Envoy admin (via oc port-forward):${NC}"
echo "  oc port-forward -n ${NAMESPACE} deploy/${APP_NAME} 9901:9901"
echo "  curl http://localhost:9901/stats/prometheus"
echo ""
