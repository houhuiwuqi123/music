package hub

import (
	"encoding/json"
	"errors"
	"sync"
	"time"

	"github.com/gogf/gf/v2/net/ghttp"

	"webtrc-signaling/internal/model"
)

// Client 代表一个已连接的广场成员。
type Client struct {
	ID        string
	Conn      *ghttp.WebSocket
	Region    string
	Verified  bool
	mu        sync.Mutex // 保护 Conn 的并发写
	queue     chan *model.WSMessage
	stop      chan struct{}
	stopped   bool
	rateStart time.Time
	rateCount int
}

func (c *Client) AllowMessage(now time.Time) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	if now.Sub(c.rateStart) >= time.Second {
		c.rateStart = now
		c.rateCount = 0
	}
	c.rateCount++
	return c.rateCount <= 30
}

func (c *Client) Send(v *model.WSMessage) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.stopped {
		return errors.New("socket closed")
	}
	if c.Conn == nil {
		return nil
	}
	if c.queue == nil {
		c.queue = make(chan *model.WSMessage, 128)
		c.stop = make(chan struct{})
		go c.writer()
	}
	select {
	case c.queue <- v:
		return nil
	default:
		c.stopped = true
		close(c.stop)
		go c.Conn.Close()
		return errors.New("socket queue full")
	}
}

func (c *Client) writer() {
	defer c.Close()
	for {
		select {
		case <-c.stop:
			return
		case v := <-c.queue:
			if err := c.Conn.SetWriteDeadline(time.Now().Add(10 * time.Second)); err != nil {
				return
			}
			if err := c.Conn.WriteJSON(v); err != nil {
				return
			}
		}
	}
}

func (c *Client) Close() {
	c.mu.Lock()
	if !c.stopped {
		c.stopped = true
		if c.stop != nil {
			close(c.stop)
		}
	}
	c.mu.Unlock()
	if c.Conn != nil {
		_ = c.Conn.Close()
	}
}

// Hub 维护在线客户端与广场文件列表，是信令服务的核心状态容器。
type Hub struct {
	mu               sync.RWMutex
	clients          map[string]*Client
	files            map[string]*model.FileMeta // fileId -> meta
	listeningMu      sync.Mutex
	listening        map[string]listeningEntry
	transfers        *transferStore
	leases           map[string]time.Time
	current          map[string]string
	canceledRequests map[string]map[string]time.Time
}

func New() *Hub {
	return &Hub{
		clients:          make(map[string]*Client),
		files:            make(map[string]*model.FileMeta),
		listening:        make(map[string]listeningEntry),
		leases:           make(map[string]time.Time),
		current:          make(map[string]string),
		canceledRequests: make(map[string]map[string]time.Time),
	}
}

// Register 将客户端加入广场，并返回当前广场上的全部文件快照。
func (h *Hub) Register(c *Client) []*model.FileMeta {
	h.listeningMu.Lock()
	defer h.listeningMu.Unlock()
	h.mu.Lock()
	defer h.mu.Unlock()
	if old := h.clients[c.ID]; old != nil && old != c {
		h.revokeLocked(c.ID)
		delete(h.leases, c.ID)
		delete(h.current, c.ID)
		for id, file := range h.files {
			if file.OwnerID == c.ID {
				delete(h.files, id)
			}
		}
		if entry, exists := h.listening[c.ID]; exists {
			now := time.Now().Unix()
			entry.state.OfflineAt = &now
			h.listening[c.ID] = entry
		}
		old.Close()
	}
	h.clients[c.ID] = c
	return h.snapshotLocked()
}

func (h *Hub) snapshotLocked() []*model.FileMeta {
	list := make([]*model.FileMeta, 0, len(h.files))
	for _, f := range h.files {
		list = append(list, f)
	}
	return list
}

// Snapshot 返回当前广场文件快照（线程安全）。
func (h *Hub) Snapshot() []*model.FileMeta {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return h.snapshotLocked()
}

// Broadcast 向所有在线客户端推送广场快照。
func (h *Hub) Broadcast(files []*model.FileMeta) {
	h.mu.RLock()
	clients := make([]*Client, 0, len(h.clients))
	for _, c := range h.clients {
		clients = append(clients, c)
	}
	h.mu.RUnlock()

	msg := &model.WSMessage{Type: "plaza", Files: files}
	for _, c := range clients {
		_ = c.Send(msg)
	}
}

// RelaySignal 将信令消息转发给目标客户端（用于 offer/answer/ICE candidate 转发）。
func (h *Hub) RelaySignal(client *Client, msg *model.WSMessage) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.clients[client.ID] != client || h.transfers == nil {
		return false
	}
	grant := h.transfers.grants[msg.TransferID]
	if grant == nil || grant.mode != "p2p" || !h.validGrantLocked(grant, time.Now()) ||
		msg.Generation != grant.generation {
		return false
	}
	if !((client.ID == grant.owner && msg.To == grant.recipient) ||
		(client.ID == grant.recipient && msg.To == grant.owner)) {
		return false
	}
	var inner string
	if json.Unmarshal(msg.Data, &inner) != nil {
		return false
	}
	var envelope struct {
		TransferID string `json:"transferId"`
		FileID     string `json:"fileId"`
		Generation int    `json:"generation"`
	}
	if json.Unmarshal([]byte(inner), &envelope) != nil || envelope.TransferID != grant.id ||
		envelope.FileID != grant.file.ID || envelope.Generation != grant.generation {
		return false
	}
	target := h.clients[msg.To]
	if target == nil {
		return false
	}
	return target.Send(&model.WSMessage{Type: "signal", From: client.ID, Data: msg.Data, TransferID: grant.id, Generation: grant.generation}) == nil
}

func (h *Hub) Active(c *Client) bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return h.clients[c.ID] == c
}

func (h *Hub) PublishClient(c *Client, f *model.FileMeta) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.clients[c.ID] != c || f == nil || f.ID == "" || f.Size < 0 {
		return errors.New("invalid publication")
	}
	if old := h.files[f.ID]; old != nil && old.OwnerID != c.ID {
		return errors.New("file belongs to another client")
	}
	if old := h.files[f.ID]; old != nil && old.SHA256 != "" &&
		(old.Size != f.Size || old.SHA256 != f.SHA256) {
		return errors.New("publication manifest is immutable")
	}
	if len(f.ID) > 128 || len(f.Name) > 1200 || len(f.OwnerName) > 320 {
		return errors.New("invalid publication")
	}
	if f.SHA256 != "" && (!hashPattern.MatchString(f.SHA256) || f.ProtocolVersion != 2) {
		return errors.New("invalid hash manifest")
	}
	if h.files[f.ID] == nil && len(h.files) >= 4096 {
		return errors.New("plaza-full")
	}
	count := 0
	for _, file := range h.files {
		if file.OwnerID == c.ID {
			count++
		}
	}
	if h.files[f.ID] == nil && count >= 64 {
		return errors.New("publication-limit")
	}
	value := *f
	value.OwnerID = c.ID
	h.files[value.ID] = &value
	return nil
}

func (h *Hub) UnpublishClient(c *Client, id string) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.clients[c.ID] != c {
		return errors.New("client is no longer registered")
	}
	if f := h.files[id]; f != nil && f.OwnerID != c.ID {
		return errors.New("file belongs to another client")
	}
	delete(h.files, id)
	return nil
}
