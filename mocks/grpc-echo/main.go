// grpc-echo: a minimal gRPC server that implements IdentityService.
// Used as a local mock for the external identity service.
package main

import (
	"context"
	"fmt"
	"log"
	"net"
	"time"

	pb "grpc-echo/proto"

	"google.golang.org/grpc"
	"google.golang.org/grpc/health"
	"google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/reflection"
)

type server struct {
	pb.UnimplementedIdentityServiceServer
}

func (s *server) GetIdentity(_ context.Context, req *pb.IdentityRequest) (*pb.IdentityResponse, error) {
	log.Printf("[GetIdentity] subject_id=%s", req.SubjectId)
	return &pb.IdentityResponse{
		SubjectId:   req.SubjectId,
		DisplayName: fmt.Sprintf("Mock User [%s]", req.SubjectId),
		Email:       fmt.Sprintf("%s@mock.local", req.SubjectId),
		TimestampMs: time.Now().UnixMilli(),
	}, nil
}

func (s *server) Echo(_ context.Context, req *pb.EchoRequest) (*pb.EchoResponse, error) {
	log.Printf("[Echo] message=%s", req.Message)
	return &pb.EchoResponse{
		Echo:       req.Message,
		ReceivedBy: "grpc-echo-mock",
	}, nil
}

func main() {
	lis, err := net.Listen("tcp", ":50051")
	if err != nil {
		log.Fatalf("failed to listen: %v", err)
	}

	s := grpc.NewServer()
	pb.RegisterIdentityServiceServer(s, &server{})

	// Standard gRPC health check – Envoy uses this
	healthSrv := health.NewServer()
	grpc_health_v1.RegisterHealthServer(s, healthSrv)
	healthSrv.SetServingStatus("", grpc_health_v1.HealthCheckResponse_SERVING)

	// gRPC reflection – lets grpcurl work without proto files
	reflection.Register(s)

	log.Printf("grpc-echo listening on :50051")
	if err := s.Serve(lis); err != nil {
		log.Fatalf("failed to serve: %v", err)
	}
}
