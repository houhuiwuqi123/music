package hub

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gogf/gf/v2/net/ghttp"
	"github.com/gorilla/websocket"
	"webtrc-signaling/internal/model"
)

func TestSlowSocketBoundedWriterDoesNotBlockHub(t *testing.T) {
	sockets := make(chan *websocket.Conn, 1)
	done := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := (&websocket.Upgrader{}).Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer conn.Close()
		sockets <- conn
		<-done
	}))
	defer server.Close()
	defer close(done)
	remote, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(server.URL, "http"), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer remote.Close()
	c := &Client{ID: "slow", Conn: &ghttp.WebSocket{Conn: <-sockets}}
	defer c.Close()
	h := New()
	h.Register(c)
	large := &model.WSMessage{Type: "plaza", Files: []*model.FileMeta{{Name: strings.Repeat("x", 512<<10)}}}
	start := time.Now()
	overflow := false
	for i := 0; i < 1000; i++ {
		if err := c.Send(large); err != nil {
			overflow = true
			break
		}
	}
	if !overflow || time.Since(start) > time.Second {
		t.Fatal("slow socket was not bounded/nonblocking")
	}
	healthy := &Client{ID: "healthy"}
	h.Register(healthy)
	if err := h.UpdateListening(healthy, &model.Listening{OwnerName: "Visitor", Title: "Song"}, time.Now()); err != nil {
		t.Fatal(err)
	}
	if time.Since(start) > time.Second {
		t.Fatal("broadcast blocked listening mutation")
	}
	c.mu.Lock()
	size, stopped := len(c.queue), c.stopped
	c.mu.Unlock()
	if size > 128 || !stopped {
		t.Fatal("overflow did not close slow socket")
	}
}
