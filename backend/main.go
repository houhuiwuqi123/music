package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/gogf/gf/v2/frame/g"
	"github.com/gogf/gf/v2/net/ghttp"

	"webtrc-signaling/internal/geoip"
	"webtrc-signaling/internal/hub"
	"webtrc-signaling/internal/model"
)

func main() {
	port := flag.Int("port", 8080, "HTTP signaling port")
	database := flag.String("geoip-db", os.Getenv("GEOIP_DB_PATH"), "local GeoLite2 City/Country MMDB path")
	proxyCIDRs := flag.String("trusted-proxies", os.Getenv("TRUSTED_PROXY_CIDRS"), "comma-separated trusted reverse proxy CIDRs")
	gatewayPort := flag.Int("gateway-port", 0, "independent localhost gateway port (0 disables reliable grants)")
	gatewayURL := flag.String("gateway-public-url", os.Getenv("GATEWAY_PUBLIC_URL"), "external HTTPS gateway base URL")
	cacheDir := flag.String("gateway-cache-dir", "./state/relay-cache", "exclusive temporary relay cache directory")
	identityPath := flag.String("identity-store", "./state/identities.json", "persisted TOFU identity digests")
	maxFile := flag.Int64("gateway-max-file-bytes", 512<<20, "maximum manifest file size")
	maxCache := flag.Int64("gateway-max-cache-bytes", 4<<30, "maximum reserved cache bytes")
	maxOwner := flag.Int64("gateway-max-owner-bytes", 1<<30, "maximum reserved bytes per owner")
	gatewayRate := flag.Int64("gateway-bytes-per-second", 64<<20, "aggregate upload/download byte rate")
	flag.Parse()
	identities, err := hub.OpenIdentityStore(*identityPath)
	if err != nil {
		g.Log().Fatal(context.Background(), "identity store unavailable")
		return
	}
	regions, err := geoip.Open(*database)
	if err != nil {
		g.Log().Fatal(context.Background(), err)
		return
	}
	defer regions.Close()
	proxies, err := geoip.ParseTrustedProxies(*proxyCIDRs)
	if err != nil {
		g.Log().Fatal(context.Background(), err)
		return
	}
	if *database == "" {
		g.Log().Warning(context.Background(), "GeoIP database not configured; regions will be unknown")
	}
	h := hub.New()
	if *gatewayPort != 0 {
		cfg := hub.DefaultTransferConfig(*cacheDir, *gatewayURL)
		cfg.MaxFileSize = *maxFile
		cfg.MaxCacheBytes = *maxCache
		cfg.MaxOwnerBytes = *maxOwner
		cfg.BytesPerSecond = *gatewayRate
		if err := h.EnableTransfers(cfg); err != nil {
			g.Log().Fatal(context.Background(), err)
			return
		}
		listener, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", *gatewayPort))
		if err != nil {
			g.Log().Fatal(context.Background(), err)
			return
		}
		gateway := &http.Server{Handler: h.Gateway(), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 30 * time.Second,
			WriteTimeout: 2 * time.Minute, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 16 << 10}
		go func() {
			if err := gateway.Serve(listener); err != nil && err != http.ErrServerClosed {
				g.Log().Fatal(context.Background(), err)
			}
		}()
	}
	var turnURLs []string
	for _, value := range strings.Split(os.Getenv("TURN_URLS"), ",") {
		if value = strings.TrimSpace(value); value != "" {
			turnURLs = append(turnURLs, value)
		}
	}
	turnSecret := os.Getenv("TURN_REST_SECRET")
	s := g.Server()
	go func() {
		ticker := time.NewTicker(time.Second)
		defer ticker.Stop()
		for now := range ticker.C {
			h.ExpireListening(now)
			h.SweepTransfers(now)
		}
	}()

	s.BindHandler("/ws", func(r *ghttp.Request) {
		clientID := r.Get("id").String()
		verified, err := identities.Authenticate(clientID, r.Get("secret").String())
		if err != nil {
			r.Response.WriteStatus(403, "identity rejected")
			return
		}

		conn, err := r.WebSocket()
		if err != nil {
			g.Log().Warning(r.Context(), "websocket upgrade failed:", err)
			return
		}
		defer conn.Close()
		conn.SetReadLimit(128 << 10)

		region, err := regions.Region(geoip.ClientIP(r.RemoteAddr, r.Header.Get("X-Forwarded-For"), proxies))
		if err != nil {
			g.Log().Error(r.Context(), err)
			region = "地区未知"
		}
		client := &hub.Client{ID: clientID, Conn: conn, Region: region, Verified: verified}
		snapshot := h.Register(client)
		clientTURNSecret := turnSecret
		if !verified {
			clientTURNSecret = ""
		}
		_ = client.Send(&model.WSMessage{Type: "config", ICEServers: hub.ICEConfig(clientID, time.Now(), turnURLs, clientTURNSecret),
			GatewayEnabled: *gatewayPort != 0, ProtocolVersion: 2})
		_ = client.Send(&model.WSMessage{Type: "plaza", Files: snapshot})
		if err := h.SendListeningSnapshot(client); err != nil {
			g.Log().Warning(r.Context(), "listening snapshot failed:", err)
		}

		defer func() {
			h.DisconnectListening(client, time.Now())
		}()

		for {
			_, msgBytes, err := conn.ReadMessage()
			if err != nil {
				return
			}

			var msg model.WSMessage
			if err := json.Unmarshal(msgBytes, &msg); err != nil {
				continue
			}
			if !h.Active(client) {
				return
			}
			if !client.AllowMessage(time.Now()) {
				_ = client.Send(&model.WSMessage{Type: "transfer-error", RequestID: msg.RequestID, TransferID: msg.TransferID, Error: "rate-limited"})
				continue
			}

			switch msg.Type {
			case "listening":
				if err := h.UpdateListening(client, msg.Listening, time.Now()); err != nil {
					g.Log().Warning(r.Context(), "invalid listening update:", err)
					if sendErr := client.Send(&model.WSMessage{Type: "error", Error: err.Error()}); sendErr != nil {
						g.Log().Warning(r.Context(), "listening error response failed:", sendErr)
					}
				}
			case "publish":
				if err := h.PublishClient(client, msg.File); err != nil {
					_ = client.Send(&model.WSMessage{Type: "error", Error: err.Error()})
					continue
				}
				h.Broadcast(h.Snapshot())

			case "unpublish":
				if msg.FileID == "" {
					continue
				}
				if err := h.UnpublishClient(client, msg.FileID); err != nil {
					_ = client.Send(&model.WSMessage{Type: "error", Error: err.Error()})
					continue
				}
				h.Broadcast(h.Snapshot())

			case "signal":
				if msg.To == "" {
					continue
				}
				if !h.RelaySignal(client, &msg) {
					_ = client.Send(&model.WSMessage{Type: "transfer-error", TransferID: msg.TransferID, Error: "invalid-signal"})
				}
			case "transfer-request":
				transfer, err := h.RequestTransfer(client, &msg, time.Now())
				if err != nil {
					_ = client.Send(&model.WSMessage{Type: "transfer-error", RequestID: msg.RequestID, TransferID: msg.TransferID, Error: err.Error()})
					continue
				}
				_ = client.Send(&model.WSMessage{Type: "transfer", RequestID: msg.RequestID, Transfer: transfer})
			case "transfer-cancel", "transfer-complete":
				if err := h.ReleaseTransfer(client, msg.TransferID); err != nil {
					_ = client.Send(&model.WSMessage{Type: "transfer-error", TransferID: msg.TransferID, Error: err.Error()})
				}
			case "config":
				_ = client.Send(&model.WSMessage{Type: "config", ICEServers: hub.ICEConfig(clientID, time.Now(), turnURLs, clientTURNSecret), GatewayEnabled: *gatewayPort != 0, ProtocolVersion: 2})
			}
		}
	})

	s.SetPort(*port)
	s.Run()
}
