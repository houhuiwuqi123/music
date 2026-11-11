// Package node implements the AURU lightweight libp2p node: a Kademlia DHT
// server, a GossipSub relay for the plaza feed, a WebRTC signalling router and
// a WebSocket gateway for terminals (iOS) that cannot run libp2p themselves.
package node

import (
	"bufio"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/ipfs/go-cid"
	"github.com/libp2p/go-libp2p/core/protocol"
	mh "github.com/multiformats/go-multihash"
)

const (
	// DHTPrefix makes the DHT protocol "/auru/kad/1.0.0" so AURU forms its own
	// Kademlia network instead of joining (and polluting) the public IPFS DHT.
	DHTPrefix     protocol.ID = "/auru"
	DHTProtocol   protocol.ID = "/auru/kad/1.0.0"
	SignalProto   protocol.ID = "/auru/signal/1.0.0"
	ResolveProto  protocol.ID = "/auru/resolve/1.0.0"
	SnapshotProto protocol.ID = "/auru/plaza/1.0.0"
	PlazaTopic                = "auru/plaza/1"

	// EntryTTL marks a peer offline when no fresh announcement arrived; the
	// entry is dropped OfflineRetention later. Clients announce every 30 s.
	EntryTTL         = 90 * time.Second
	OfflineRetention = 60 * time.Second

	maxFrame = 256 << 10
)

// writeFrame writes one unsigned-varint length-prefixed JSON message
// (the same framing as it-length-prefixed on the JS side).
func writeFrame(w io.Writer, value any) error {
	body, err := json.Marshal(value)
	if err != nil {
		return err
	}
	if len(body) > maxFrame {
		return errors.New("frame too large")
	}
	var prefix [binary.MaxVarintLen64]byte
	n := binary.PutUvarint(prefix[:], uint64(len(body)))
	if _, err := w.Write(append(prefix[:n], body...)); err != nil {
		return err
	}
	return nil
}

func readFrame(r *bufio.Reader, value any) error {
	size, err := binary.ReadUvarint(r)
	if err != nil {
		return err
	}
	if size > maxFrame {
		return fmt.Errorf("frame of %d bytes exceeds limit", size)
	}
	body := make([]byte, size)
	if _, err := io.ReadFull(r, body); err != nil {
		return err
	}
	return json.Unmarshal(body, value)
}

// ContentCID is CIDv1(raw, sha2-256(file)). Every client derives it from the
// whole-file SHA-256, so the CID doubles as the integrity check.
func ContentCID(sha256Hex string) (cid.Cid, error) {
	digest, err := hex.DecodeString(sha256Hex)
	if err != nil || len(digest) != 32 || strings.ToLower(sha256Hex) != sha256Hex {
		return cid.Undef, errors.New("sha256 must be 64 lowercase hex characters")
	}
	hash, err := mh.Encode(digest, mh.SHA2_256)
	if err != nil {
		return cid.Undef, err
	}
	return cid.NewCidV1(cid.Raw, hash), nil
}

// ParseContentCID accepts only CIDv1 raw sha2-256 CIDs.
func ParseContentCID(value string) (cid.Cid, error) {
	parsed, err := cid.Decode(value)
	if err != nil {
		return cid.Undef, err
	}
	decoded, err := mh.Decode(parsed.Hash())
	if err != nil {
		return cid.Undef, err
	}
	if parsed.Version() != 1 || parsed.Type() != cid.Raw || decoded.Code != mh.SHA2_256 || decoded.Length != 32 {
		return cid.Undef, errors.New("expected CIDv1 raw sha2-256")
	}
	return parsed, nil
}

// Signal carries a complete (non-trickle) SDP offer/answer between two
// terminals. Candidates are gathered before sending, so offer + answer is the
// whole exchange and reconnecting simply starts a new session.
type Signal struct {
	From      string   `json:"from"`
	To        string   `json:"to"`
	Node      string   `json:"node,omitempty"`      // peer ID of the node the target is attached to
	NodeAddrs []string `json:"nodeAddrs,omitempty"` // dialable addresses of that node
	// FromNode lets the answerer route its reply to the node the offerer is attached to.
	FromNode      string   `json:"fromNode,omitempty"`
	FromNodeAddrs []string `json:"fromNodeAddrs,omitempty"`
	Session       string   `json:"session"`
	Kind          string   `json:"kind"` // offer | answer | bye
	SDP           string   `json:"sdp,omitempty"`
	Hop           int      `json:"hop,omitempty"`
}

func (s *Signal) validate() error {
	switch {
	case s.To == "" || len(s.To) > 128:
		return errors.New("invalid target")
	case s.Session == "" || len(s.Session) > 64:
		return errors.New("invalid session")
	case s.Kind != "offer" && s.Kind != "answer" && s.Kind != "bye":
		return errors.New("invalid kind")
	case len(s.SDP) > 64<<10:
		return errors.New("sdp too large")
	case len(s.NodeAddrs) > 8 || len(s.FromNodeAddrs) > 8:
		return errors.New("too many node addresses")
	}
	return nil
}

type signalReply struct {
	OK    bool   `json:"ok,omitempty"`
	Error string `json:"error,omitempty"`
}

// Candidate is a terminal that holds a file, plus the node it can be signalled through.
type Candidate struct {
	PeerID    string   `json:"peerId"`
	Node      string   `json:"node"`
	NodeAddrs []string `json:"nodeAddrs,omitempty"`
}

type resolveRequest struct {
	CID string `json:"cid"`
}

type resolveReply struct {
	Peers []string `json:"peers"`
}
