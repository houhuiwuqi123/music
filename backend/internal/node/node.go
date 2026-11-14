package node

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/libp2p/go-libp2p"
	dht "github.com/libp2p/go-libp2p-kad-dht"
	pubsub "github.com/libp2p/go-libp2p-pubsub"
	"github.com/libp2p/go-libp2p/core/crypto"
	"github.com/libp2p/go-libp2p/core/host"
	"github.com/libp2p/go-libp2p/core/network"
	"github.com/libp2p/go-libp2p/core/peer"
	"github.com/libp2p/go-libp2p/p2p/protocol/circuitv2/relay"
	ma "github.com/multiformats/go-multiaddr"
)

type Config struct {
	KeyPath   string   // persisted node identity (created on first start)
	Listen    []string // libp2p listen multiaddrs
	Announce  []string // public multiaddrs advertised instead of the listen addresses
	Bootstrap []string // other nodes: multiaddrs ending in /p2p/<id>
	Logger    *log.Logger
}

type Node struct {
	Host  host.Host
	DHT   *dht.IpfsDHT
	Plaza *Plaza

	cfg      Config
	ps       *pubsub.PubSub
	topic    *pubsub.Topic
	sessions sync.Map // peer ID string -> *Session (gateway terminals)
	provided sync.Map // cid string -> time of the last delegated provide
	log      *log.Logger
	ctx      context.Context
	cancel   context.CancelFunc
}

func New(cfg Config) (*Node, error) {
	if cfg.Logger == nil {
		cfg.Logger = log.New(os.Stderr, "node ", log.LstdFlags)
	}
	key, err := loadKey(cfg.KeyPath)
	if err != nil {
		return nil, err
	}
	options := []libp2p.Option{
		libp2p.Identity(key),
		libp2p.ListenAddrStrings(cfg.Listen...),
		// Browsers cannot be dialed; they reserve a circuit slot here so their
		// DHT provider records carry an address that points at this node.
		libp2p.EnableRelayService(relay.WithResources(relay.DefaultResources())),
		libp2p.ForceReachabilityPublic(),
	}
	if len(cfg.Announce) > 0 {
		announce := make([]ma.Multiaddr, 0, len(cfg.Announce))
		for _, value := range cfg.Announce {
			addr, err := ma.NewMultiaddr(value)
			if err != nil {
				return nil, fmt.Errorf("announce %q: %w", value, err)
			}
			announce = append(announce, addr)
		}
		options = append(options, libp2p.AddrsFactory(func([]ma.Multiaddr) []ma.Multiaddr { return announce }))
	}
	h, err := libp2p.New(options...)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithCancel(context.Background())
	n := &Node{Host: h, Plaza: NewPlaza(), cfg: cfg, log: cfg.Logger, ctx: ctx, cancel: cancel}
	fail := func(err error) (*Node, error) {
		cancel()
		_ = h.Close()
		return nil, err
	}
	bootstrap, err := parsePeers(cfg.Bootstrap)
	if err != nil {
		return fail(err)
	}
	n.DHT, err = dht.New(h, dht.Mode(dht.ModeServer), dht.ProtocolPrefix(DHTPrefix), dht.BootstrapPeers(bootstrap...))
	if err != nil {
		return fail(err)
	}
	n.ps, err = pubsub.NewGossipSub(ctx, h, pubsub.WithMaxMessageSize(128<<10))
	if err != nil {
		return fail(err)
	}
	if err := n.ps.RegisterTopicValidator(PlazaTopic, n.validateGossip); err != nil {
		return fail(err)
	}
	if n.topic, err = n.ps.Join(PlazaTopic); err != nil {
		return fail(err)
	}
	sub, err := n.topic.Subscribe()
	if err != nil {
		return fail(err)
	}
	// A browser that went away (tab frozen, network switch) stays "online" until its last
	// announcement ages out; grey it out as soon as its only connection here is gone.
	h.Network().Notify(&network.NotifyBundle{DisconnectedF: func(_ network.Network, c network.Conn) {
		go n.peerGone(c.RemotePeer())
	}})
	h.SetStreamHandler(SignalProto, n.handleSignalStream)
	h.SetStreamHandler(ResolveProto, n.handleResolveStream)
	h.SetStreamHandler(SnapshotProto, n.handleSnapshotStream)
	go n.readGossip(sub)
	go n.maintain(bootstrap)
	n.log.Printf("peer %s listening on %v", h.ID(), n.Addrs())
	return n, nil
}

func (n *Node) Close() error {
	n.cancel()
	_ = n.DHT.Close()
	return n.Host.Close()
}

// Addrs returns this node's advertised addresses with the /p2p suffix.
func (n *Node) Addrs() []string {
	var result []string
	for _, addr := range n.Host.Addrs() {
		result = append(result, addr.String()+"/p2p/"+n.Host.ID().String())
	}
	return result
}

// RoutingPeers is the current Kademlia routing table (other nodes) with known addresses.
func (n *Node) RoutingPeers() []peer.AddrInfo {
	var result []peer.AddrInfo
	for _, id := range n.DHT.RoutingTable().ListPeers() {
		result = append(result, n.Host.Peerstore().PeerInfo(id))
	}
	return result
}

func (n *Node) maintain(bootstrap []peer.AddrInfo) {
	connect := func() {
		for _, info := range bootstrap {
			if info.ID == n.Host.ID() || n.Host.Network().Connectedness(info.ID) == network.Connected {
				continue
			}
			ctx, cancel := context.WithTimeout(n.ctx, 10*time.Second)
			if err := n.Host.Connect(ctx, info); err != nil {
				n.log.Printf("bootstrap %s: %v", info.ID, err)
			}
			cancel()
		}
		if len(bootstrap) > 0 {
			if err := n.DHT.Bootstrap(n.ctx); err != nil {
				n.log.Printf("dht bootstrap: %v", err)
			}
		}
	}
	connect()
	sweep := time.NewTicker(time.Second)
	reconnect := time.NewTicker(30 * time.Second)
	reprovide := time.NewTicker(time.Hour)
	defer sweep.Stop()
	defer reconnect.Stop()
	defer reprovide.Stop()
	for {
		select {
		case <-n.ctx.Done():
			return
		case now := <-sweep.C:
			n.Plaza.Sweep(now)
		case <-reconnect.C:
			connect()
		case <-reprovide.C:
			n.provided.Range(func(key, _ any) bool { n.provided.Delete(key); return true })
			n.sessions.Range(func(_, value any) bool { n.provideFor(value.(*Session).files()); return true })
		}
	}
}

// ---- plaza gossip ----

func (n *Node) validateGossip(_ context.Context, _ peer.ID, msg *pubsub.Message) pubsub.ValidationResult {
	var env Envelope
	if err := json.Unmarshal(msg.Data, &env); err != nil {
		return pubsub.ValidationReject
	}
	body, err := n.Plaza.Check(env, time.Now())
	if errors.Is(err, errStale) {
		return pubsub.ValidationIgnore
	} else if err != nil {
		return pubsub.ValidationReject
	}
	msg.ValidatorData = body
	return pubsub.ValidationAccept
}

func (n *Node) readGossip(sub *pubsub.Subscription) {
	for {
		msg, err := sub.Next(n.ctx)
		if err != nil {
			return
		}
		var env Envelope
		body, ok := msg.ValidatorData.(*PlazaBody)
		if !ok || json.Unmarshal(msg.Data, &env) != nil {
			continue
		}
		if n.detached(body) {
			n.Plaza.ApplyOffline(env, body, time.Now())
		} else {
			n.Plaza.Apply(env, body, time.Now())
		}
	}
}

// ErrNotAttached: the announcement names only this node, but the terminal has no connection
// here, so nobody could reach it to fetch its files. It is stored as offline.
var ErrNotAttached = errors.New("not attached")

// AnnounceHTTP stores and gossips an announcement posted over HTTP (stale ones count as
// accepted) and reports ErrNotAttached when its sender cannot actually be reached.
func (n *Node) AnnounceHTTP(ctx context.Context, env Envelope) error {
	body, err := n.Plaza.Check(env, time.Now())
	if IsStale(err) {
		// Check verified the signature before reporting it stale.
		body = new(PlazaBody)
		if json.Unmarshal([]byte(env.Body), body) != nil || !n.detached(body) {
			return nil
		}
		n.Plaza.MarkOffline(body.PeerID, time.Now())
		return ErrNotAttached
	} else if err != nil {
		return err
	}
	if n.detached(body) {
		// Not gossiped: nobody could fetch from it. Stored so the page's details stay current.
		n.Plaza.ApplyOffline(env, body, time.Now())
		return ErrNotAttached
	}
	_, err = n.PublishEnvelope(ctx, env)
	if IsStale(err) {
		return nil
	}
	return err
}

// detached: an online announcement attached only through this node by a terminal that has
// neither a libp2p connection nor a gateway session here.
func (n *Node) detached(body *PlazaBody) bool {
	if body.Bye {
		return false
	}
	vias := body.ViaNodes()
	for _, via := range vias {
		if via.ID != n.Host.ID() {
			return false
		}
	}
	return len(vias) > 0 && !n.isAttached(body.PeerID)
}

func (n *Node) peerGone(id peer.ID) {
	// Give a reconnecting browser a moment before greying it out.
	select {
	case <-n.ctx.Done():
		return
	case <-time.After(5 * time.Second):
	}
	if body, ok := n.Plaza.Lookup(id.String()); ok && n.detached(&body) {
		n.Plaza.MarkOffline(body.PeerID, time.Now())
	}
}

// PublishEnvelope verifies and gossips an announcement made by a gateway terminal.
func (n *Node) PublishEnvelope(ctx context.Context, env Envelope) (*PlazaBody, error) {
	body, err := n.Plaza.Check(env, time.Now())
	if err != nil {
		return nil, err
	}
	data, err := json.Marshal(env)
	if err != nil {
		return nil, err
	}
	// Publish validates locally (rejecting replays) and works with zero topic peers;
	// apply right away so the cache does not depend on the subscription loop timing.
	if err := n.topic.Publish(ctx, data); err != nil {
		return nil, err
	}
	n.Plaza.Apply(env, body, time.Now())
	return body, nil
}

func (n *Node) handleSnapshotStream(s network.Stream) {
	defer s.Close()
	_ = s.SetDeadline(time.Now().Add(15 * time.Second))
	if err := writeFrame(s, n.Plaza.Snapshot()); err != nil {
		_ = s.Reset()
	}
}

// ---- content discovery ----

// provideFor announces this node as provider for files held by attached
// gateway terminals: Kademlia only accepts self-announced provider records,
// so the node answers ResolveProto with the actual holders.
func (n *Node) provideFor(cids []string) {
	for _, value := range cids {
		if _, loaded := n.provided.LoadOrStore(value, time.Now()); loaded {
			continue
		}
		c, err := ParseContentCID(value)
		if err != nil {
			continue
		}
		go func() {
			ctx, cancel := context.WithTimeout(n.ctx, 2*time.Minute)
			defer cancel()
			// With an empty routing table (single node) the record is still stored locally.
			if err := n.DHT.Provide(ctx, c, true); err != nil && len(n.DHT.RoutingTable().ListPeers()) > 0 {
				n.log.Printf("provide %s: %v", c, err)
				n.provided.Delete(value)
			}
		}()
	}
}

func (n *Node) handleResolveStream(s network.Stream) {
	defer s.Close()
	_ = s.SetDeadline(time.Now().Add(10 * time.Second))
	var req resolveRequest
	if err := readFrame(bufio.NewReader(s), &req); err != nil {
		_ = s.Reset()
		return
	}
	reply := resolveReply{Peers: []string{}}
	if _, err := ParseContentCID(req.CID); err == nil {
		reply.Peers = n.localHolders(req.CID)
	}
	_ = writeFrame(s, reply)
}

// localHolders lists online terminals attached here that announce the CID.
func (n *Node) localHolders(cidValue string) []string {
	var result []string
	for _, id := range n.Plaza.Holders(cidValue, n.Host.ID()) {
		if n.isAttached(id) {
			result = append(result, id)
		}
	}
	return result
}

func (n *Node) isAttached(id string) bool {
	if _, ok := n.sessions.Load(id); ok {
		return true
	}
	pid, err := peer.Decode(id)
	return err == nil && n.Host.Network().Connectedness(pid) == network.Connected
}

// FindCandidates runs GET_PROVIDERS for the CID and expands node providers
// (delegates for gateway terminals) into the terminals that hold the file.
func (n *Node) FindCandidates(ctx context.Context, cidValue string, exclude string) ([]Candidate, error) {
	c, err := ParseContentCID(cidValue)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	seen := map[string]bool{exclude: true}
	var mu sync.Mutex
	var result []Candidate
	add := func(candidate Candidate) {
		mu.Lock()
		defer mu.Unlock()
		if !seen[candidate.PeerID] {
			seen[candidate.PeerID] = true
			result = append(result, candidate)
		}
	}
	var wg sync.WaitGroup
	for info := range n.DHT.FindProvidersAsync(ctx, c, 20) {
		switch {
		case info.ID == n.Host.ID():
			for _, id := range n.localHolders(cidValue) {
				add(Candidate{PeerID: id, Node: n.Host.ID().String(), NodeAddrs: n.Addrs()})
			}
		case isRelayed(info.Addrs):
			// A browser announcing itself: its circuit address names its node.
			if relayInfo := relayOf(info.Addrs); relayInfo != nil {
				add(Candidate{PeerID: info.ID.String(), Node: relayInfo.ID.String(), NodeAddrs: p2pAddrs(*relayInfo)})
			}
		default:
			wg.Add(1)
			go func(info peer.AddrInfo) {
				defer wg.Done()
				peers, err := n.resolveRemote(ctx, info, cidValue)
				if err != nil {
					return
				}
				for _, id := range peers {
					add(Candidate{PeerID: id, Node: info.ID.String(), NodeAddrs: p2pAddrs(n.Host.Peerstore().PeerInfo(info.ID))})
				}
			}(info)
		}
	}
	wg.Wait()
	sort.SliceStable(result, func(i, j int) bool {
		return result[i].Node == n.Host.ID().String() && result[j].Node != n.Host.ID().String()
	})
	return result, nil
}

func (n *Node) resolveRemote(ctx context.Context, info peer.AddrInfo, cidValue string) ([]string, error) {
	if len(info.Addrs) > 0 {
		n.Host.Peerstore().AddAddrs(info.ID, info.Addrs, time.Hour)
	}
	s, err := n.Host.NewStream(ctx, info.ID, ResolveProto)
	if err != nil {
		return nil, err
	}
	defer s.Close()
	_ = s.SetDeadline(time.Now().Add(10 * time.Second))
	if err := writeFrame(s, resolveRequest{CID: cidValue}); err != nil {
		return nil, err
	}
	var reply resolveReply
	if err := readFrame(bufio.NewReader(s), &reply); err != nil {
		return nil, err
	}
	if len(reply.Peers) > 64 {
		reply.Peers = reply.Peers[:64]
	}
	return reply.Peers, nil
}

func isRelayed(addrs []ma.Multiaddr) bool {
	for _, addr := range addrs {
		if _, err := addr.ValueForProtocol(ma.P_CIRCUIT); err == nil {
			return true
		}
	}
	return false
}

// relayOf extracts the relay node from /…/p2p/<relay>/p2p-circuit addresses.
func relayOf(addrs []ma.Multiaddr) *peer.AddrInfo {
	for _, addr := range addrs {
		relayed, _ := ma.SplitFunc(addr, func(c ma.Component) bool { return c.Protocol().Code == ma.P_CIRCUIT })
		if relayed == nil {
			continue
		}
		if info, err := peer.AddrInfoFromP2pAddr(relayed); err == nil {
			return info
		}
	}
	return nil
}

func p2pAddrs(info peer.AddrInfo) []string {
	addrs, err := peer.AddrInfoToP2pAddrs(&info)
	if err != nil {
		return nil
	}
	result := make([]string, 0, len(addrs))
	for _, addr := range addrs {
		result = append(result, addr.String())
	}
	if len(result) > 8 {
		result = result[:8]
	}
	return result
}

// ---- signalling ----

// RouteSignal delivers to a terminal attached here, or forwards one hop to
// the node the target is attached to.
func (n *Node) RouteSignal(ctx context.Context, sig *Signal) error {
	if err := sig.validate(); err != nil {
		return err
	}
	if value, ok := n.sessions.Load(sig.To); ok {
		return value.(*Session).deliverSignal(sig)
	}
	if target, err := peer.Decode(sig.To); err == nil && n.Host.Network().Connectedness(target) == network.Connected {
		if !n.isNodePeer(target) {
			return n.sendSignal(ctx, target, sig)
		}
	}
	if sig.Hop == 0 && sig.Node != "" && sig.Node != n.Host.ID().String() {
		next, err := peer.Decode(sig.Node)
		if err != nil {
			return errors.New("invalid node")
		}
		for _, value := range sig.NodeAddrs {
			if addr, err := ma.NewMultiaddr(value); err == nil {
				if info, err := peer.AddrInfoFromP2pAddr(addr); err == nil && info.ID == next {
					n.Host.Peerstore().AddAddrs(next, info.Addrs, time.Hour)
				}
			}
		}
		forward := *sig
		forward.Hop = 1
		forward.NodeAddrs = nil
		return n.sendSignal(ctx, next, &forward)
	}
	return errors.New("unreachable")
}

func (n *Node) isNodePeer(id peer.ID) bool {
	protocols, err := n.Host.Peerstore().SupportsProtocols(id, DHTProtocol)
	return err == nil && len(protocols) > 0
}

func (n *Node) sendSignal(ctx context.Context, target peer.ID, sig *Signal) error {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	s, err := n.Host.NewStream(network.WithAllowLimitedConn(ctx, "signal"), target, SignalProto)
	if err != nil {
		return fmt.Errorf("unreachable: %w", err)
	}
	defer s.Close()
	_ = s.SetDeadline(time.Now().Add(10 * time.Second))
	if err := writeFrame(s, sig); err != nil {
		return err
	}
	var reply signalReply
	if err := readFrame(bufio.NewReader(s), &reply); err != nil {
		return err
	}
	if reply.Error != "" {
		return errors.New(reply.Error)
	}
	return nil
}

func (n *Node) handleSignalStream(s network.Stream) {
	defer s.Close()
	_ = s.SetDeadline(time.Now().Add(15 * time.Second))
	var sig Signal
	if err := readFrame(bufio.NewReader(s), &sig); err != nil {
		_ = s.Reset()
		return
	}
	remote := s.Conn().RemotePeer()
	// Another node vouches for the sender it authenticated; a terminal can only speak for itself.
	if sig.Hop != 1 || !n.isNodePeer(remote) {
		sig.From = remote.String()
		sig.Hop = 0
	}
	reply := signalReply{OK: true}
	if err := n.RouteSignal(n.ctx, &sig); err != nil {
		reply = signalReply{Error: err.Error()}
	}
	_ = writeFrame(s, reply)
}

// ---- helpers ----

func parsePeers(values []string) ([]peer.AddrInfo, error) {
	var addrs []ma.Multiaddr
	for _, value := range values {
		if value = strings.TrimSpace(value); value == "" {
			continue
		}
		addr, err := ma.NewMultiaddr(value)
		if err != nil {
			return nil, fmt.Errorf("bootstrap %q: %w", value, err)
		}
		addrs = append(addrs, addr)
	}
	return peer.AddrInfosFromP2pAddrs(addrs...)
}

func loadKey(path string) (crypto.PrivKey, error) {
	if path == "" {
		key, _, err := crypto.GenerateEd25519Key(nil)
		return key, err
	}
	if data, err := os.ReadFile(path); err == nil {
		return crypto.UnmarshalPrivateKey(data)
	} else if !os.IsNotExist(err) {
		return nil, err
	}
	key, _, err := crypto.GenerateEd25519Key(nil)
	if err != nil {
		return nil, err
	}
	data, err := crypto.MarshalPrivateKey(key)
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, err
	}
	return key, os.WriteFile(path, data, 0o600)
}
