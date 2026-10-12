package hub

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
	"webtrc-signaling/internal/model"
)

const MaxChunk = 1 << 20

var hashPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)
var artifactPattern = regexp.MustCompile(`^relay-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.part$`)

type TransferConfig struct {
	CacheDir           string
	PublicURL          string
	MaxFileSize        int64
	MaxCacheBytes      int64
	MaxOwnerBytes      int64
	MaxGrants          int
	MaxOwnerGrants     int
	MaxRecipientGrants int
	MaxContents        int
	MaxPendingUploads  int
	MaxStreams         int
	BytesPerSecond     int64
	GrantTTL           time.Duration
	IdleTTL            time.Duration
}

func DefaultTransferConfig(dir, publicURL string) TransferConfig {
	return TransferConfig{CacheDir: dir, PublicURL: publicURL, MaxFileSize: 2 << 30,
		MaxCacheBytes: 4 << 30, MaxOwnerBytes: 2 << 30, MaxGrants: 2048, MaxOwnerGrants: 256,
		MaxRecipientGrants: 4, MaxContents: 64, MaxPendingUploads: 50, MaxStreams: 128,
		BytesPerSecond: 64 << 20, GrantTTL: 30 * time.Minute, IdleTTL: 10 * time.Minute}
}

type grant struct {
	id, owner, recipient, requestID, token, mode string
	file                                         model.FileMeta
	expires                                      time.Time
	generation                                   int
	completed                                    bool
	requests                                     map[string]bool
	httpRate                                     requestRate
	content                                      *relayContent
	ctx                                          context.Context
	cancel                                       context.CancelFunc
}

type relayContent struct {
	mu                           sync.Mutex
	id, owner, hash, token, path string
	size, offset                 int64
	ready, failed, scheduled     bool // protected by Hub.mu (offset by content.mu)
	refs                         int
	idle                         time.Time
	created                      time.Time
	expires                      time.Time
	lastNotified                 time.Time
	file                         model.FileMeta
	httpRate                     requestRate
	ctx                          context.Context
	cancel                       context.CancelFunc
}

type transferStore struct {
	config    TransferConfig
	grants    map[string]*grant
	contents  map[string]*relayContent
	reserved  int64
	streams   chan struct{}
	rateMu    sync.Mutex
	nextWrite time.Time
}

func (h *Hub) EnableTransfers(cfg TransferConfig) error {
	u, err := url.Parse(cfg.PublicURL)
	if err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return errors.New("gateway-public-url must be an absolute HTTPS URL without credentials/query/fragment")
	}
	if cfg.MaxFileSize <= 0 || cfg.MaxCacheBytes < cfg.MaxFileSize || cfg.MaxOwnerBytes < cfg.MaxFileSize ||
		cfg.MaxGrants < 1 || cfg.MaxOwnerGrants < 1 || cfg.MaxRecipientGrants < 1 || cfg.MaxContents < 1 ||
		cfg.MaxPendingUploads < 1 || cfg.MaxStreams < 1 || cfg.BytesPerSecond < 1 ||
		cfg.GrantTTL <= 0 || cfg.IdleTTL <= 0 {
		return errors.New("invalid transfer limits")
	}
	if err := os.MkdirAll(cfg.CacheDir, 0700); err != nil {
		return err
	}
	info, err := os.Lstat(cfg.CacheDir)
	if err != nil {
		return err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return errors.New("cache must be a real directory")
	}
	entries, err := os.ReadDir(cfg.CacheDir)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if artifactPattern.MatchString(entry.Name()) {
			if entry.Type()&os.ModeSymlink != 0 || entry.IsDir() {
				return errors.New("unsafe cache artifact")
			}
			if err := os.Remove(filepath.Join(cfg.CacheDir, entry.Name())); err != nil {
				return err
			}
		}
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.transfers != nil {
		return errors.New("gateway already enabled")
	}
	cfg.PublicURL = strings.TrimRight(cfg.PublicURL, "/")
	h.transfers = &transferStore{config: cfg, grants: map[string]*grant{}, contents: map[string]*relayContent{}, streams: make(chan struct{}, cfg.MaxStreams)}
	return nil
}

func opaqueToken() string {
	var data [32]byte
	if _, err := rand.Read(data[:]); err != nil {
		panic(err)
	}
	return hex.EncodeToString(data[:])
}

func equalToken(a, b string) bool {
	return len(a) == 64 && len(b) == 64 && subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1
}

func (h *Hub) validGrantLocked(g *grant, now time.Time) bool {
	owner, recipient := h.clients[g.owner], h.clients[g.recipient]
	return g.ctx.Err() == nil && now.Before(g.expires) && now.Before(h.leases[g.owner]) &&
		owner != nil && owner.Verified && recipient != nil && recipient.Verified &&
		(g.content == nil || !g.content.failed)
}

func (h *Hub) transferLocked(g *grant) *model.Transfer {
	t := &model.Transfer{ID: g.id, File: g.file, Mode: g.mode, Token: g.token,
		DownloadURL: h.transfers.config.PublicURL + "/v2/transfers/" + g.id + "/download",
		ExpiresAt:   g.expires.Unix(), Status: "waiting", Generation: g.generation}
	if g.mode == "p2p" || (g.content != nil && g.content.ready) {
		t.Status = "ready"
	}
	return t
}

func (h *Hub) RequestTransfer(c *Client, msg *model.WSMessage, now time.Time) (*model.Transfer, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	s := h.transfers
	if h.clients[c.ID] != c || !c.Verified {
		return nil, errors.New("identity-required")
	}
	if s == nil {
		return nil, errors.New("gateway-disabled")
	}
	if _, err := uuid.Parse(msg.RequestID); err != nil {
		return nil, errors.New("invalid-request-id")
	}
	if expiry := h.canceledRequests[c.ID][msg.RequestID]; now.Before(expiry) {
		return nil, errors.New("request-canceled")
	}
	if msg.Mode != "" && msg.Mode != "relay" && msg.Mode != "p2p" {
		return nil, errors.New("invalid-mode")
	}
	if msg.TransferID != "" {
		g := s.grants[msg.TransferID]
		if g == nil || g.recipient != c.ID || g.owner != msg.To || g.file.ID != msg.FileID ||
			!h.validGrantLocked(g, now) {
			return nil, errors.New("invalid-or-revoked-transfer")
		}
		if !g.requests[msg.RequestID] {
			if len(g.requests) >= 64 {
				return nil, errors.New("resume-limit")
			}
			if msg.Mode == "relay" && g.mode == "p2p" {
				if err := h.attachRelayLocked(g, now); err != nil {
					return nil, err
				}
			}
			g.requests[msg.RequestID] = true
			if g.mode == "p2p" {
				g.generation++
			}
		}
		if msg.Mode == "relay" && g.mode == "p2p" {
			if g.content == nil {
				if err := h.attachRelayLocked(g, now); err != nil {
					return nil, err
				}
			}
			if owner := h.clients[g.owner]; owner != nil {
				_ = owner.Send(&model.WSMessage{Type: "transfer-revoked", TransferID: g.id, Error: "relay-upgrade"})
			}
			g.mode = "relay"
			h.scheduleLocked(g.owner, now)
		}
		g.requestID = msg.RequestID
		g.expires = now.Add(s.config.GrantTTL)
		h.retryUploadLocked(g, now)
		h.authorizeP2PLocked(g)
		return h.transferLocked(g), nil
	}
	for _, g := range s.grants {
		if g.recipient == c.ID && g.requests[msg.RequestID] {
			if g.owner != msg.To || g.file.ID != msg.FileID {
				return nil, errors.New("request-id-conflict")
			}
			if !h.validGrantLocked(g, now) {
				return nil, errors.New("invalid-or-revoked-transfer")
			}
			if msg.Mode == "relay" && g.mode == "p2p" {
				if err := h.attachRelayLocked(g, now); err != nil {
					return nil, err
				}
				if owner := h.clients[g.owner]; owner != nil {
					_ = owner.Send(&model.WSMessage{Type: "transfer-revoked", TransferID: g.id, Error: "relay-upgrade"})
				}
				g.mode = "relay"
				h.scheduleLocked(g.owner, now)
			}
			g.expires = now.Add(s.config.GrantTTL)
			h.retryUploadLocked(g, now)
			h.authorizeP2PLocked(g)
			return h.transferLocked(g), nil
		}
	}
	f := h.files[msg.FileID]
	owner := h.clients[msg.To]
	if f == nil || f.OwnerID != msg.To || h.current[msg.To] != msg.FileID || msg.To == c.ID || owner == nil || !owner.Verified ||
		!now.Before(h.leases[msg.To]) {
		return nil, errors.New("not-available")
	}
	if f.ProtocolVersion != 2 || !hashPattern.MatchString(f.SHA256) {
		return nil, errors.New("manifest-required")
	}
	if f.Size <= 0 || f.Size > s.config.MaxFileSize {
		return nil, errors.New("file-too-large")
	}
	ownerCount, recipientCount, p2p := 0, 0, 0
	for _, g := range s.grants {
		if !h.validGrantLocked(g, now) {
			continue
		}
		if g.owner == msg.To {
			ownerCount++
			if g.mode == "p2p" {
				p2p++
			}
		}
		if g.recipient == c.ID {
			recipientCount++
		}
	}

	if len(s.grants) >= s.config.MaxGrants || ownerCount >= s.config.MaxOwnerGrants ||
		recipientCount >= s.config.MaxRecipientGrants {
		return nil, errors.New("full")
	}
	g := &grant{id: uuid.NewString(), owner: msg.To, recipient: c.ID, requestID: msg.RequestID,
		token: opaqueToken(), mode: "p2p", file: *f, expires: now.Add(s.config.GrantTTL), generation: 1}
	g.requests = map[string]bool{msg.RequestID: true}
	if p2p >= 2 || msg.Mode == "relay" {
		g.mode = "relay"
		if err := h.attachRelayLocked(g, now); err != nil {
			return nil, err
		}
	}
	g.ctx, g.cancel = context.WithCancel(context.Background())
	s.grants[g.id] = g
	h.scheduleLocked(msg.To, now)
	h.authorizeP2PLocked(g)
	return h.transferLocked(g), nil
}

func (h *Hub) retryUploadLocked(g *grant, now time.Time) {
	v := g.content
	if v == nil || v.ready || v.failed || !v.scheduled || now.Sub(v.lastNotified) < 15*time.Second {
		return
	}
	if owner := h.clients[v.owner]; owner != nil {
		v.lastNotified = now
		v.expires = now.Add(2 * time.Hour)
		_ = owner.Send(&model.WSMessage{Type: "upload-request", Transfer: &model.Transfer{ID: v.id, File: v.file, Mode: "relay", Token: v.token,
			UploadURL: h.transfers.config.PublicURL + "/v2/uploads/" + v.id, ExpiresAt: v.expires.Unix()}})
	}
}

func (h *Hub) attachRelayLocked(g *grant, now time.Time) error {
	s := h.transfers
	f := g.file
	key := fmt.Sprintf("%s:%s:%d", g.owner, f.SHA256, f.Size)
	content := s.contents[key]
	if content != nil && content.failed {
		return errors.New("busy")
	}
	if content == nil {
		var ownerBytes int64
		pending := 0
		for _, v := range s.contents {
			if v.owner == g.owner {
				ownerBytes += v.size
				if !v.ready && !v.failed {
					pending++
				}
			}
		}
		if len(s.contents) >= s.config.MaxContents || f.Size > s.config.MaxCacheBytes-s.reserved ||
			f.Size > s.config.MaxOwnerBytes-ownerBytes {
			return errors.New("cache-full")
		}
		if pending >= s.config.MaxPendingUploads {
			return errors.New("busy")
		}
		ctx, cancel := context.WithCancel(context.Background())
		id := uuid.NewString()
		content = &relayContent{id: id, owner: g.owner, hash: f.SHA256, size: f.Size, token: opaqueToken(),
			path: filepath.Join(s.config.CacheDir, "relay-"+id+".part"), file: f, ctx: ctx, cancel: cancel, created: now}
		s.contents[key] = content
		s.reserved += f.Size
	}
	content.refs++
	content.idle = time.Time{}
	g.content = content
	return nil
}

func (h *Hub) authorizeP2PLocked(g *grant) {
	if g.mode != "p2p" {
		return
	}
	if owner := h.clients[g.owner]; owner != nil {
		_ = owner.Send(&model.WSMessage{Type: "transfer-authorized", From: g.recipient,
			Transfer: &model.Transfer{ID: g.id, File: g.file, Mode: "p2p", Token: "", ExpiresAt: g.expires.Unix(), Generation: g.generation}})
	}
}

func (h *Hub) notifyRevokedLocked(g *grant, reason string) {
	for _, peer := range []string{g.owner, g.recipient} {
		if c := h.clients[peer]; c != nil {
			_ = c.Send(&model.WSMessage{Type: "transfer-revoked", TransferID: g.id, Error: reason})
		}
	}
}

type requestRate struct {
	start time.Time
	count int
}

func (v *requestRate) allow(now time.Time) bool {
	if now.Sub(v.start) >= time.Second {
		v.start = now
		v.count = 0
	}
	v.count++
	return v.count <= 120
}

func (h *Hub) scheduleLocked(owner string, now time.Time) {
	s := h.transfers
	if s == nil {
		return
	}
	for _, v := range s.contents {
		if v.owner == owner && v.scheduled && !v.ready && !v.failed {
			return
		}
	}
	var selected *relayContent
	for _, v := range s.contents {
		if v.owner != owner || v.refs == 0 || v.scheduled || v.ready || v.failed {
			continue
		}
		if selected == nil || v.created.Before(selected.created) {
			selected = v
		}
	}
	if selected != nil {
		client := h.clients[owner]
		if client == nil {
			return
		}
		selected.scheduled = true
		selected.expires = now.Add(2 * time.Hour)
		selected.lastNotified = now
		_ = client.Send(&model.WSMessage{Type: "upload-request", Transfer: &model.Transfer{ID: selected.id, File: selected.file,
			Mode: "relay", Token: selected.token, UploadURL: s.config.PublicURL + "/v2/uploads/" + selected.id,
			ExpiresAt: selected.expires.Unix()}})
	}
}

func (h *Hub) releaseLocked(g *grant, now time.Time) {
	g.cancel()
	delete(h.transfers.grants, g.id)
	if v := g.content; v != nil {
		v.refs--
		if v.refs == 0 {
			v.idle = now
			if !v.ready {
				if v.scheduled && !v.failed {
					if owner := h.clients[v.owner]; owner != nil {
						_ = owner.Send(&model.WSMessage{Type: "transfer-revoked", TransferID: v.id, Error: "released"})
					}
				}
				v.failed = true
				v.cancel()
				v.idle = now.Add(-h.transfers.config.IdleTTL)
			}
		}
	}
	h.scheduleLocked(g.owner, now)
}

func (h *Hub) ReleaseTransfer(c *Client, id string) error {
	return h.finishTransfer(c, id, false)
}

func (h *Hub) CancelTransfer(c *Client, requestID, id string) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.clients[c.ID] != c {
		return errors.New("client is no longer registered")
	}
	if requestID != "" {
		if _, err := uuid.Parse(requestID); err != nil {
			return errors.New("invalid-request-id")
		}
		now := time.Now()
		requests := h.canceledRequests[c.ID]
		total := 0
		for _, entries := range h.canceledRequests {
			total += len(entries)
		}
		if total >= 8192 && requests[requestID].IsZero() {
			return errors.New("cancel-limit")
		}
		if requests == nil {
			requests = map[string]time.Time{}
			h.canceledRequests[c.ID] = requests
		}
		for key, expiry := range requests {
			if !now.Before(expiry) {
				delete(requests, key)
			}
		}
		if len(requests) >= 256 && requests[requestID].IsZero() {
			return errors.New("cancel-limit")
		}
		requests[requestID] = now.Add(5 * time.Minute)
	}
	if h.transfers == nil {
		return nil
	}
	g := h.transfers.grants[id]
	if g == nil && requestID != "" {
		for _, candidate := range h.transfers.grants {
			if candidate.recipient == c.ID && candidate.requests[requestID] {
				g = candidate
				break
			}
		}
	}
	if g == nil {
		return nil
	}
	if g.recipient != c.ID {
		return errors.New("not-your-transfer")
	}
	h.notifyRevokedLocked(g, "released")
	h.releaseLocked(g, time.Now())
	return nil
}

func (h *Hub) UploadError(c *Client, id string) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.clients[c.ID] != c || !c.Verified {
		return errors.New("identity-required")
	}
	if h.transfers == nil {
		return errors.New("gateway-disabled")
	}
	for _, v := range h.transfers.contents {
		if v.id != id {
			continue
		}
		if v.owner != c.ID || !v.scheduled {
			return errors.New("not-your-upload")
		}
		if v.ready || v.failed {
			return nil
		}
		h.failContentLocked(v, "upload-failed")
		return nil
	}
	return errors.New("invalid-upload")
}

func (h *Hub) CompleteTransfer(c *Client, id string) error {
	return h.finishTransfer(c, id, true)
}

func (h *Hub) finishTransfer(c *Client, id string, completed bool) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.clients[c.ID] != c {
		return errors.New("client is no longer registered")
	}
	if h.transfers == nil {
		return nil
	}
	g := h.transfers.grants[id]
	if g == nil {
		return nil
	}
	if g.recipient != c.ID {
		return errors.New("not-your-transfer")
	}
	if completed {
		if owner := h.clients[g.owner]; owner != nil {
			_ = owner.Send(&model.WSMessage{Type: "transfer-completed", TransferID: g.id})
		}
	} else {
		h.notifyRevokedLocked(g, "released")
	}
	h.releaseLocked(g, time.Now())
	return nil
}

func (h *Hub) revokeLocked(id string) {
	if h.transfers == nil {
		return
	}
	now := time.Now()
	for _, v := range h.transfers.contents {
		if v.owner == id {
			if v.scheduled && !v.ready && !v.failed {
				if owner := h.clients[v.owner]; owner != nil {
					_ = owner.Send(&model.WSMessage{Type: "transfer-revoked", TransferID: v.id, Error: "revoked"})
				}
			}
			v.failed = true
			v.cancel()
			v.idle = now.Add(-h.transfers.config.IdleTTL)
		}
	}
	for _, g := range h.transfers.grants {
		if g.owner == id || g.recipient == id {
			h.notifyRevokedLocked(g, "revoked")
			h.releaseLocked(g, now)
		}
	}
	for _, v := range h.transfers.contents {
		if v.owner == id {
			v.idle = now.Add(-h.transfers.config.IdleTTL)
		}
	}
}

// SweepTransfers bounds leases independently of WS heartbeat delivery and removes only owned artifacts.
func (h *Hub) SweepTransfers(now time.Time) {
	h.mu.Lock()
	if h.transfers == nil {
		h.mu.Unlock()
		return
	}
	s := h.transfers
	for owner, requests := range h.canceledRequests {
		for id, expiry := range requests {
			if !now.Before(expiry) {
				delete(requests, id)
			}
		}
		if len(requests) == 0 {
			delete(h.canceledRequests, owner)
		}
	}
	for _, v := range s.contents {
		if v.scheduled && !v.ready && !v.failed && v.refs > 0 && v.expires.Sub(now) < time.Minute &&
			now.Before(h.leases[v.owner]) {
			if owner := h.clients[v.owner]; owner != nil {
				v.expires = now.Add(2 * time.Hour)
				_ = owner.Send(&model.WSMessage{Type: "upload-request", Transfer: &model.Transfer{ID: v.id, File: v.file,
					Mode: "relay", Token: v.token, UploadURL: s.config.PublicURL + "/v2/uploads/" + v.id, ExpiresAt: v.expires.Unix()}})
			}
		}
	}
	for _, g := range s.grants {
		if g.completed && now.Before(g.expires) && now.Before(h.leases[g.owner]) &&
			h.clients[g.owner] != nil && h.clients[g.recipient] != nil {
			continue
		}
		if !h.validGrantLocked(g, now) {
			h.notifyRevokedLocked(g, "expired-or-revoked")
			h.releaseLocked(g, now)
		}
	}
	var cleanup []*relayContent
	for _, v := range s.contents {
		if v.refs == 0 && !v.idle.IsZero() && now.Sub(v.idle) >= s.config.IdleTTL {
			cleanup = append(cleanup, v)
		}
	}
	h.mu.Unlock()
	for _, v := range cleanup {
		v.mu.Lock()
		h.mu.Lock()
		if v.refs == 0 && !v.idle.IsZero() && now.Sub(v.idle) >= s.config.IdleTTL {
			v.cancel()
			if err := os.Remove(v.path); err == nil || os.IsNotExist(err) {
				for key, item := range s.contents {
					if item == v {
						delete(s.contents, key)
						break
					}
				}
				s.reserved -= v.size
			} else {
				v.failed = true
			}
		}
		h.mu.Unlock()
		v.mu.Unlock()
	}
}
