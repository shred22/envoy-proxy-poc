package com.poc.envoy.rest;

import com.poc.envoy.grpc.IdentityGrpcClient;
import com.poc.envoy.grpc.proto.EchoResponse;
import com.poc.envoy.grpc.proto.IdentityResponse;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;
import reactor.core.publisher.Mono;

import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * REST controller – the Spring Boot app's HTTP surface.
 *
 * Ingress path:
 *   External caller  --mTLS-->  Envoy :8443  --plain HTTP-->  this controller :8080
 */
@RestController
@RequestMapping("/api")
public class AppController {

    private static final Logger log = LoggerFactory.getLogger(AppController.class);

    private final IdentityGrpcClient grpcClient;
    private final ExternalRestClient restClient;

    public AppController(IdentityGrpcClient grpcClient, ExternalRestClient restClient) {
        this.grpcClient = grpcClient;
        this.restClient = restClient;
    }

    // ── Ingress smoke-test ────────────────────────────────────────────────

    /**
     * GET /api/ping
     * Verifies the ingress path is working. Returns server timestamp and
     * the caller's peer certificate subject if forwarded by Envoy.
     */
    @GetMapping("/ping")
    public ResponseEntity<Map<String, Object>> ping(
            @RequestHeader(value = "x-forwarded-client-cert", required = false) String xfcc) {

        Map<String, Object> body = new LinkedHashMap<>();
        body.put("status", "ok");
        body.put("server_time", Instant.now().toString());
        body.put("peer_cert_header", xfcc != null ? xfcc : "not-present");
        log.info("Received ping. XFCC header present: {}", xfcc != null);
        return ResponseEntity.ok(body);
    }

    // ── gRPC egress ───────────────────────────────────────────────────────

    /**
     * GET /api/identity/{subjectId}
     * Calls the external gRPC identity service via Envoy egress.
     */
    @GetMapping("/identity/{subjectId}")
    public ResponseEntity<Map<String, Object>> getIdentity(@PathVariable String subjectId) {
        log.info("Fetching identity for subject: {}", subjectId);
        IdentityResponse resp = grpcClient.getIdentity(subjectId);

        Map<String, Object> body = new LinkedHashMap<>();
        body.put("subject_id", resp.getSubjectId());
        body.put("display_name", resp.getDisplayName());
        body.put("email", resp.getEmail());
        body.put("timestamp_ms", resp.getTimestampMs());
        return ResponseEntity.ok(body);
    }

    /**
     * POST /api/echo
     * Body: { "message": "hello" }
     * Sends an echo over gRPC via Envoy egress and returns the response.
     */
    @PostMapping("/echo")
    public ResponseEntity<Map<String, Object>> echo(@RequestBody Map<String, String> req) {
        String message = req.getOrDefault("message", "");
        log.info("Echo via gRPC: {}", message);
        EchoResponse resp = grpcClient.echo(message);

        Map<String, Object> body = new LinkedHashMap<>();
        body.put("echo", resp.getEcho());
        body.put("received_by", resp.getReceivedBy());
        return ResponseEntity.ok(body);
    }

    // ── REST egress ───────────────────────────────────────────────────────

    /**
     * GET /api/external/resource/{id}
     * Calls the external REST API via Envoy egress, then returns the response.
     */
    @GetMapping("/external/resource/{id}")
    public Mono<ResponseEntity<Map>> getExternalResource(@PathVariable String id) {
        log.info("Fetching external resource: {}", id);
        return restClient.getResource(id)
                .map(ResponseEntity::ok)
                .onErrorReturn(ResponseEntity.status(502).build());
    }

    /**
     * POST /api/external/resource
     * Proxies a resource creation to the external REST API via Envoy egress.
     */
    @PostMapping("/external/resource")
    public Mono<ResponseEntity<Map>> createExternalResource(@RequestBody Map<String, Object> payload) {
        log.info("Creating external resource via REST egress");
        return restClient.createResource(payload)
                .map(body -> ResponseEntity.status(201).<Map>body(body))
                .onErrorReturn(ResponseEntity.status(502).build());
    }
}
