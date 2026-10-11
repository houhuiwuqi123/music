package main

import (
	"context"
	"encoding/json"
	"flag"
	"os"
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
	flag.Parse()
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
	s := g.Server()
	go func() {
		ticker := time.NewTicker(10 * time.Second)
		defer ticker.Stop()
		for now := range ticker.C {
			h.ExpireListening(now)
		}
	}()

	s.BindHandler("/ws", func(r *ghttp.Request) {
		clientID := r.Get("id").String()
		if clientID == "" {
			r.Response.WriteStatus(400, "missing id")
			return
		}

		conn, err := r.WebSocket()
		if err != nil {
			g.Log().Warning(r.Context(), "websocket upgrade failed:", err)
			return
		}
		defer conn.Close()

		region, err := regions.Region(geoip.ClientIP(r.RemoteAddr, r.Header.Get("X-Forwarded-For"), proxies))
		if err != nil {
			g.Log().Error(r.Context(), err)
			region = "地区未知"
		}
		client := &hub.Client{ID: clientID, Conn: conn, Region: region}
		snapshot := h.Register(client)
		_ = client.Send(&model.WSMessage{Type: "plaza", Files: snapshot})
		if err := h.SendListeningSnapshot(client); err != nil {
			g.Log().Warning(r.Context(), "listening snapshot failed:", err)
		}

		defer func() {
			if err := h.UpdateListening(client, nil, time.Now()); err != nil {
				g.Log().Warning(r.Context(), "listening cleanup failed:", err)
			}
			files := h.Unregister(clientID)
			h.Broadcast(files)
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

			switch msg.Type {
			case "listening":
				if err := h.UpdateListening(client, msg.Listening, time.Now()); err != nil {
					g.Log().Warning(r.Context(), "invalid listening update:", err)
					if sendErr := client.Send(&model.WSMessage{Type: "error", Error: err.Error()}); sendErr != nil {
						g.Log().Warning(r.Context(), "listening error response failed:", sendErr)
					}
				}
			case "publish":
				if msg.File == nil || msg.File.ID == "" {
					continue
				}
				msg.File.OwnerID = clientID
				files := h.Publish(msg.File)
				h.Broadcast(files)

			case "unpublish":
				if msg.FileID == "" {
					continue
				}
				files := h.Unpublish(msg.FileID)
				h.Broadcast(files)

			case "signal":
				if msg.To == "" {
					continue
				}
				h.RelaySignal(clientID, msg.To, msg.Data)
			}
		}
	})

	s.SetPort(*port)
	s.Run()
}
