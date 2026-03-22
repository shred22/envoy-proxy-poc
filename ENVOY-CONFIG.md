# Envoy Configuration Deep Dive

This document explains every section of the Envoy proxy configuration used in this PoC. Two variants exist:

| File | Used by | TLS on egress |
|---|---|---|
| [openshift/envoy-local.yaml](openshift/envoy-local.yaml) | Docker Compose (`local-test.sh`) | No — plaintext to local mocks |
| [openshift/configmap-template.yaml](openshift/configmap-template.yaml) | OpenShift (`oc process`) | Yes — mTLS to real services |

---

## Top-Level Structure

```
node          ← Envoy identity (used in logs and xDS)
admin         ← Management API (stats, config dump, health)
layered_runtime
static_resources
  listeners   ← What Envoy accepts connections on
  clusters    ← Where Envoy forwards connections to
```

---

## Node

```yaml
node:
  id: envoy-local
  cluster: poc-local-cluster
```

The `id` and `cluster` fields identify this Envoy instance. They appear in access logs and are required if you ever connect to a control plane (xDS). They have no effect on static configuration but are good practice to set meaningfully.

---

## Admin

```yaml
admin:
  address:
    socket_address:
      address: 0.0.0.0   # local: 0.0.0.0 — OCP: 127.0.0.1
      port_value: 9901
```

The admin API exposes:

| Endpoint | Purpose |
|---|---|
| `/ready` | Returns `200 LIVE` when Envoy is ready |
| `/clusters` | Live cluster state and health |
| `/stats` | All counters and gauges |
| `/config_dump` | Full rendered config as JSON |
| `/listeners` | Active listeners |

**In OpenShift the admin address is `127.0.0.1`** so it is only reachable from within the Pod (e.g. via `kubectl/oc exec`). In the local Docker Compose stack it binds to `0.0.0.0` so you can reach it on `localhost:9901` from your host machine.

---

## Listeners

A listener is a network address Envoy binds to. Each listener has a chain of **filters** that process the connection. The outermost filter (the `transport_socket`) handles TLS; the inner `filter_chains` handle the protocol.

### Listener 1 — Ingress (port 8443)

```
External caller (mTLS) ──▶ Envoy :8443 ──▶ Spring Boot :8080 (plain HTTP)
```

#### Address

```yaml
address:
  socket_address:
    address: 0.0.0.0   # accept from any interface
    port_value: 8443
```

Binds to all interfaces so that external traffic can reach it. A port above 1024 means no special OS capability is needed.

#### Transport socket — Downstream TLS (mTLS termination)

```yaml
transport_socket:
  name: envoy.transport_sockets.tls
  typed_config:
    "@type": ...DownstreamTlsContext
    require_client_certificate: true    # ← enforces mutual TLS
    common_tls_context:
      tls_params:
        tls_minimum_protocol_version: TLSv1_2
        tls_maximum_protocol_version: TLSv1_3
      tls_certificate_sds_secret_configs:
        - name: server_cert             # ← Envoy's own cert (presented to callers)
          sds_config: ...
      validation_context_sds_secret_config:
        name: validation_context        # ← CA bundle used to verify caller's cert
        sds_config: ...
```

Key decisions:

- `require_client_certificate: true` — rejects connections that do not present a valid client certificate. This is the mutual in mTLS.
- `tls_minimum_protocol_version: TLSv1_2` — TLS 1.0 and 1.1 are disabled.
- Certificates are loaded via **SDS** (see SDS section below), not inline, so Envoy can hot-reload them when they rotate.

#### HTTP Connection Manager filter

```yaml
filters:
  - name: envoy.filters.network.http_connection_manager
    typed_config:
      codec_type: AUTO        # HTTP/1.1 or HTTP/2, auto-detected
      forward_client_cert_details: SANITIZE_SET
      set_current_client_cert_details:
        subject: true
        dns: true
        uri: true
```

`forward_client_cert_details: SANITIZE_SET` instructs Envoy to:
1. Strip any incoming `x-forwarded-client-cert` header (preventing spoofing).
2. Set a new one from the verified peer certificate.

Spring Boot receives the header `x-forwarded-client-cert` (XFCC) and can extract the caller's identity without doing any TLS itself. The `/api/ping` endpoint echoes this header so you can verify it end-to-end.

#### Route

```yaml
route_config:
  virtual_hosts:
    - domains: ["*"]
      routes:
        - match:
            prefix: "/"
          route:
            cluster: springboot_cluster
            timeout: 30s
            retry_policy:
              retry_on: "gateway-error,connect-failure,retriable-4xx"
              num_retries: 3
              per_try_timeout: 10s
              retry_back_off:
                base_interval: 0.25s
                max_interval: 5s
```

All paths are routed to `springboot_cluster` (loopback). The retry policy retries on 5xx gateway errors, connection failures, and 4xx errors marked as retriable — but not on 4xx client errors, avoiding infinite loops on bad requests.

---

### Listener 2 — Egress gRPC (port 9090)

```
Spring Boot (plaintext gRPC h2c) ──▶ Envoy :9090 ──▶ External gRPC :443 (mTLS)
```

#### Address

```yaml
address:
  socket_address:
    address: 127.0.0.1   # loopback only — not reachable outside the Pod
    port_value: 9090
```

Binding to `127.0.0.1` is a defence-in-depth measure. Even if a network policy misconfiguration occurs, this port cannot be reached from outside the Pod.

#### No transport socket

There is no `transport_socket` on this listener — the connection from Spring Boot arrives as **plain text**. TLS is applied on the cluster (upstream) side.

#### HTTP Connection Manager

```yaml
codec_type: HTTP2   # gRPC requires HTTP/2 — do not use AUTO here
```

`HTTP2` is hardcoded (not `AUTO`) because gRPC uses HTTP/2 trailers which `AUTO` does not negotiate correctly in all Envoy versions for listener-side codec detection. Setting it explicitly is safer.

#### Route

```yaml
routes:
  - match:
      prefix: "/"
      grpc: {}            # ← only match gRPC requests (Content-Type: application/grpc)
    route:
      cluster: identity_service_cluster
      timeout: 60s
      retry_policy:
        retry_on: "reset,connect-failure,retriable-status-codes"
        retriable_status_codes: [14]   # gRPC UNAVAILABLE
        num_retries: 3
```

The `grpc: {}` match guard ensures only gRPC traffic is accepted on this listener. `retriable_status_codes: [14]` retries on gRPC status `UNAVAILABLE` (code 14), which is the standard transient error in gRPC.

---

### Listener 3 — Egress HTTP (port 9091)

```
Spring Boot (plain HTTP) ──▶ Envoy :9091 ──▶ External REST :443 (mTLS)
```

Identical structure to Listener 2 but with `codec_type: AUTO` (HTTP/1.1 or HTTP/2, whatever the upstream negotiates) and routes to `external_rest_cluster`.

```yaml
address:
  socket_address:
    address: 127.0.0.1   # loopback only
    port_value: 9091
```

---

## Clusters

A cluster is an upstream destination. Envoy load-balances across the endpoints in a cluster.

### Cluster 1 — springboot_cluster (STATIC)

```yaml
name: springboot_cluster
type: STATIC             # address is fixed, no DNS lookup
connect_timeout: 5s
load_assignment:
  endpoints:
    - lb_endpoints:
        - endpoint:
            address:
              socket_address:
                address: 127.0.0.1
                port_value: 8080
```

`STATIC` type because `127.0.0.1` never changes. No TLS — traffic stays on the loopback interface inside the Pod.

#### Circuit breaker

```yaml
circuit_breakers:
  thresholds:
    - priority: DEFAULT
      max_connections: 100
      max_pending_requests: 100
      max_requests: 1000
      max_retries: 3
    - priority: HIGH
      max_connections: 200
      max_requests: 2000
```

Circuit breakers prevent the sidecar from overwhelming the Spring Boot app during bursts or when it is slow. When thresholds are exceeded, Envoy immediately rejects new requests with `503` rather than queuing them indefinitely. Stats are visible at `http://localhost:9901/stats?filter=circuit_breakers`.

#### Health check

```yaml
health_checks:
  - timeout: 3s
    interval: 10s
    unhealthy_threshold: 3
    healthy_threshold: 2
    http_health_check:
      path: /actuator/health
```

Envoy periodically polls `/actuator/health`. If the app fails 3 consecutive checks it is marked unhealthy and traffic is held back. It needs 2 consecutive successes to be marked healthy again.

---

### Cluster 2 — identity_service_cluster (STRICT_DNS + mTLS)

```yaml
name: identity_service_cluster
type: STRICT_DNS          # hostname resolved via DNS, re-resolved every 30s
connect_timeout: 5s
dns_refresh_rate: 30s
dns_lookup_family: V4_ONLY
```

`STRICT_DNS` means Envoy keeps the cluster endpoints in sync with DNS. Every 30 seconds it re-resolves the hostname. `V4_ONLY` avoids dual-stack resolution issues in some OpenShift network configurations.

#### HTTP/2 for gRPC

```yaml
typed_extension_protocol_options:
  envoy.extensions.upstreams.http.v3.HttpProtocolOptions:
    "@type": type.googleapis.com/envoy.extensions.upstreams.http.v3.HttpProtocolOptions
    explicit_http_config:
      http2_protocol_options: {}
```

This tells Envoy to always use HTTP/2 on this upstream. Using `typed_extension_protocol_options` (rather than the deprecated `http2_protocol_options` at cluster level) is the correct approach for Envoy v1.19+.

#### Upstream TLS (mTLS origination)

```yaml
transport_socket:
  name: envoy.transport_sockets.tls
  typed_config:
    "@type": ...UpstreamTlsContext
    sni: ${GRPC_SERVICE_HOST}          # ← SNI sent in the TLS ClientHello
    common_tls_context:
      tls_certificate_sds_secret_configs:
        - name: client_cert            # ← Envoy's client cert (proves its identity)
      validation_context_sds_secret_config:
        name: validation_context       # ← CA used to verify the server's cert
```

`UpstreamTlsContext` is the **outbound** TLS context (as opposed to `DownstreamTlsContext` on listeners). Envoy presents the `client_cert` to the remote server and validates the server's certificate against `validation_context`. The `sni` field sets the TLS SNI extension, which is required when connecting to a virtual-hosted HTTPS endpoint.

#### gRPC health check

```yaml
health_checks:
  - grpc_health_check: {}
```

Uses the standard [gRPC Health Checking Protocol](https://grpc.io/docs/guides/health-checking/) (`grpc.health.v1.Health/Check`). The `grpc-echo` mock registers a health server so this works end-to-end locally.

---

### Cluster 3 — external_rest_cluster (STRICT_DNS + mTLS)

Same structure as `identity_service_cluster` but:
- No `http2_protocol_options` — HTTP/1.1 or HTTP/2 negotiated via ALPN.
- Health check uses `http_health_check: { path: /health }`.

---

## SDS — Secret Discovery Service

Certificates are not embedded in the Envoy config. Instead, Envoy watches YAML files on disk and (re)loads them whenever they change. This is the **filesystem SDS** pattern.

### Why SDS instead of inline certs?

| Inline | SDS |
|---|---|
| Cert rotation requires config reload / pod restart | Cert rotation is hot-reloaded with zero downtime |
| Secret embedded in ConfigMap (less secure) | Secret stays in a Kubernetes Secret, mounted as a volume |
| Simple | Slightly more config |

### tls_certificate_sds_secret.yaml

```yaml
resources:
  - "@type": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.Secret
    name: server_cert          # matches the name referenced in the listener
    tls_certificate:
      certificate_chain:
        filename: /etc/envoy/certs/tls.crt
      private_key:
        filename: /etc/envoy/certs/tls.key
```

**One secret per file.** Envoy's path-based SDS rejects files with more than one resource entry — each `name:` reference must point to a file containing exactly that one secret.

### validation_context_sds_secret.yaml

```yaml
resources:
  - "@type": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.Secret
    name: validation_context
    validation_context:
      trusted_ca:
        filename: /etc/envoy/certs/ca.crt
```

The CA bundle used to validate peer certificates on both inbound (client cert verification) and outbound (server cert verification) connections.

### SDS reference in listener / cluster

```yaml
sds_config:
  path_config_source:
    path: /etc/envoy/sds/tls_certificate_sds_secret.yaml
  resource_api_version: V3
  # watched_directory is NOT used in envoy-local.yaml (local Docker)
  # It IS present in configmap-template.yaml (OpenShift)
```

`watched_directory` tells Envoy to watch the cert directory for inotify events (e.g. when a Kubernetes Secret is rotated and the volume is remounted). This field only exists in Envoy v1.20+ and is **omitted in the local config** because the local `envoy-local.yaml` file is targeted at Envoy v1.30 but the field causes a proto parse error when used with `path_config_source` in some builds — removing it makes the local config more portable.

---

## Local vs OpenShift Config Differences

| Aspect | `envoy-local.yaml` | `configmap-template.yaml` |
|---|---|---|
| Admin bind | `0.0.0.0` (reachable from host) | `127.0.0.1` (Pod-internal only) |
| Egress gRPC cluster | `grpc-echo:50051` plaintext | `${GRPC_SERVICE_HOST}:443` mTLS |
| Egress HTTP cluster | `rest-mock:8080` plaintext | `${REST_SERVICE_HOST}:443` mTLS |
| `watched_directory` on SDS | Not present | Present (cert rotation support) |
| Access log format | Plain stdout | JSON structured |
| Template parameters | None | `BRANCH_NAME_HY`, `PROJECT_NAME`, `GRPC_SERVICE_HOST`, `REST_SERVICE_HOST` |

---

## Access Logging

All three listeners log to stdout in JSON format (OpenShift config):

```json
{
  "ts": "2026-03-22T10:00:00.000Z",
  "direction": "ingress",
  "method": "GET",
  "path": "/api/ping",
  "status": 200,
  "duration_ms": 4,
  "upstream": "127.0.0.1:8080",
  "peer_cn": "CN=envoy-client,O=PoC,C=GB"
}
```

The `direction` field (`ingress`, `egress-grpc`, `egress-http`) lets you filter logs by traffic direction in a log aggregator.

---

## Retry Policy Summary

| Listener | Retry triggers | Max retries | Per-try timeout |
|---|---|---|---|
| Ingress `:8443` | `gateway-error`, `connect-failure`, `retriable-4xx` | 3 | 10s |
| Egress gRPC `:9090` | `reset`, `connect-failure`, gRPC status `14` (UNAVAILABLE) | 3 | 20s |
| Egress HTTP `:9091` | `gateway-error`, `connect-failure`, `retriable-4xx` | 3 | 10s |

Exponential back-off applies on all retry policies (`base: 0.25s`, `max: 5–10s`).

---

## Circuit Breaker Summary

| Cluster | Max connections | Max requests | Max retries |
|---|---|---|---|
| `springboot_cluster` | 100 (DEFAULT) / 200 (HIGH) | 1000 / 2000 | 3 / 5 |
| `identity_service_cluster` | 50 | 500 | 3 |
| `external_rest_cluster` | 50 | 500 | 3 |

Check live circuit breaker state:

```bash
curl -s http://localhost:9901/stats?filter=circuit_breakers
```

---

## Common Troubleshooting

### Envoy exits with `no such field: watched_directory`

The `watched_directory` field under `path_config_source` is not valid on all Envoy builds. Remove it from the local config. It is only needed (and valid) in the OpenShift ConfigMap for cert rotation support.

### SDS rejected: `Unexpected SDS secrets length`

Each path-based SDS file must contain **exactly one** secret. Split `server_cert` and `client_cert` into separate files, or remove the one that is not needed for the environment.

### Envoy healthcheck always failing

The `envoyproxy/envoy:v1.30` image does not include `curl` or `wget`. Use a bash TCP socket check:

```yaml
healthcheck:
  test: ["CMD-SHELL", "bash -c '</dev/tcp/127.0.0.1/9901'"]
```

### `The character [_] is never valid in a domain name`

Tomcat rejected a request where the `Host` header was set to a cluster name containing `_`. This happens when a healthcheck or test tries to exec `curl` inside the Envoy container (which has no `curl`) and the fallback sends a malformed request. Fix: run health checks from the host against `localhost:8080`, not via `docker compose exec envoy`.

### TLS key unreadable by Envoy container

`openssl` generates private keys with mode `600` (owner-only). The Envoy container runs as a different UID and cannot read them. The `gen-certs.sh` script runs `chmod 644` on all key files after generation.
