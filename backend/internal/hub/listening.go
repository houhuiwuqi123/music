package hub

import (
	"bytes"
	"context"
	"encoding/base64"
	"fmt"
	"image"
	_ "image/jpeg"
	_ "image/png"
	"reflect"
	"sort"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/gogf/gf/v2/frame/g"
	"github.com/google/uuid"
	"webtrc-signaling/internal/model"
)

const ListeningTTL = 90 * time.Second
const OfflineRetention = 60 * time.Second

type listeningEntry struct {
	state   model.Listening
	updated time.Time
}

func (h *Hub) listeningSnapshotLocked() []model.Listening {
	list := make([]model.Listening, 0, len(h.listening))
	for _, entry := range h.listening {
		list = append(list, entry.state)
	}
	sort.Slice(list, func(i, j int) bool { return list[i].ClientID < list[j].ClientID })
	return list
}

func (h *Hub) broadcastListeningLocked() {
	h.mu.RLock()
	clients := make([]*Client, 0, len(h.clients))
	for _, client := range h.clients {
		clients = append(clients, client)
	}
	h.mu.RUnlock()
	message := &model.WSMessage{Type: "listeners", Listeners: h.listeningSnapshotLocked()}
	for _, client := range clients {
		if err := client.Send(message); err != nil {
			g.Log().Warning(context.Background(), "listening broadcast failed:", client.ID, err)
		}
	}
}

func (h *Hub) SendListeningSnapshot(client *Client) error {
	h.listeningMu.Lock()
	defer h.listeningMu.Unlock()
	return client.Send(&model.WSMessage{Type: "listeners", Listeners: h.listeningSnapshotLocked()})
}

func (h *Hub) removeListeningFileLocked(state model.Listening) {
	if state.File == nil {
		return
	}
	h.mu.Lock()
	if file := h.files[state.File.ID]; file != nil && file.OwnerID == state.ClientID {
		delete(h.files, state.File.ID)
	}
	h.mu.Unlock()
}

func (h *Hub) UpdateListening(client *Client, state *model.Listening, now time.Time) error {
	h.listeningMu.Lock()
	defer h.listeningMu.Unlock()
	h.mu.RLock()
	registered := h.clients[client.ID] == client
	h.mu.RUnlock()
	if !registered {
		return fmt.Errorf("client is no longer registered")
	}
	if state == nil {
		h.mu.Lock()
		h.revokeLocked(client.ID)
		delete(h.leases, client.ID)
		delete(h.current, client.ID)
		h.mu.Unlock()
		if previous, exists := h.listening[client.ID]; exists {
			h.removeListeningFileLocked(previous.state)
			delete(h.listening, client.ID)
			h.broadcastListeningLocked()
			h.Broadcast(h.Snapshot())
		}
		return nil
	}
	value := *state
	value.ClientID = client.ID
	value.OfflineAt = nil
	if value.Avatar != "" {
		data, err := base64.StdEncoding.DecodeString(value.Avatar)
		if err != nil || len(data) > 32768 {
			return fmt.Errorf("invalid avatar size or encoding")
		}
		config, _, err := image.DecodeConfig(bytes.NewReader(data))
		if err != nil || config.Width > 256 || config.Height > 256 || config.Width < 1 || config.Height < 1 {
			return fmt.Errorf("invalid avatar image")
		}
	}
	value.Region = client.Region
	if value.Region == "" {
		value.Region = "地区未知"
	}
	value.OwnerName = strings.TrimSpace(value.OwnerName)
	value.Title = strings.TrimSpace(value.Title)
	value.Artist = strings.TrimSpace(value.Artist)
	if value.OwnerName == "" || value.Title == "" ||
		utf8.RuneCountInString(value.OwnerName) > 80 ||
		utf8.RuneCountInString(value.Title) > 300 || utf8.RuneCountInString(value.Artist) > 300 {
		return fmt.Errorf("invalid listening metadata")
	}
	if state.File != nil {
		file := *state.File
		file.OwnerID = client.ID
		file.OwnerName = value.OwnerName
		if file.ID == "" || len(file.ID) > 128 || strings.TrimSpace(file.Name) == "" ||
			utf8.RuneCountInString(file.Name) > 300 || file.Size < 0 {
			return fmt.Errorf("invalid listening file")
		}
		if file.SHA256 != "" && (!hashPattern.MatchString(file.SHA256) || file.ProtocolVersion != 2) {
			return fmt.Errorf("invalid hash manifest")
		}
		if file.SHA256 != "" {
			if _, err := uuid.Parse(file.ID); err != nil {
				return fmt.Errorf("invalid publication UUID")
			}
		}
		h.mu.RLock()
		existing := h.files[file.ID]
		changedManifest := existing != nil && existing.SHA256 != "" &&
			(existing.SHA256 != file.SHA256 || existing.Size != file.Size)
		if h.transfers != nil {
			for _, g := range h.transfers.grants {
				if g.file.ID == file.ID && (g.file.SHA256 != file.SHA256 || g.file.Size != file.Size) {
					changedManifest = true
					break
				}
			}
		}
		h.mu.RUnlock()
		if existing != nil && existing.OwnerID != client.ID {
			return fmt.Errorf("listening file belongs to another client")
		}
		if changedManifest {
			return fmt.Errorf("publication manifest is immutable; use a new UUID")
		}
		value.File = &file
	}
	previous, exists := h.listening[client.ID]
	if exists {
		h.removeListeningFileLocked(previous.state)
	}
	if value.File != nil {
		h.mu.Lock()
		h.files[value.File.ID] = value.File
		h.mu.Unlock()
	}
	h.listening[client.ID] = listeningEntry{state: value, updated: now}
	h.mu.Lock()
	h.leases[client.ID] = now.Add(ListeningTTL)
	if value.File == nil {
		h.revokeLocked(client.ID)
		delete(h.current, client.ID)
	} else {
		h.current[client.ID] = value.File.ID
	}
	h.mu.Unlock()
	if !exists || !reflect.DeepEqual(previous.state, value) {
		h.broadcastListeningLocked()
		h.Broadcast(h.Snapshot())
	}
	return nil
}

func (h *Hub) ExpireListening(now time.Time) {
	h.listeningMu.Lock()
	defer h.listeningMu.Unlock()
	changed := false
	for id, entry := range h.listening {
		if entry.state.OfflineAt != nil {
			if now.Unix()-*entry.state.OfflineAt < 60 {
				continue
			}
			delete(h.listening, id)
			changed = true
		} else if now.Sub(entry.updated) >= ListeningTTL {
			h.mu.Lock()
			h.revokeLocked(id)
			delete(h.leases, id)
			delete(h.current, id)
			h.mu.Unlock()
			h.removeListeningFileLocked(entry.state)
			timestamp := now.Unix()
			entry.state.OfflineAt = &timestamp
			h.listening[id] = entry
			changed = true
		}

	}
	if changed {
		h.broadcastListeningLocked()
		h.Broadcast(h.Snapshot())
	}
}

func (h *Hub) DisconnectListening(client *Client, now time.Time) {
	h.listeningMu.Lock()
	defer h.listeningMu.Unlock()
	h.mu.Lock()
	if h.clients[client.ID] != client {
		h.mu.Unlock()
		return
	}

	delete(h.clients, client.ID)
	h.revokeLocked(client.ID)
	delete(h.leases, client.ID)
	delete(h.current, client.ID)
	client.Close()
	for id, file := range h.files {
		if file.OwnerID == client.ID {
			delete(h.files, id)
		}
	}
	h.mu.Unlock()
	if entry, exists := h.listening[client.ID]; exists {
		timestamp := now.Unix()
		entry.state.OfflineAt = &timestamp
		h.listening[client.ID] = entry
	}
	h.broadcastListeningLocked()
	h.Broadcast(h.Snapshot())
}

func (h *Hub) RefreshLease(client *Client, now time.Time) error {
	h.listeningMu.Lock()
	defer h.listeningMu.Unlock()
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.clients[client.ID] != client || !client.Verified {
		return fmt.Errorf("identity-required")
	}
	entry, exists := h.listening[client.ID]
	if !exists || entry.state.OfflineAt != nil || !now.Before(h.leases[client.ID]) {
		return fmt.Errorf("source-offline")
	}
	entry.updated = now
	h.listening[client.ID] = entry
	h.leases[client.ID] = now.Add(ListeningTTL)
	return nil
}

// RetireShare closes admission while a replacement manifest is being computed.
func (h *Hub) RetireShare(client *Client, fileID string) error {
	h.listeningMu.Lock()
	defer h.listeningMu.Unlock()
	h.mu.Lock()
	if h.clients[client.ID] != client {
		h.mu.Unlock()
		return fmt.Errorf("client is no longer registered")
	}

	if fileID == "" {
		h.mu.Unlock()
		return fmt.Errorf("missing fileId")
	}
	if f := h.files[fileID]; f != nil && f.OwnerID != client.ID {
		h.mu.Unlock()
		return fmt.Errorf("file belongs to another client")
	}
	entry, exists := h.listening[client.ID]
	if exists && entry.state.File != nil && entry.state.File.ID == fileID {
		entry.state.File = nil
		h.listening[client.ID] = entry
	}
	delete(h.files, fileID)
	if h.current[client.ID] == fileID {
		delete(h.current, client.ID)
	}
	h.mu.Unlock()
	h.broadcastListeningLocked()
	h.Broadcast(h.Snapshot())
	return nil
}

func (h *Hub) SourceUnavailable(client *Client, fileID string) error {
	h.listeningMu.Lock()
	defer h.listeningMu.Unlock()
	h.mu.Lock()
	if h.clients[client.ID] != client {
		h.mu.Unlock()
		return fmt.Errorf("client is no longer registered")
	}
	if fileID == "" {
		h.mu.Unlock()
		return fmt.Errorf("missing fileId")
	}
	if f := h.files[fileID]; f != nil && f.OwnerID != client.ID {
		h.mu.Unlock()
		return fmt.Errorf("file belongs to another client")
	}
	known := false
	if f := h.files[fileID]; f != nil && f.OwnerID == client.ID {
		known = true
	}
	contents := map[*relayContent]bool{}
	if h.transfers != nil {
		for _, g := range h.transfers.grants {
			if g.file.ID == fileID {
				if g.owner != client.ID {
					h.mu.Unlock()
					return fmt.Errorf("file belongs to another client")
				}
				known = true
				if g.content != nil {
					contents[g.content] = true
				}
			}
		}
		for _, v := range h.transfers.contents {
			if v.owner == client.ID && v.file.ID == fileID {
				known = true
				contents[v] = true
			}
		}
	}
	if !known {
		h.mu.Unlock()
		return nil
	}
	delete(h.files, fileID)
	if h.current[client.ID] == fileID {
		delete(h.current, client.ID)
	}
	if entry, exists := h.listening[client.ID]; exists && entry.state.File != nil && entry.state.File.ID == fileID {
		entry.state.File = nil
		h.listening[client.ID] = entry
	}
	if h.transfers != nil {
		for _, g := range h.transfers.grants {
			if g.owner == client.ID && g.file.ID == fileID {
				h.notifyRevokedLocked(g, "source-unavailable")
				h.releaseLocked(g, time.Now())
			}
		}
		for v := range contents {
			if v.refs != 0 {
				if !v.ready && !v.failed && v.file.ID == fileID {
					_ = client.Send(&model.WSMessage{Type: "transfer-revoked", TransferID: v.id, Error: "source-unavailable"})
					for _, remaining := range h.transfers.grants {
						if remaining.content == v {
							v.file = remaining.file
							break
						}
					}
					v.scheduled = false
				}
				continue
			}
			if !v.failed && v.scheduled && !v.ready {
				_ = client.Send(&model.WSMessage{Type: "transfer-revoked", TransferID: v.id, Error: "source-unavailable"})
			}
			v.failed = true
			v.cancel()
			v.idle = time.Now().Add(-h.transfers.config.IdleTTL)
		}
		h.scheduleLocked(client.ID, time.Now())
	}
	h.mu.Unlock()
	h.broadcastListeningLocked()
	h.Broadcast(h.Snapshot())
	return nil
}
