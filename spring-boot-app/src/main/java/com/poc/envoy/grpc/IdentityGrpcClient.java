package com.poc.envoy.grpc;

import com.poc.envoy.grpc.proto.EchoRequest;
import com.poc.envoy.grpc.proto.EchoResponse;
import com.poc.envoy.grpc.proto.IdentityRequest;
import com.poc.envoy.grpc.proto.IdentityResponse;
import com.poc.envoy.grpc.proto.IdentityServiceGrpc;
import io.grpc.StatusRuntimeException;
import net.devh.boot.grpc.client.inject.GrpcClient;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

/**
 * gRPC client that calls the external identity service.
 *
 * Traffic path (egress):
 *   Spring Boot (plaintext gRPC)
 *     -> Envoy sidecar  :9090  (egress_grpc_listener)
 *     -> External gRPC service  :443  (mTLS, identity_service_cluster)
 *
 * The channel is plaintext (PLAINTEXT negotiation) because Envoy handles mTLS.
 * The channel address is configured via grpc.client.identity-service.address
 * in application.yaml.
 */
@Service
public class IdentityGrpcClient {

    private static final Logger log = LoggerFactory.getLogger(IdentityGrpcClient.class);

    @GrpcClient("identity-service")
    private IdentityServiceGrpc.IdentityServiceBlockingStub identityStub;

    public IdentityResponse getIdentity(String subjectId) {
        log.debug("Calling external identity service for subject: {}", subjectId);
        try {
            return identityStub.getIdentity(
                    IdentityRequest.newBuilder().setSubjectId(subjectId).build());
        } catch (StatusRuntimeException e) {
            log.error("gRPC call failed: {} - {}", e.getStatus().getCode(), e.getMessage());
            throw new RuntimeException("Identity service unavailable: " + e.getStatus().getCode(), e);
        }
    }

    public EchoResponse echo(String message) {
        log.debug("Sending echo via gRPC: {}", message);
        try {
            return identityStub.echo(
                    EchoRequest.newBuilder().setMessage(message).build());
        } catch (StatusRuntimeException e) {
            log.error("gRPC echo failed: {} - {}", e.getStatus().getCode(), e.getMessage());
            throw new RuntimeException("Echo service unavailable: " + e.getStatus().getCode(), e);
        }
    }
}
