// Command webtrc-signaling runs an AURU lightweight node: a libp2p Kademlia
// DHT server + GossipSub plaza relay + WebRTC signalling router, with an HTTP
// side for the bootstrap list, ICE config and the iOS gateway WebSocket.
package main

import (
	"context"
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base64"
	"encoding/json"
	"flag"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/gorilla/websocket"

	"webtrc-signaling/internal/geoip"
	"webtrc-signaling/internal/node"
)

func main() {
	httpAddr := flag.String("http", "127.0.0.1:8003", "HTTP listen address (API + iOS gateway WebSocket); put TLS in front")
	keyPath := flag.String("key", "./state/node.key", "persisted node identity")
	listen := flag.String("listen", "/ip4/0.0.0.0/tcp/4001,/ip4/0.0.0.0/udp/4001/quic-v1,/ip4/127.0.0.1/tcp/4002/ws",
		"comma-separated libp2p listen multiaddrs")
	announce := flag.String("announce", os.Getenv("NODE_ANNOUNCE"), "comma-separated public multiaddrs to advertise (e.g. /dns4/host/tcp/443/wss)")
	bootstrap := flag.String("bootstrap", os.Getenv("NODE_BOOTSTRAP"), "comma-separated multiaddrs of other nodes (/…/p2p/<id>)")
	gatewayURL := flag.String("gateway-url", os.Getenv("NODE_GATEWAY_URL"), "public wss:// URL of this node's /ws gateway, listed in /api/bootstrap")
	webDir := flag.String("web-dir", "", "optional directory with the built Vue app to serve at /")
	database := flag.String("geoip-db", os.Getenv("GEOIP_DB_PATH"), "local GeoLite2 City/Country MMDB path")
	proxyCIDRs := flag.String("trusted-proxies", os.Getenv("TRUSTED_PROXY_CIDRS"), "comma-separated trusted reverse proxy CIDRs (loopback is always trusted)")
	flag.Parse()

	logger := log.New(os.Stderr, "", log.LstdFlags)
	regions, err := geoip.Open(*database)
	if err != nil {
		logger.Fatal(err)
	}
	defer regions.Close()
	proxies, err := geoip.ParseTrustedProxies(strings.Join(append(split(*proxyCIDRs), "127.0.0.1/32", "::1/128"), ","))
	if err != nil {
		logger.Fatal(err)
	}

	n, err := node.New(node.Config{KeyPath: *keyPath, Listen: split(*listen), Announce: split(*announce),
		Bootstrap: split(*bootstrap), Logger: logger})
	if err != nil {
		logger.Fatal(err)
	}
	defer n.Close()

	ice := iceProvider(split(os.Getenv("STUN_URLS")), split(os.Getenv("TURN_URLS")), os.Getenv("TURN_REST_SECRET"))
	region := func(r *http.Request) (string, []float64) {
		value, geo, err := regions.Locate(geoip.ClientIP(r.RemoteAddr, r.Header.Get("X-Forwarded-For"), proxies))
		if err != nil || value == "" {
			return "地区未知", nil
		}
		return value, geo
	}
	server := &http.Server{Addr: *httpAddr, Handler: routes(n, ice, region, *gatewayURL, *webDir),
		ReadHeaderTimeout: 10 * time.Second, IdleTimeout: 120 * time.Second}
	go func() {
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			logger.Fatal(err)
		}
	}()
	logger.Printf("http on %s", *httpAddr)
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	<-stop
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = server.Shutdown(ctx)
}

func routes(n *node.Node, ice func(string) []node.ICEServer, region func(*http.Request) (string, []float64), gatewayURL, webDir string) http.Handler {
	mux := http.NewServeMux()
	upgrader := websocket.Upgrader{ReadBufferSize: 16 << 10, WriteBufferSize: 16 << 10,
		CheckOrigin: func(*http.Request) bool { return true }} // authenticated by Ed25519 challenge, not cookies
	mux.HandleFunc("GET /ws", func(w http.ResponseWriter, r *http.Request) {
		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		name, geo := region(r)
		n.ServeGateway(conn, node.GatewayOptions{Region: name, Geo: geo, GatewayURL: gatewayURL, ICE: ice})
	})
	mux.HandleFunc("GET /api/bootstrap", func(w http.ResponseWriter, r *http.Request) {
		// The initial node list: this node plus the other DHT servers in its routing table.
		nodes := []node.NodeInfo{{PeerID: n.Host.ID().String(), Addrs: n.Addrs(), Gateway: gatewayURL}}
		for _, info := range n.RoutingPeers() {
			entry := node.NodeInfo{PeerID: info.ID.String()}
			for _, addr := range info.Addrs {
				if isPublic(addr.String()) {
					entry.Addrs = append(entry.Addrs, addr.String()+"/p2p/"+info.ID.String())
				}
			}
			if len(entry.Addrs) > 0 {
				nodes = append(nodes, entry)
			}
		}
		writeJSON(w, map[string]any{"nodes": nodes, "dht": node.DHTProtocol, "topic": node.PlazaTopic})
	})
	mux.HandleFunc("GET /api/whoami", func(w http.ResponseWriter, r *http.Request) {
		name, geo := region(r)
		writeJSON(w, map[string]any{"region": name, "geo": geo})
	})
	mux.HandleFunc("GET /api/ice", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, map[string]any{"iceServers": ice("web")})
	})
	mux.HandleFunc("GET /api/plaza", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, map[string]any{"entries": n.Plaza.Entries()})
	})
	// Browsers also post their signed announcement here. GossipSub from a browser is best effort
	// (some browsers never get a working pubsub stream to the node and publish to no one), and it
	// gives no feedback; this path stores + gossips the envelope and returns the exact rejection.
	mux.HandleFunc("POST /api/announce", func(w http.ResponseWriter, r *http.Request) {
		var env node.Envelope
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 128<<10)).Decode(&env); err != nil {
			writeJSONStatus(w, http.StatusBadRequest, map[string]any{"error": "invalid envelope"})
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
		defer cancel()
		if _, err := n.PublishEnvelope(ctx, env); err != nil && !node.IsStale(err) {
			writeJSONStatus(w, http.StatusBadRequest, map[string]any{"error": err.Error(), "time": time.Now().UnixMilli()})
			return
		}
		writeJSON(w, map[string]any{"ok": true, "time": time.Now().UnixMilli()})
	})
	if webDir != "" {
		files := http.FileServer(http.Dir(webDir))
		mux.HandleFunc("GET /", func(w http.ResponseWriter, r *http.Request) {
			if _, err := os.Stat(filepath.Join(webDir, filepath.Clean("/"+r.URL.Path))); err != nil {
				r.URL.Path = "/" // SPA fallback
			}
			files.ServeHTTP(w, r)
		})
	}
	return mux
}

func writeJSON(w http.ResponseWriter, value any) { writeJSONStatus(w, http.StatusOK, value) }

func writeJSONStatus(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

// iceProvider issues coturn REST credentials (use-auth-secret) valid for one hour.
func iceProvider(stun, turn []string, secret string) func(string) []node.ICEServer {
	if len(stun) == 0 {
		stun = []string{"stun:stun.l.google.com:19302", "stun:stun.cloudflare.com:3478"}
	}
	return func(id string) []node.ICEServer {
		result := []node.ICEServer{{URLs: stun}}
		if len(turn) > 0 && secret != "" {
			username := strconv.FormatInt(time.Now().Add(time.Hour).Unix(), 10) + ":" + id
			mac := hmac.New(sha1.New, []byte(secret))
			_, _ = mac.Write([]byte(username))
			result = append(result, node.ICEServer{URLs: turn, Username: username, Credential: base64.StdEncoding.EncodeToString(mac.Sum(nil))})
		}
		return result
	}
}

func isPublic(addr string) bool {
	parts := strings.Split(addr, "/")
	if len(parts) < 3 {
		return false
	}
	switch parts[1] {
	case "dns", "dns4", "dns6":
		return parts[2] != "localhost"
	case "ip4", "ip6":
		ip := net.ParseIP(parts[2])
		return ip != nil && !ip.IsLoopback() && !ip.IsPrivate() && !ip.IsLinkLocalUnicast() && !ip.IsUnspecified()
	}
	return false
}

func split(value string) []string {
	var result []string
	for _, item := range strings.Split(value, ",") {
		if item = strings.TrimSpace(item); item != "" {
			result = append(result, item)
		}
	}
	return result
}
