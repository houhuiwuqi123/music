package main

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"github.com/libp2p/go-libp2p"
	dht "github.com/libp2p/go-libp2p-kad-dht"
	"github.com/libp2p/go-libp2p/core/crypto"
	"github.com/libp2p/go-libp2p/core/peer"
	"github.com/libp2p/go-libp2p/p2p/protocol/circuitv2/client"
	ma "github.com/multiformats/go-multiaddr"

	"webtrc-signaling/internal/node"
)

func startNode(t *testing.T, bootstrap ...string) (*node.Node, *httptest.Server) {
	t.Helper()
	n, err := node.New(node.Config{Listen: []string{"/ip4/127.0.0.1/tcp/0"}, Bootstrap: bootstrap})
	if err != nil {
		t.Fatal(err)
	}
	ice := iceProvider(nil, []string{"turn:turn.example:3478"}, "secret")
	srv := httptest.NewServer(routes(n, ice, func(*http.Request) (string, []float64) { return "测试", []float64{31.2, 121.5} }, "", ""))
	t.Cleanup(func() { srv.Close(); _ = n.Close() })
	return n, srv
}

// terminal emulates the iOS client of the gateway protocol.
type terminal struct {
	t    *testing.T
	conn *websocket.Conn
	key  ed25519.PrivateKey
	id   string
	via  []string
	msgs chan node.GatewayMessage
}

func dial(t *testing.T, srv *httptest.Server) *terminal {
	t.Helper()
	conn, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(srv.URL, "http")+"/ws", nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	_, key, _ := ed25519.GenerateKey(rand.Reader)
	var challenge node.GatewayMessage
	if err := conn.ReadJSON(&challenge); err != nil || challenge.Type != "challenge" {
		t.Fatalf("challenge: %v %+v", err, challenge)
	}
	sig := ed25519.Sign(key, []byte(node.AuthPrefix+challenge.Nonce+":"+challenge.Node.PeerID))
	pub := key.Public().(ed25519.PublicKey)
	if err := conn.WriteJSON(node.GatewayMessage{Type: "hello", PublicKey: base64.StdEncoding.EncodeToString(pub),
		Signature: base64.StdEncoding.EncodeToString(sig)}); err != nil {
		t.Fatal(err)
	}
	term := &terminal{t: t, conn: conn, key: key, msgs: make(chan node.GatewayMessage, 64)}
	go func() {
		for {
			var msg node.GatewayMessage
			if err := conn.ReadJSON(&msg); err != nil {
				close(term.msgs)
				return
			}
			term.msgs <- msg
		}
	}()
	welcome := term.expect("welcome", nil)
	term.id, term.via = welcome.PeerID, welcome.Node.Addrs
	if welcome.Region != "测试" || len(welcome.Geo) != 2 || len(welcome.ICEServers) != 2 {
		t.Fatalf("welcome: %+v", welcome)
	}
	return term
}

func (term *terminal) expect(kind string, match func(node.GatewayMessage) bool) node.GatewayMessage {
	term.t.Helper()
	deadline := time.After(20 * time.Second)
	for {
		select {
		case msg, ok := <-term.msgs:
			if !ok {
				term.t.Fatalf("socket closed waiting for %s", kind)
			}
			if msg.Type == kind && (match == nil || match(msg)) {
				return msg
			}
			if msg.Type == "error" {
				term.t.Fatalf("server error waiting for %s: %s", kind, msg.Error)
			}
		case <-deadline:
			term.t.Fatalf("timeout waiting for %s", kind)
		}
	}
}

func envelope(key ed25519.PrivateKey, body node.PlazaBody) node.Envelope {
	pub, _ := crypto.UnmarshalEd25519PublicKey(key.Public().(ed25519.PublicKey))
	raw, _ := crypto.MarshalPublicKey(pub)
	text, _ := json.Marshal(body)
	return node.Envelope{Body: string(text), Pub: base64.StdEncoding.EncodeToString(raw),
		Sig: base64.StdEncoding.EncodeToString(ed25519.Sign(key, append([]byte(node.SignaturePrefix), text...)))}
}

func sampleFile(content string) node.PlazaFile {
	sum := sha256.Sum256([]byte(content))
	hash := hex.EncodeToString(sum[:])
	c, _ := node.ContentCID(hash)
	return node.PlazaFile{CID: c.String(), Name: "song.mp3", Size: int64(len(content)), SHA256: hash, Kind: "listening"}
}

func TestVerifyEnvelope(t *testing.T) {
	_, key, _ := ed25519.GenerateKey(rand.Reader)
	pub, _ := crypto.UnmarshalEd25519PublicKey(key.Public().(ed25519.PublicKey))
	id, _ := peer.IDFromPublicKey(pub)
	nodeID := "/ip4/1.2.3.4/tcp/4001/p2p/12D3KooWGzBkKRZ8jG3H5Hn8xP8t4SPGqv8Vwg8b6jtZLH9nTb7K"
	body := node.PlazaBody{V: 1, PeerID: id.String(), Name: "游客", Via: []string{nodeID},
		Files: []node.PlazaFile{sampleFile("x")}, Seq: time.Now().UnixMilli()}
	if _, err := node.VerifyEnvelope(envelope(key, body), time.Now()); err != nil {
		t.Fatal(err)
	}
	tampered := envelope(key, body)
	tampered.Body = strings.Replace(tampered.Body, "游客", "攻击", 1)
	if _, err := node.VerifyEnvelope(tampered, time.Now()); err == nil {
		t.Fatal("tampered body accepted")
	}
	_, other, _ := ed25519.GenerateKey(rand.Reader)
	if _, err := node.VerifyEnvelope(envelope(other, body), time.Now()); err == nil {
		t.Fatal("foreign key accepted for peerId")
	}
	bad := body
	bad.Files = []node.PlazaFile{sampleFile("x")}
	bad.Files[0].CID = sampleFile("y").CID
	if _, err := node.VerifyEnvelope(envelope(key, bad), time.Now()); err == nil {
		t.Fatal("cid not matching sha256 accepted")
	}
	located := body
	located.Geo = []float64{31.2, 121.5}
	if _, err := node.VerifyEnvelope(envelope(key, located), time.Now()); err != nil {
		t.Fatalf("geo rejected: %v", err)
	}
	for _, geo := range [][]float64{{91, 0}, {0, 181}, {1}} {
		located.Geo = geo
		if _, err := node.VerifyEnvelope(envelope(key, located), time.Now()); err == nil {
			t.Fatalf("invalid geo %v accepted", geo)
		}
	}
	c, _ := node.ContentCID(sampleFile("hello").SHA256)
	// Fixed vector shared with the Swift and JS implementations.
	if c.String() != "bafkreibm6jg3ux5qumhcn2b3flc3tyu6dmlb4xa7u5bf44yegnrjhc4yeq" {
		t.Fatalf("unexpected cid %s", c)
	}
}

func TestTwoNodesAnnounceFindSignal(t *testing.T) {
	n1, srv1 := startNode(t)
	n2, srv2 := startNode(t, n1.Addrs()[0])
	waitFor(t, func() bool { return len(n2.RoutingPeers()) > 0 && len(n1.RoutingPeers()) > 0 }, "routing tables")
	waitFor(t, func() bool { return len(n1.Host.Network().Peers()) > 0 }, "gossip mesh")
	time.Sleep(2 * time.Second) // let GossipSub graft the topic mesh

	a := dial(t, srv1)
	b := dial(t, srv2)
	file := sampleFile("a song")
	body := node.PlazaBody{V: 1, PeerID: a.id, Name: "Alice", Client: "ios", Via: a.via,
		Listening: &node.PlazaListening{Title: "Song", Artist: "Artist", IsPlaying: true},
		Files:     []node.PlazaFile{file}, Seq: time.Now().UnixMilli()}
	if err := a.conn.WriteJSON(node.GatewayMessage{Type: "announce", ID: "1", Envelope: ptr(envelope(a.key, body))}); err != nil {
		t.Fatal(err)
	}
	a.expect("announced", nil)
	update := b.expect("plaza-update", func(m node.GatewayMessage) bool { return m.Entry.PeerID == a.id })
	if update.Entry.Listening.Title != "Song" || update.Entry.Offline {
		t.Fatalf("gossiped entry: %+v", update.Entry)
	}
	// Replaying the same envelope must be rejected as stale.
	_ = a.conn.WriteJSON(node.GatewayMessage{Type: "announce", ID: "2", Envelope: ptr(envelope(a.key, body))})
	if msg := a.expect("error", nil); !strings.Contains(msg.Error, "stale") {
		t.Fatalf("replay: %+v", msg)
	}

	// GET_PROVIDERS via the DHT from the other node: n1 provided on Alice's behalf.
	var providers node.GatewayMessage
	waitFor(t, func() bool {
		_ = b.conn.WriteJSON(node.GatewayMessage{Type: "find", ID: "f", CID: file.CID})
		providers = b.expect("providers", nil)
		return len(providers.Providers) > 0
	}, "providers")
	got := providers.Providers[0]
	if got.PeerID != a.id || got.Node != n1.Host.ID().String() {
		t.Fatalf("candidate: %+v", got)
	}

	// Offer from Bob (on n2) is forwarded to n1 and delivered to Alice with an authenticated From.
	_ = b.conn.WriteJSON(node.GatewayMessage{Type: "signal", Signal: &node.Signal{From: "forged", To: a.id, Node: got.Node,
		NodeAddrs: got.NodeAddrs, Session: "s1", Kind: "offer", SDP: "v=0"}})
	offer := a.expect("signal", nil)
	if offer.Signal.From != b.id || offer.Signal.SDP != "v=0" || offer.Signal.FromNode != n2.Host.ID().String() {
		t.Fatalf("offer: %+v", offer.Signal)
	}
	_ = a.conn.WriteJSON(node.GatewayMessage{Type: "signal", Signal: &node.Signal{To: b.id, Node: n2.Host.ID().String(),
		NodeAddrs: n2.Addrs(), Session: "s1", Kind: "answer", SDP: "v=0 answer"}})
	if answer := b.expect("signal", nil); answer.Signal.From != a.id || answer.Signal.Kind != "answer" {
		t.Fatalf("answer: %+v", answer.Signal)
	}

	// Alice drops: Bob's own node learns via gossip TTL, Alice's node immediately.
	a.conn.Close()
	waitFor(t, func() bool {
		for _, e := range n1.Plaza.Entries() {
			if e.PeerID == a.id {
				return e.Offline
			}
		}
		return false
	}, "offline mark")
	_ = b.conn.WriteJSON(node.GatewayMessage{Type: "signal", Signal: &node.Signal{To: a.id, Node: got.Node, Session: "s2", Kind: "offer"}})
	if msg := b.expect("signal-error", nil); msg.Error == "" {
		t.Fatal("expected unreachable")
	}
}

// TestBrowserStyleProvider: a DHT client reachable only through a circuit
// reservation provides a CID itself; finders get its relay node as signalling hop.
func TestBrowserStyleProvider(t *testing.T) {
	n1, srv1 := startNode(t)
	key, _, _ := crypto.GenerateEd25519Key(rand.Reader)
	browserID, _ := peer.IDFromPrivateKey(key)
	circuit := ma.StringCast(n1.Addrs()[0] + "/p2p-circuit")
	h, err := libp2p.New(libp2p.Identity(key), libp2p.NoListenAddrs, libp2p.EnableRelay(),
		libp2p.AddrsFactory(func([]ma.Multiaddr) []ma.Multiaddr { return []ma.Multiaddr{circuit} }))
	if err != nil {
		t.Fatal(err)
	}
	defer h.Close()
	info := peer.AddrInfo{ID: n1.Host.ID(), Addrs: n1.Host.Addrs()}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	if err := h.Connect(ctx, info); err != nil {
		t.Fatal(err)
	}
	if _, err := client.Reserve(ctx, h, info); err != nil {
		t.Fatal(err)
	}
	d, err := dht.New(h, dht.Mode(dht.ModeClient), dht.ProtocolPrefix(node.DHTPrefix), dht.BootstrapPeers(info))
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	waitFor(t, func() bool { return d.RoutingTable().Size() > 0 }, "client routing table")
	file := sampleFile("browser upload")
	c, _ := node.ParseContentCID(file.CID)
	if err := d.Provide(ctx, c, true); err != nil {
		t.Fatal(err)
	}
	finder := dial(t, srv1)
	_ = finder.conn.WriteJSON(node.GatewayMessage{Type: "find", ID: "f", CID: file.CID})
	providers := finder.expect("providers", nil)
	if len(providers.Providers) != 1 || providers.Providers[0].PeerID != browserID.String() ||
		providers.Providers[0].Node != n1.Host.ID().String() {
		t.Fatalf("providers: %+v", providers.Providers)
	}
}

func TestBootstrapList(t *testing.T) {
	n1, srv := startNode(t)
	resp, err := http.Get(srv.URL + "/api/bootstrap")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var list struct {
		Nodes []node.NodeInfo `json:"nodes"`
		DHT   string          `json:"dht"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&list); err != nil {
		t.Fatal(err)
	}
	if len(list.Nodes) == 0 || list.Nodes[0].PeerID != n1.Host.ID().String() || list.DHT != "/auru/kad/1.0.0" {
		t.Fatalf("bootstrap: %+v", list)
	}
}

func waitFor(t *testing.T, check func() bool, what string) {
	t.Helper()
	deadline := time.Now().Add(30 * time.Second)
	for !check() {
		if time.Now().After(deadline) {
			t.Fatalf("timeout: %s", what)
		}
		time.Sleep(200 * time.Millisecond)
	}
}

func ptr[T any](v T) *T { return &v }
