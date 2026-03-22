# ── Stage 1: generate proto stubs + build binary ─────────────────────────────
FROM golang:1.22-alpine AS builder

RUN apk add --no-cache protobuf protobuf-dev git && \
    go install google.golang.org/protobuf/cmd/protoc-gen-go@v1.34.1 && \
    go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@v1.3.0

WORKDIR /src

# Copy everything so go mod tidy can see all imports
COPY . .

# Resolve full dependency graph (including health, reflection) and update go.sum
RUN go mod tidy && go mod download

# Generate proto stubs into ./proto/
RUN mkdir -p proto && \
    protoc --go_out=proto --go_opt=paths=source_relative \
           --go-grpc_out=proto --go-grpc_opt=paths=source_relative \
           identity.proto

RUN go build -o /grpc-echo .

# ── Stage 2: minimal runtime image ───────────────────────────────────────────
FROM gcr.io/distroless/static-debian12

COPY --from=builder /grpc-echo /grpc-echo
EXPOSE 50051
ENTRYPOINT ["/grpc-echo"]
