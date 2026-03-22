package com.poc.envoy.rest;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;
import org.springframework.web.reactive.function.client.WebClient;
import org.springframework.web.reactive.function.client.WebClientResponseException;
import reactor.core.publisher.Mono;

import java.time.Duration;
import java.util.Map;

/**
 * REST client that calls an external HTTP API.
 *
 * Traffic path (egress):
 *   Spring Boot (plain HTTP)
 *     -> Envoy sidecar  :9091  (egress_http_listener)
 *     -> External REST API  :443  (mTLS, external_rest_cluster)
 *
 * No TLS configuration needed here – Envoy originates mTLS on behalf
 * of the application.
 */
@Service
public class ExternalRestClient {

    private static final Logger log = LoggerFactory.getLogger(ExternalRestClient.class);

    private final WebClient webClient;

    public ExternalRestClient(
            WebClient.Builder builder,
            @Value("${egress.rest.base-url}") String baseUrl,
            @Value("${egress.rest.read-timeout:30000}") long readTimeoutMs) {

        this.webClient = builder
                .baseUrl(baseUrl)
                .build();

        log.info("ExternalRestClient configured with base-url: {}", baseUrl);
    }

    /**
     * GET /api/resource/{id} on the external service.
     */
    public Mono<Map> getResource(String resourceId) {
        log.debug("GET /api/resource/{} via Envoy egress", resourceId);
        return webClient.get()
                .uri("/api/resource/{id}", resourceId)
                .retrieve()
                .bodyToMono(Map.class)
                .timeout(Duration.ofSeconds(30))
                .doOnError(WebClientResponseException.class,
                        e -> log.error("REST call failed: {} {}", e.getStatusCode(), e.getMessage()))
                .doOnError(Exception.class,
                        e -> log.error("REST call error: {}", e.getMessage()));
    }

    /**
     * POST /api/resource on the external service.
     */
    public Mono<Map> createResource(Map<String, Object> payload) {
        log.debug("POST /api/resource via Envoy egress, payload keys: {}", payload.keySet());
        return webClient.post()
                .uri("/api/resource")
                .bodyValue(payload)
                .retrieve()
                .bodyToMono(Map.class)
                .timeout(Duration.ofSeconds(30))
                .doOnError(WebClientResponseException.class,
                        e -> log.error("REST POST failed: {} {}", e.getStatusCode(), e.getMessage()));
    }
}
