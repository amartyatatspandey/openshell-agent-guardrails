// kyverno-guard is an OpenShell supervisor middleware that asks a Kyverno
// authorization server to decide every HTTP request a sandboxed agent sends to
// the hosts it is attached to.
//
// OpenShell enforces: it calls EvaluateHttpRequest after network policy has
// allowed a request and before it injects provider credentials, and it blocks
// the request when this service says deny. Kyverno decides: the request is
// forwarded, as a nested raw HTTP request, to kyverno-authz running in HTTP
// mode, where ValidatingPolicy CEL rules see the real method, host, path,
// headers and JSON body. A 403 from Kyverno becomes a deny whose reason code is
// the Kyverno denial reason, so it shows up in OpenShell's own audit log.
package main

import (
	"bytes"
	"context"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"regexp"
	"slices"
	"strings"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	ext "kyverno-guard/gen/extensionv1"
	mw "kyverno-guard/gen/middlewarev1"
)

const (
	implementationName = "kyverno-guard"
	implementationVer  = "0.1.0"
	// Capability every supervisor-middleware peer must support (OpenShell
	// crates/openshell-core/src/extension_protocol.rs, protocol 1.0).
	contractCapability = "openshell.supervisor-middleware.contract"
	protocolMajor      = 1
	protocolMinor      = 0
	maxPayloadBytes    = 256 * 1024
	// OpenShell may send up to 4 MiB plus its envelope; allow headroom.
	grpcMessageLimit = 6 << 20
	fallbackReason   = "kyverno_denied"
)

// OpenShell rejects reason codes that are not short lowercase identifiers.
var reasonCode = regexp.MustCompile(`^[a-z][a-z0-9_]{0,63}$`)

// Headers that describe the outer transport, not the request being judged.
var skipHeaders = []string{"host", "content-length", "transfer-encoding", "connection"}

type guard struct {
	mw.UnimplementedSupervisorMiddlewareServer
	authzURL string
	client   *http.Client
}

func peerMetadata() *ext.PeerMetadata {
	return &ext.PeerMetadata{
		ProtocolVersion:       &ext.ProtocolVersion{Major: protocolMajor, Minor: protocolMinor},
		ImplementationName:    implementationName,
		ImplementationVersion: implementationVer,
		SupportedCapabilities: []string{contractCapability},
		RequiredCapabilities:  []string{contractCapability},
	}
}

func (g *guard) Describe(_ context.Context, req *mw.MiddlewareDescribeRequest) (*mw.MiddlewareManifest, error) {
	gw := req.GetGateway()
	if gw == nil || gw.GetProtocolVersion() == nil {
		return nil, status.Error(codes.FailedPrecondition, "gateway did not provide protocol metadata")
	}
	if gw.GetProtocolVersion().GetMajor() != protocolMajor {
		return nil, status.Errorf(codes.FailedPrecondition, "unsupported gateway protocol %d.%d; this service speaks %d.x",
			gw.GetProtocolVersion().GetMajor(), gw.GetProtocolVersion().GetMinor(), protocolMajor)
	}
	if !slices.Contains(gw.GetSupportedCapabilities(), contractCapability) {
		return nil, status.Errorf(codes.FailedPrecondition, "gateway does not support %s", contractCapability)
	}
	return &mw.MiddlewareManifest{
		Name:           implementationName,
		ServiceVersion: implementationVer,
		Bindings: []*mw.MiddlewareBinding{{
			Operation:       mw.SupervisorMiddlewareOperation_SUPERVISOR_MIDDLEWARE_OPERATION_HTTP_REQUEST,
			Phase:           mw.SupervisorMiddlewarePhase_SUPERVISOR_MIDDLEWARE_PHASE_PRE_CREDENTIALS,
			MaxPayloadBytes: maxPayloadBytes,
		}},
		Extension: peerMetadata(),
	}, nil
}

// ValidateConfig accepts any config: the policies live in Kyverno, not in the
// OpenShell sandbox policy.
func (g *guard) ValidateConfig(context.Context, *mw.ValidateConfigRequest) (*mw.ValidateConfigResponse, error) {
	return &mw.ValidateConfigResponse{Valid: true}, nil
}

// rawRequest rebuilds the agent's request as HTTP/1.1 bytes for kyverno-authz
// --nested-request, which evaluates policies against the request in the body.
func rawRequest(req *mw.HttpRequestEvaluation) []byte {
	t := req.GetTarget()
	target := t.GetPath()
	if target == "" {
		target = "/"
	}
	if q := t.GetQuery(); q != "" {
		target += "?" + q
	}
	var b bytes.Buffer
	fmt.Fprintf(&b, "%s %s HTTP/1.1\r\nHost: %s\r\n", t.GetMethod(), target, t.GetHost())
	for _, h := range req.GetHeaders() {
		if slices.Contains(skipHeaders, strings.ToLower(h.GetName())) {
			continue
		}
		fmt.Fprintf(&b, "%s: %s\r\n", h.GetName(), h.GetValue())
	}
	fmt.Fprintf(&b, "Content-Length: %d\r\n\r\n", len(req.GetBody()))
	b.Write(req.GetBody())
	return b.Bytes()
}

func (g *guard) EvaluateHttpRequest(ctx context.Context, req *mw.HttpRequestEvaluation) (*mw.HttpRequestResult, error) {
	t := req.GetTarget()
	who := req.GetContext().GetSandbox()
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, g.authzURL, bytes.NewReader(rawRequest(req)))
	if err != nil {
		return nil, status.Errorf(codes.Internal, "build kyverno request: %v", err)
	}
	resp, err := g.client.Do(httpReq)
	if err != nil {
		// A failure here is a middleware failure; OpenShell fails closed by default.
		log.Printf("ERROR sandbox=%s %s %s%s kyverno unreachable: %v", who, t.GetMethod(), t.GetHost(), t.GetPath(), err)
		return nil, status.Errorf(codes.Unavailable, "kyverno authz unreachable: %v", err)
	}
	defer resp.Body.Close()
	reason, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))

	switch resp.StatusCode {
	case http.StatusOK:
		log.Printf("ALLOW sandbox=%s %s %s%s", who, t.GetMethod(), t.GetHost(), t.GetPath())
		return &mw.HttpRequestResult{Decision: mw.Decision_DECISION_ALLOW}, nil
	case http.StatusForbidden, http.StatusUnauthorized:
		code := strings.TrimSpace(string(reason))
		if !reasonCode.MatchString(code) {
			code = fallbackReason
		}
		log.Printf("DENY  sandbox=%s %s %s%s reason=%s", who, t.GetMethod(), t.GetHost(), t.GetPath(), code)
		return &mw.HttpRequestResult{
			Decision:   mw.Decision_DECISION_DENY,
			ReasonCode: code,
			Reason:     "denied by Kyverno policy",
			Findings: []*mw.Finding{{
				Type:     "kyverno.policy_denied",
				Label:    code,
				Count:    1,
				Severity: "high",
			}},
		}, nil
	default:
		log.Printf("ERROR sandbox=%s %s %s%s kyverno status %d", who, t.GetMethod(), t.GetHost(), t.GetPath(), resp.StatusCode)
		return nil, status.Errorf(codes.Internal, "unexpected kyverno status %d", resp.StatusCode)
	}
}

func main() {
	listen := flag.String("listen", envOr("LISTEN_ADDR", "0.0.0.0:50061"), "gRPC listen address")
	authz := flag.String("kyverno-url", envOr("KYVERNO_AUTHZ_URL", "http://127.0.0.1:9081/"), "kyverno-authz HTTP server (run with --nested-request)")
	flag.Parse()

	lis, err := net.Listen("tcp", *listen)
	if err != nil {
		log.Fatalf("listen %s: %v", *listen, err)
	}
	srv := grpc.NewServer(grpc.MaxRecvMsgSize(grpcMessageLimit), grpc.MaxSendMsgSize(grpcMessageLimit))
	mw.RegisterSupervisorMiddlewareServer(srv, &guard{
		authzURL: *authz,
		client:   &http.Client{Timeout: 1500 * time.Millisecond},
	})
	log.Printf("%s %s serving OpenShell supervisor middleware on %s, deciding with Kyverno at %s",
		implementationName, implementationVer, *listen, *authz)
	if err := srv.Serve(lis); err != nil {
		log.Fatal(err)
	}
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
