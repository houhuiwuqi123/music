package node

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	"github.com/libp2p/go-libp2p/core/crypto"
	"github.com/libp2p/go-libp2p/core/peer"
)

// AuthPrefix domain-separates gateway login signatures.
const AuthPrefix = "auru-node-auth:"

// GatewayMessage is the JSON envelope of the terminal gateway (iOS) WebSocket.
type GatewayMessage struct {
	Type       string          `json:"type"`
	ID         string          `json:"id,omitempty"`
	Error      string          `json:"error,omitempty"`
	Nonce      string          `json:"nonce,omitempty"`
	PublicKey  string          `json:"publicKey,omitempty"`
	Signature  string          `json:"signature,omitempty"`
	PeerID     string          `json:"peerId,omitempty"`
	Region     string          `json:"region,omitempty"`
	Geo        []float64       `json:"geo,omitempty"`
	Node       *NodeInfo       `json:"node,omitempty"`
	Routing    []NodeInfo      `json:"routing,omitempty"`
	ICEServers []ICEServer     `json:"iceServers,omitempty"`
	Envelope   *Envelope       `json:"envelope,omitempty"`
	CID        string          `json:"cid,omitempty"`
	Providers  []Candidate     `json:"providers,omitempty"`
	Signal     *Signal         `json:"signal,omitempty"`
	Entries    []Entry         `json:"entries,omitempty"`
	Entry      *Entry          `json:"entry,omitempty"`
	Seq        int64           `json:"seq,omitempty"`
	Extra      json.RawMessage `json:"extra,omitempty"`
}

type NodeInfo struct {
	PeerID  string   `json:"peerId"`
	Addrs   []string `json:"addrs"`
	Gateway string   `json:"gateway,omitempty"`
}

type ICEServer struct {
	URLs       []string `json:"urls"`
	Username   string   `json:"username,omitempty"`
	Credential string   `json:"credential,omitempty"`
}

// GatewayOptions are per-connection values supplied by the HTTP layer.
type GatewayOptions struct {
	Region     string
	Geo        []float64
	GatewayURL string
	ICE        func(id string) []ICEServer
}

type Session struct {
	node   *Node
	conn   *websocket.Conn
	peerID string
	out    chan GatewayMessage
	done   chan struct{}
	once   sync.Once

	mu     sync.Mutex
	cids   []string
	tokens float64
	last   time.Time
}

func (s *Session) files() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.cids...)
}

func (s *Session) send(msg GatewayMessage) bool {
	select {
	case <-s.done:
		return false
	case s.out <- msg:
		return true
	default:
		s.close() // a client that cannot keep up reconnects and resyncs
		return false
	}
}

func (s *Session) deliverSignal(sig *Signal) error {
	if !s.send(GatewayMessage{Type: "signal", Signal: sig}) {
		return errors.New("unreachable")
	}
	return nil
}

func (s *Session) close() {
	s.once.Do(func() {
		close(s.done)
		_ = s.conn.Close()
	})
}

func (s *Session) allow(now time.Time) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.last.IsZero() {
		s.tokens = 60
	} else {
		s.tokens = min(60, s.tokens+now.Sub(s.last).Seconds()*20)
	}
	s.last = now
	if s.tokens < 1 {
		return false
	}
	s.tokens--
	return true
}

// ServeGateway runs one authenticated terminal session until the socket closes.
func (n *Node) ServeGateway(conn *websocket.Conn, opts GatewayOptions) {
	defer conn.Close()
	conn.SetReadLimit(160 << 10)
	nonceBytes := make([]byte, 32)
	if _, err := rand.Read(nonceBytes); err != nil {
		return
	}
	nonce := base64.StdEncoding.EncodeToString(nonceBytes)
	self := NodeInfo{PeerID: n.Host.ID().String(), Addrs: n.Addrs(), Gateway: opts.GatewayURL}
	_ = conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
	if err := conn.WriteJSON(GatewayMessage{Type: "challenge", Nonce: nonce, Node: &self}); err != nil {
		return
	}
	_ = conn.SetReadDeadline(time.Now().Add(20 * time.Second))
	var hello GatewayMessage
	if err := conn.ReadJSON(&hello); err != nil || hello.Type != "hello" {
		return
	}
	id, err := verifyHello(hello, nonce, self.PeerID)
	if err != nil {
		_ = conn.WriteJSON(GatewayMessage{Type: "error", Error: err.Error()})
		return
	}
	s := &Session{node: n, conn: conn, peerID: id.String(), out: make(chan GatewayMessage, 512), done: make(chan struct{})}
	if previous, loaded := n.sessions.Swap(s.peerID, s); loaded {
		previous.(*Session).close()
	}
	defer func() {
		if n.sessions.CompareAndDelete(s.peerID, s) {
			n.Plaza.MarkOffline(s.peerID, time.Now())
		}
		s.close()
	}()
	events := n.Plaza.Subscribe()
	defer n.Plaza.Unsubscribe(events)

	go s.writeLoop()
	var routing []NodeInfo
	for _, info := range n.RoutingPeers() {
		routing = append(routing, NodeInfo{PeerID: info.ID.String(), Addrs: p2pAddrs(info)})
	}
	s.send(GatewayMessage{Type: "welcome", PeerID: s.peerID, Region: opts.Region, Geo: opts.Geo, Node: &self, Routing: routing,
		ICEServers: opts.ICE(s.peerID), Entries: n.Plaza.Entries()})
	go func() {
		for {
			select {
			case <-s.done:
				return
			case event := <-events:
				if n.Plaza.TakeOverflow(events) {
					s.send(GatewayMessage{Type: "plaza", Entries: n.Plaza.Entries()})
					continue
				}
				if event.Entry != nil {
					s.send(GatewayMessage{Type: "plaza-update", Entry: event.Entry})
				} else if event.Removed != "" {
					s.send(GatewayMessage{Type: "plaza-remove", PeerID: event.Removed})
				}
			}
		}
	}()

	conn.SetPongHandler(func(string) error { return conn.SetReadDeadline(time.Now().Add(75 * time.Second)) })
	for {
		_ = conn.SetReadDeadline(time.Now().Add(75 * time.Second))
		var msg GatewayMessage
		if err := conn.ReadJSON(&msg); err != nil {
			return
		}
		if !s.allow(time.Now()) {
			s.send(GatewayMessage{Type: "error", ID: msg.ID, Error: "rate-limited"})
			continue
		}
		s.handle(msg, opts)
	}
}

func (s *Session) handle(msg GatewayMessage, opts GatewayOptions) {
	n := s.node
	switch msg.Type {
	case "ping":
		s.send(GatewayMessage{Type: "pong", ID: msg.ID})
	case "ice":
		s.send(GatewayMessage{Type: "ice", ID: msg.ID, ICEServers: opts.ICE(s.peerID)})
	case "announce":
		if msg.Envelope == nil {
			s.send(GatewayMessage{Type: "error", ID: msg.ID, Error: "envelope required"})
			return
		}
		ctx, cancel := context.WithTimeout(n.ctx, 10*time.Second)
		body, err := n.PublishEnvelope(ctx, *msg.Envelope)
		cancel()
		if err == nil && body.PeerID != s.peerID {
			err = errors.New("envelope signed by another peer")
		}
		if err != nil {
			s.send(GatewayMessage{Type: "error", ID: msg.ID, Error: err.Error()})
			return
		}
		cids := make([]string, 0, len(body.Files))
		for _, file := range body.Files {
			cids = append(cids, file.CID)
		}
		if body.Bye {
			cids = nil
		}
		s.mu.Lock()
		s.cids = cids
		s.mu.Unlock()
		n.provideFor(cids)
		s.send(GatewayMessage{Type: "announced", ID: msg.ID, Seq: body.Seq})
	case "find":
		go func() {
			providers, err := n.FindCandidates(n.ctx, msg.CID, s.peerID)
			reply := GatewayMessage{Type: "providers", ID: msg.ID, CID: msg.CID, Providers: providers}
			if err != nil {
				reply.Error = err.Error()
			}
			if reply.Providers == nil {
				reply.Providers = []Candidate{}
			}
			s.send(reply)
		}()
	case "signal":
		if msg.Signal == nil {
			return
		}
		sig := *msg.Signal
		sig.From = s.peerID
		sig.Hop = 0
		sig.FromNode = n.Host.ID().String()
		sig.FromNodeAddrs = n.Addrs()
		if len(sig.FromNodeAddrs) > 8 {
			sig.FromNodeAddrs = sig.FromNodeAddrs[:8]
		}
		go func() {
			if err := n.RouteSignal(n.ctx, &sig); err != nil {
				s.send(GatewayMessage{Type: "signal-error", ID: msg.ID, Signal: &Signal{To: sig.To, Session: sig.Session, Kind: sig.Kind}, Error: err.Error()})
			}
		}()
	default:
		s.send(GatewayMessage{Type: "error", ID: msg.ID, Error: "unknown type"})
	}
}

func (s *Session) writeLoop() {
	ping := time.NewTicker(25 * time.Second)
	defer ping.Stop()
	for {
		select {
		case <-s.done:
			return
		case msg := <-s.out:
			_ = s.conn.SetWriteDeadline(time.Now().Add(15 * time.Second))
			if err := s.conn.WriteJSON(msg); err != nil {
				s.close()
				return
			}
		case <-ping.C:
			_ = s.conn.SetWriteDeadline(time.Now().Add(15 * time.Second))
			if err := s.conn.WriteMessage(websocket.PingMessage, nil); err != nil {
				s.close()
				return
			}
		}
	}
}

func verifyHello(hello GatewayMessage, nonce, nodeID string) (peer.ID, error) {
	raw, err := base64.StdEncoding.DecodeString(hello.PublicKey)
	if err != nil || len(raw) != 32 {
		return "", errors.New("publicKey must be a base64 raw Ed25519 key")
	}
	pub, err := crypto.UnmarshalEd25519PublicKey(raw)
	if err != nil {
		return "", errors.New("invalid public key")
	}
	sig, err := base64.StdEncoding.DecodeString(hello.Signature)
	if err != nil {
		return "", errors.New("invalid signature encoding")
	}
	if ok, err := pub.Verify([]byte(AuthPrefix+nonce+":"+nodeID), sig); err != nil || !ok {
		return "", errors.New("bad signature")
	}
	return peer.IDFromPublicKey(pub)
}
