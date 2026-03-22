package com.poc.envoy.grpc;

import com.poc.envoy.grpc.proto.EchoRequest;
import com.poc.envoy.grpc.proto.EchoResponse;
import com.poc.envoy.grpc.proto.IdentityRequest;
import com.poc.envoy.grpc.proto.IdentityResponse;
import com.poc.envoy.grpc.proto.IdentityServiceGrpc;
import io.grpc.stub.StreamObserver;
import net.devh.boot.grpc.server.service.GrpcService;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * gRPC server implementation.
 *
 * Traffic path (ingress):
 *   External mTLS client
 *     -> Envoy sidecar  :8443  (terminates mTLS)
 *     -> Spring Boot HTTP :8080  (via ingress_listener cluster)
 *
 * NOTE: This gRPC service runs on port 6565 and is used for local unit tests.
 * The main ingress path is HTTP/REST at port 8080.
 */
@GrpcService
public class IdentityGrpcService extends IdentityServiceGrpc.IdentityServiceImplBase {

    private static final Logger log = LoggerFactory.getLogger(IdentityGrpcService.class);

    @Override
    public void getIdentity(IdentityRequest request, StreamObserver<IdentityResponse> responseObserver) {
        log.debug("getIdentity called for subject: {}", request.getSubjectId());

        IdentityResponse response = IdentityResponse.newBuilder()
                .setSubjectId(request.getSubjectId())
                .setDisplayName("Test User [" + request.getSubjectId() + "]")
                .setEmail(request.getSubjectId() + "@poc.example.com")
                .setTimestampMs(System.currentTimeMillis())
                .build();

        responseObserver.onNext(response);
        responseObserver.onCompleted();
    }

    @Override
    public void echo(EchoRequest request, StreamObserver<EchoResponse> responseObserver) {
        log.debug("echo called with message: {}", request.getMessage());

        EchoResponse response = EchoResponse.newBuilder()
                .setEcho(request.getMessage())
                .setReceivedBy("envoy-sidecar-poc")
                .build();

        responseObserver.onNext(response);
        responseObserver.onCompleted();
    }
}
