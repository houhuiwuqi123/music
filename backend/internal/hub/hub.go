package hub

import (
	"encoding/json"
	"sync"
	"time"

	"github.com/gogf/gf/v2/net/ghttp"

	"webtrc-signaling/internal/model"
)

// Client 代表一个已连接的广场成员。
type Client struct {
	ID     string
	Conn   *ghttp.WebSocket
	Region string
	mu     sync.Mutex // 保护 Conn 的并发写
}

func (c *Client) Send(v *model.WSMessage) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if err := c.Conn.SetWriteDeadline(time.Now().Add(10 * time.Second)); err != nil {
		return err
	}
	return c.Conn.WriteJSON(v)
}

// Hub 维护在线客户端与广场文件列表，是信令服务的核心状态容器。
type Hub struct {
	mu          sync.RWMutex
	clients     map[string]*Client
	files       map[string]*model.FileMeta // fileId -> meta
	listeningMu sync.Mutex
	listening   map[string]listeningEntry
}

func New() *Hub {
	return &Hub{
		clients:   make(map[string]*Client),
		files:     make(map[string]*model.FileMeta),
		listening: make(map[string]listeningEntry),
	}
}

// Register 将客户端加入广场，并返回当前广场上的全部文件快照。
func (h *Hub) Register(c *Client) []*model.FileMeta {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.clients[c.ID] = c
	return h.snapshotLocked()
}

// Unregister 移除客户端，并清理其发布的所有文件，返回更新后的文件快照。
func (h *Hub) Unregister(id string) []*model.FileMeta {
	h.mu.Lock()
	defer h.mu.Unlock()
	delete(h.clients, id)
	for fid, f := range h.files {
		if f.OwnerID == id {
			delete(h.files, fid)
		}
	}
	return h.snapshotLocked()
}

// Publish 在广场上发布一个文件，返回更新后的文件快照。
func (h *Hub) Publish(f *model.FileMeta) []*model.FileMeta {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.files[f.ID] = f
	return h.snapshotLocked()
}

// Unpublish 从广场上移除一个文件，返回更新后的文件快照。
func (h *Hub) Unpublish(fileID string) []*model.FileMeta {
	h.mu.Lock()
	defer h.mu.Unlock()
	delete(h.files, fileID)
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
func (h *Hub) RelaySignal(from, to string, data json.RawMessage) bool {
	h.mu.RLock()
	target, ok := h.clients[to]
	h.mu.RUnlock()
	if !ok {
		return false
	}
	_ = target.Send(&model.WSMessage{Type: "signal", From: from, Data: data})
	return true
}
