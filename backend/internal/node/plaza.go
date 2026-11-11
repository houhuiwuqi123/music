package node

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/libp2p/go-libp2p/core/crypto"
	"github.com/libp2p/go-libp2p/core/peer"
	ma "github.com/multiformats/go-multiaddr"
)

// SignaturePrefix domain-separates plaza signatures from any other use of the key.
const SignaturePrefix = "auru-plaza:"

// Envelope is what travels on the GossipSub topic. Body is the exact JSON
// text that was signed, so Go, Swift and JS never need canonical JSON.
type Envelope struct {
	Body string `json:"body"`
	Sig  string `json:"sig"` // base64 Ed25519 signature over SignaturePrefix+Body
	Pub  string `json:"pub"` // base64 libp2p protobuf public key
}

type PlazaListening struct {
	Title     string `json:"title"`
	Artist    string `json:"artist"`
	IsPlaying bool   `json:"isPlaying"`
}

type PlazaFile struct {
	CID    string `json:"cid"`
	Name   string `json:"name"`
	Size   int64  `json:"size"`
	SHA256 string `json:"sha256"`
	Kind   string `json:"kind"` // listening | upload
	Mime   string `json:"mime,omitempty"`
}

type PlazaBody struct {
	V         int             `json:"v"`
	PeerID    string          `json:"peerId"`
	Name      string          `json:"name"`
	Avatar    string          `json:"avatar,omitempty"`
	Region    string          `json:"region,omitempty"`
	Client    string          `json:"client,omitempty"` // ios | web
	Via       []string        `json:"via"`              // node multiaddrs ending in /p2p/<node>
	Listening *PlazaListening `json:"listening,omitempty"`
	Files     []PlazaFile     `json:"files"`
	Seq       int64           `json:"seq"` // unix milliseconds, strictly increasing per peer
	Bye       bool            `json:"bye,omitempty"`
}

// Entry is a verified announcement as served to gateway clients.
type Entry struct {
	PlazaBody
	Offline bool `json:"offline"`
}

var (
	errStale = errors.New("stale announcement")
)

// VerifyEnvelope checks the signature, the key-to-peer binding and the field limits.
func VerifyEnvelope(env Envelope, now time.Time) (*PlazaBody, error) {
	if len(env.Body) > 96<<10 {
		return nil, errors.New("body too large")
	}
	rawPub, err := base64.StdEncoding.DecodeString(env.Pub)
	if err != nil {
		return nil, errors.New("invalid public key encoding")
	}
	pub, err := crypto.UnmarshalPublicKey(rawPub)
	if err != nil {
		return nil, errors.New("invalid public key")
	}
	if pub.Type() != crypto.Ed25519 {
		return nil, errors.New("only Ed25519 keys are accepted")
	}
	sig, err := base64.StdEncoding.DecodeString(env.Sig)
	if err != nil {
		return nil, errors.New("invalid signature encoding")
	}
	ok, err := pub.Verify([]byte(SignaturePrefix+env.Body), sig)
	if err != nil || !ok {
		return nil, errors.New("bad signature")
	}
	var body PlazaBody
	if err := json.Unmarshal([]byte(env.Body), &body); err != nil {
		return nil, errors.New("invalid body")
	}
	id, err := peer.IDFromPublicKey(pub)
	if err != nil || id.String() != body.PeerID {
		return nil, errors.New("peerId does not match key")
	}
	if err := body.validate(now); err != nil {
		return nil, err
	}
	return &body, nil
}

func (b *PlazaBody) validate(now time.Time) error {
	seq := time.UnixMilli(b.Seq)
	switch {
	case b.V != 1:
		return errors.New("unsupported version")
	case seq.Before(now.Add(-5*time.Minute)) || seq.After(now.Add(time.Minute)):
		return errors.New("announcement clock out of range")
	case !utf8.ValidString(b.Name) || utf8.RuneCountInString(b.Name) == 0 || utf8.RuneCountInString(b.Name) > 40:
		return errors.New("name must be 1-40 characters")
	case len(b.Avatar) > 48<<10:
		return errors.New("avatar too large")
	case utf8.RuneCountInString(b.Region) > 64:
		return errors.New("region too long")
	case len(b.Files) > 32:
		return errors.New("too many files")
	case len(b.Via) == 0 && !b.Bye, len(b.Via) > 8:
		return errors.New("via must list 1-8 node addresses")
	}
	if b.Avatar != "" {
		if _, err := base64.StdEncoding.DecodeString(b.Avatar); err != nil {
			return errors.New("avatar must be base64")
		}
	}
	if b.Listening != nil && (utf8.RuneCountInString(b.Listening.Title) > 300 || utf8.RuneCountInString(b.Listening.Artist) > 300) {
		return errors.New("listening text too long")
	}
	for _, addr := range b.Via {
		parsed, err := ma.NewMultiaddr(addr)
		if err != nil {
			return errors.New("invalid via address")
		}
		if _, err := peer.AddrInfoFromP2pAddr(parsed); err != nil {
			return errors.New("via address must end with /p2p/<node>")
		}
	}
	for _, file := range b.Files {
		c, err := ContentCID(file.SHA256)
		if err != nil || c.String() != file.CID {
			return errors.New("file cid must be CIDv1 raw of its sha256")
		}
		if file.Size < 0 || file.Size > 4<<30 || file.Name == "" || utf8.RuneCountInString(file.Name) > 255 ||
			strings.ContainsAny(file.Name, "/\\\x00") || (file.Kind != "listening" && file.Kind != "upload") || len(file.Mime) > 128 {
			return errors.New("invalid file entry")
		}
	}
	return nil
}

// ViaNodes returns the node IDs the announcer is attached to.
func (b *PlazaBody) ViaNodes() []peer.AddrInfo {
	var result []peer.AddrInfo
	for _, addr := range b.Via {
		parsed, err := ma.NewMultiaddr(addr)
		if err != nil {
			continue
		}
		info, err := peer.AddrInfoFromP2pAddr(parsed)
		if err != nil {
			continue
		}
		merged := false
		for i := range result {
			if result[i].ID == info.ID {
				result[i].Addrs = append(result[i].Addrs, info.Addrs...)
				merged = true
			}
		}
		if !merged {
			result = append(result, *info)
		}
	}
	return result
}

type plazaRecord struct {
	env      Envelope
	body     PlazaBody
	lastSeen time.Time
	offline  bool
}

// Plaza is the node's cache of verified announcements. Gateway sessions
// subscribe to receive updates and removals.
type Plaza struct {
	mu       sync.Mutex
	records  map[string]*plazaRecord
	subs     map[chan PlazaEvent]struct{}
	overflow map[chan PlazaEvent]bool
}

type PlazaEvent struct {
	Entry   *Entry // non-nil: added/updated/offline
	Removed string // peer ID removed from the plaza
}

func NewPlaza() *Plaza {
	return &Plaza{records: map[string]*plazaRecord{}, subs: map[chan PlazaEvent]struct{}{}, overflow: map[chan PlazaEvent]bool{}}
}

// Check reports whether env would be accepted, without storing it.
func (p *Plaza) Check(env Envelope, now time.Time) (*PlazaBody, error) {
	body, err := VerifyEnvelope(env, now)
	if err != nil {
		return nil, err
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if current, ok := p.records[body.PeerID]; ok && body.Seq <= current.body.Seq {
		return nil, errStale
	}
	return body, nil
}

// Apply stores a verified announcement (or removes the peer on bye).
func (p *Plaza) Apply(env Envelope, body *PlazaBody, now time.Time) {
	p.mu.Lock()
	current, ok := p.records[body.PeerID]
	if ok && body.Seq <= current.body.Seq {
		p.mu.Unlock()
		return
	}
	if body.Bye {
		// Keep a tombstone with the seq so a replayed older announcement is rejected.
		p.records[body.PeerID] = &plazaRecord{env: env, body: *body, lastSeen: now.Add(-EntryTTL - OfflineRetention), offline: true}
		p.mu.Unlock()
		if ok && !current.body.Bye {
			p.publish(PlazaEvent{Removed: body.PeerID})
		}
		return
	}
	p.records[body.PeerID] = &plazaRecord{env: env, body: *body, lastSeen: now}
	entry := &Entry{PlazaBody: *body}
	p.mu.Unlock()
	p.publish(PlazaEvent{Entry: entry})
}

// Sweep marks silent peers offline and drops them after the retention window.
func (p *Plaza) Sweep(now time.Time) {
	var events []PlazaEvent
	p.mu.Lock()
	for id, record := range p.records {
		age := now.Sub(record.lastSeen)
		switch {
		case age >= EntryTTL+OfflineRetention+5*time.Minute:
			delete(p.records, id) // tombstone no longer needed: older seqs fail the clock check
		case record.body.Bye:
		case age >= EntryTTL+OfflineRetention:
			record.body.Bye = true
			events = append(events, PlazaEvent{Removed: id})
		case age >= EntryTTL && !record.offline:
			record.offline = true
			events = append(events, PlazaEvent{Entry: &Entry{PlazaBody: record.body, Offline: true}})
		}
	}
	p.mu.Unlock()
	for _, event := range events {
		p.publish(event)
	}
}

// MarkOffline greys out a peer whose gateway session dropped, without waiting
// for EntryTTL. A newer announcement (e.g. after reconnecting) restores it.
func (p *Plaza) MarkOffline(id string, now time.Time) {
	p.mu.Lock()
	record, ok := p.records[id]
	if !ok || record.offline || record.body.Bye {
		p.mu.Unlock()
		return
	}
	record.offline = true
	record.lastSeen = now.Add(-EntryTTL)
	entry := &Entry{PlazaBody: record.body, Offline: true}
	p.mu.Unlock()
	p.publish(PlazaEvent{Entry: entry})
}

// Entries returns all visible entries sorted by peer ID.
func (p *Plaza) Entries() []Entry {
	p.mu.Lock()
	defer p.mu.Unlock()
	result := make([]Entry, 0, len(p.records))
	for _, record := range p.records {
		if !record.body.Bye {
			result = append(result, Entry{PlazaBody: record.body, Offline: record.offline})
		}
	}
	sort.Slice(result, func(i, j int) bool { return result[i].PeerID < result[j].PeerID })
	return result
}

// SnapshotItem is served on SnapshotProto so browsers can verify each envelope themselves.
type SnapshotItem struct {
	Envelope Envelope `json:"envelope"`
	Offline  bool     `json:"offline"`
}

func (p *Plaza) Snapshot() []SnapshotItem {
	p.mu.Lock()
	defer p.mu.Unlock()
	result := make([]SnapshotItem, 0, len(p.records))
	for _, record := range p.records {
		if !record.body.Bye {
			result = append(result, SnapshotItem{Envelope: record.env, Offline: record.offline})
		}
	}
	return result
}

// Holders returns online peers attached through node that announce cid.
func (p *Plaza) Holders(cidValue string, node peer.ID) []string {
	p.mu.Lock()
	defer p.mu.Unlock()
	var result []string
	for id, record := range p.records {
		if record.offline || record.body.Bye {
			continue
		}
		attached := false
		for _, via := range record.body.ViaNodes() {
			attached = attached || via.ID == node
		}
		if !attached {
			continue
		}
		for _, file := range record.body.Files {
			if file.CID == cidValue {
				result = append(result, id)
				break
			}
		}
	}
	sort.Strings(result)
	return result
}

// Lookup returns the entry for a peer when it is online.
func (p *Plaza) Lookup(id string) (PlazaBody, bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	record, ok := p.records[id]
	if !ok || record.offline || record.body.Bye {
		return PlazaBody{}, false
	}
	return record.body, true
}

func (p *Plaza) Subscribe() chan PlazaEvent {
	ch := make(chan PlazaEvent, 256)
	p.mu.Lock()
	p.subs[ch] = struct{}{}
	p.mu.Unlock()
	return ch
}

func (p *Plaza) Unsubscribe(ch chan PlazaEvent) {
	p.mu.Lock()
	delete(p.subs, ch)
	delete(p.overflow, ch)
	p.mu.Unlock()
}

func (p *Plaza) publish(event PlazaEvent) {
	p.mu.Lock()
	defer p.mu.Unlock()
	for ch := range p.subs {
		select {
		case ch <- event:
		default: // a slow subscriber resyncs from a full snapshot (see TakeOverflow)
			p.overflow[ch] = true
		}
	}
}

// TakeOverflow reports (and clears) whether events were dropped for ch.
func (p *Plaza) TakeOverflow(ch chan PlazaEvent) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	dropped := p.overflow[ch]
	delete(p.overflow, ch)
	return dropped
}
