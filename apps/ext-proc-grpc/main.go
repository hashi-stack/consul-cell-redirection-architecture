package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	corev3 "github.com/envoyproxy/go-control-plane/envoy/config/core/v3"
	epb "github.com/envoyproxy/go-control-plane/envoy/service/ext_proc/v3"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

var streamID uint64

// extProcServer implements envoy's ExternalProcessorServer over gRPC.
type extProcServer struct {
	epb.UnimplementedExternalProcessorServer
	routerURL string
	httpc     *http.Client
}

// Process handles a single bidirectional gRPC stream from Envoy.
// Envoy sends ProcessingRequests; we reply with ProcessingResponses.
func (s *extProcServer) Process(stream epb.ExternalProcessor_ProcessServer) error {
	id := atomic.AddUint64(&streamID, 1)
	log.Printf("ext-proc-grpc stream=%d opened", id)
	defer log.Printf("ext-proc-grpc stream=%d closed", id)

	for {
		req, err := stream.Recv()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return status.Errorf(codes.Unknown, "stream=%d recv: %v", id, err)
		}

		switch msg := req.Request.(type) {
		case *epb.ProcessingRequest_RequestHeaders:
			cell, err := s.fetchCell(stream.Context(), id)
			if err != nil {
				log.Printf("ext-proc-grpc stream=%d fetchCell error: %v; defaulting to A", id, err)
				cell = "A"
			}
			log.Printf("ext-proc-grpc stream=%d REQUEST_HEADERS x-cell=%q headers=%v", id, cell, headerNames(msg.RequestHeaders))

			if err := stream.Send(headerMutationResponse(cell)); err != nil {
				return status.Errorf(codes.Unknown, "stream=%d send: %v", id, err)
			}

		default:
			// For all other message types (response headers, body, trailers) just continue.
			if err := stream.Send(&epb.ProcessingResponse{
				Response: &epb.ProcessingResponse_RequestHeaders{
					RequestHeaders: &epb.HeadersResponse{
						Response: &epb.CommonResponse{
							Status: epb.CommonResponse_CONTINUE,
						},
					},
				},
			}); err != nil {
				return status.Errorf(codes.Unknown, "stream=%d send continue: %v", id, err)
			}
		}
	}
}

// fetchCell calls route-decider and returns the current x-cell value.
func (s *extProcServer) fetchCell(ctx context.Context, id uint64) (string, error) {
	startedAt := time.Now()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, s.routerURL, nil)
	if err != nil {
		return "", fmt.Errorf("build request: %w", err)
	}
	resp, err := s.httpc.Do(req)
	if err != nil {
		return "", fmt.Errorf("do request after %s: %w", time.Since(startedAt), err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(io.LimitReader(resp.Body, 128))
	if err != nil {
		return "", fmt.Errorf("read body: %w", err)
	}

	var routeResp struct {
		Cell string `json:"x-cell"`
	}
	if err := json.Unmarshal(body, &routeResp); err != nil {
		return "", fmt.Errorf("parse response %q: %w", string(body), err)
	}

	cell := strings.TrimSpace(routeResp.Cell)
	log.Printf("ext-proc-grpc stream=%d route-decider -> x-cell=%q duration=%s", id, cell, time.Since(startedAt))
	return cell, nil
}

// headerMutationResponse builds a ProcessingResponse that injects x-cell and
// clears the route cache so the gateway's header-based HTTPRoutes are re-evaluated.
func headerMutationResponse(cell string) *epb.ProcessingResponse {
	return &epb.ProcessingResponse{
		Response: &epb.ProcessingResponse_RequestHeaders{
			RequestHeaders: &epb.HeadersResponse{
				Response: &epb.CommonResponse{
					Status:          epb.CommonResponse_CONTINUE_AND_REPLACE,
					ClearRouteCache: true,
					HeaderMutation: &epb.HeaderMutation{
						SetHeaders: []*corev3.HeaderValueOption{
							{
								Header: &corev3.HeaderValue{
									Key:      "x-cell",
									RawValue: []byte(cell),
								},
							},
						},
					},
				},
			},
		},
	}
}

// headerNames extracts just the header keys for concise logging.
func headerNames(h *epb.HttpHeaders) []string {
	if h == nil || h.Headers == nil {
		return nil
	}
	names := make([]string, 0, len(h.Headers.Headers))
	for _, hv := range h.Headers.Headers {
		names = append(names, hv.GetKey())
	}
	return names
}

func main() {
	grpcAddr := "0.0.0.0:50051"
	if v := os.Getenv("GRPC_ADDR"); v != "" {
		grpcAddr = v
	}

	routerURL := os.Getenv("ROUTER_URL")
	if routerURL == "" {
		routerURL = "http://route-decider.virtual.consul:8080/get-cell"
	}

	routerTimeout := 5000 * time.Millisecond
	if ms := os.Getenv("ROUTER_TIMEOUT_MS"); ms != "" {
		parsed, err := strconv.Atoi(ms)
		if err != nil {
			log.Fatalf("invalid ROUTER_TIMEOUT_MS %q: %v", ms, err)
		}
		routerTimeout = time.Duration(parsed) * time.Millisecond
	}

	httpc := &http.Client{Timeout: routerTimeout}
	log.Printf("ext-proc-grpc starting grpc_addr=%s router_url=%s timeout=%s", grpcAddr, routerURL, routerTimeout)

	lis, err := net.Listen("tcp", grpcAddr)
	if err != nil {
		log.Fatalf("listen %s: %v", grpcAddr, err)
	}

	srv := grpc.NewServer()
	epb.RegisterExternalProcessorServer(srv, &extProcServer{
		routerURL: routerURL,
		httpc:     httpc,
	})

	log.Printf("ext-proc-grpc listening on %s", grpcAddr)
	if err := srv.Serve(lis); err != nil {
		log.Fatalf("serve: %v", err)
	}
}
