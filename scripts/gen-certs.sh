#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# gen-certs.sh
# Generates a self-signed CA, server cert, and client cert for local PoC
# testing. Do NOT use these certs in production.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

CERT_DIR="$(cd "$(dirname "$0")/.." && pwd)/certs"
[ -n "${1:-}" ] && CERT_DIR="$1"
mkdir -p "$CERT_DIR"
cd "$CERT_DIR"

DAYS=365

echo "==> Generating CA key and self-signed certificate..."
openssl req -newkey rsa:4096 -nodes -keyout ca.key -x509 -days $DAYS \
  -out ca.crt \
  -subj "/CN=poc-ca/O=PoC/C=GB"

echo "==> Generating server (Envoy ingress) key and CSR..."
openssl req -newkey rsa:4096 -nodes -keyout tls.key \
  -out server.csr \
  -subj "/CN=envoy-server/O=PoC/C=GB"

cat > server-ext.cnf <<EOF
[req]
req_extensions = v3_req
[v3_req]
subjectAltName = @alt_names
[alt_names]
DNS.1 = localhost
DNS.2 = envoy-server
IP.1  = 127.0.0.1
EOF

echo "==> Signing server certificate with CA..."
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out tls.crt -days $DAYS -extfile server-ext.cnf -extensions v3_req

echo "==> Generating client key and CSR..."
openssl req -newkey rsa:4096 -nodes -keyout client.key \
  -out client.csr \
  -subj "/CN=envoy-client/O=PoC/C=GB"

echo "==> Signing client certificate with CA..."
openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out client.crt -days $DAYS

# Make all keys world-readable so the Envoy container (different UID) can read them
chmod 644 tls.key client.key ca.key

echo "==> Creating Kubernetes/OpenShift TLS Secret manifest..."
# Write the Secret YAML directly – no kubectl required on the local machine.
TLS_CRT_B64=$(base64 -w0 tls.crt)
TLS_KEY_B64=$(base64 -w0 tls.key)
CA_CRT_B64=$(base64 -w0 ca.crt)

cat > "$CERT_DIR/../openshift/tls-secret.yaml" <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: envoy-mtls-certs
type: Opaque
data:
  tls.crt: ${TLS_CRT_B64}
  tls.key: ${TLS_KEY_B64}
  ca.crt:  ${CA_CRT_B64}
YAML

echo ""
echo "Done. Files in $CERT_DIR:"
ls -1 "$CERT_DIR"  2>/dev/null || ls -1
echo ""
echo "Secret manifest written to openshift/tls-secret.yaml"
echo "Apply with:  oc apply -f openshift/tls-secret.yaml -n <namespace>"
