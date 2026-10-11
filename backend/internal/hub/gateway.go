package hub

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"webtrc-signaling/internal/model"
)

func bearer(r *http.Request) string {
	value := r.Header.Get("Authorization")
	if !strings.HasPrefix(value, "Bearer ") {
		return ""
	}
	return strings.TrimPrefix(value, "Bearer ")
}

func (h *Hub) Gateway() http.Handler { return http.HandlerFunc(h.serveGateway) }

func (h *Hub) serveGateway(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/"), "/")
	if r.URL.RawPath != "" || len(parts) < 3 || parts[0] != "v2" {
		http.NotFound(w, r)
		return
	}
	h.mu.RLock()
	s := h.transfers
	h.mu.RUnlock()
	if s == nil {
		http.Error(w, "gateway-disabled", 503)
		return
	}
	select {
	case s.streams <- struct{}{}:
		defer func() { <-s.streams }()
	default:
		w.Header().Set("Retry-After", "1")
		http.Error(w, "busy", 503)
		return
	}
	if parts[1] == "uploads" && len(parts) == 3 {
		h.upload(w, r, parts[2])
		return
	}
	if parts[1] == "transfers" && len(parts) == 4 {
		h.download(w, r, parts[2], parts[3])
		return
	}
	http.NotFound(w, r)
}

func (h *Hub) uploadAuthorizedLocked(v *relayContent, now time.Time) bool {
	c := h.clients[v.owner]
	if v.failed || v.ctx.Err() != nil || v.refs <= 0 || !v.scheduled || c == nil || !c.Verified ||
		!now.Before(h.leases[v.owner]) {
		return false
	}
	for _, g := range h.transfers.grants {
		if g.content == v && h.validGrantLocked(g, now) {
			return true
		}
	}
	return false
}

// guard interrupts stalled socket I/O too, not just the next application read/write.
func (h *Hub) guard(w http.ResponseWriter, r *http.Request, parent context.Context, valid func() bool) (context.Context, context.CancelFunc) {
	ctx, cancel := context.WithCancel(r.Context())
	go func() {
		ticker := time.NewTicker(100 * time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-parent.Done():
				if ctx.Err() != nil {
					return
				}
				cancel()
			case <-ticker.C:
				if ctx.Err() != nil {
					return
				}
				if valid() {
					continue
				}
				cancel()
			}
			controller := http.NewResponseController(w)
			_ = controller.SetReadDeadline(time.Now())
			_ = controller.SetWriteDeadline(time.Now())
			return
		}
	}()
	return ctx, cancel
}

func (h *Hub) upload(w http.ResponseWriter, r *http.Request, id string) {
	if r.Method != http.MethodHead && r.Method != http.MethodPut {
		w.Header().Set("Allow", "HEAD, PUT")
		http.Error(w, "method-not-allowed", 405)
		return
	}
	h.mu.Lock()
	var v *relayContent
	for _, item := range h.transfers.contents {
		if item.id == id {
			v = item
			break
		}
	}
	if v == nil || !equalToken(bearer(r), v.token) || !h.uploadAuthorizedLocked(v, time.Now()) {
		h.mu.Unlock()
		http.Error(w, "unauthorized-or-revoked", 403)
		return
	}
	if !v.httpRate.allow(time.Now()) {
		h.mu.Unlock()
		w.Header().Set("Retry-After", "1")
		http.Error(w, "rate-limited", 429)
		return
	}
	h.mu.Unlock()
	v.mu.Lock()
	defer v.mu.Unlock()
	h.mu.Lock()
	valid := h.uploadAuthorizedLocked(v, time.Now())
	h.mu.Unlock()
	if !valid {
		http.Error(w, "unauthorized-or-revoked", 403)
		return
	}
	w.Header().Set("Upload-Offset", strconv.FormatInt(v.offset, 10))
	w.Header().Set("Upload-Length", strconv.FormatInt(v.size, 10))
	if r.Method == http.MethodHead {
		h.mu.RLock()
		ready := v.ready
		h.mu.RUnlock()
		if ready {
			w.Header().Set("Upload-Status", "ready")
		} else {
			w.Header().Set("Upload-Status", "waiting")
		}
		w.WriteHeader(200)
		return
	}
	start, end, total, err := parseContentRange(r.Header.Get("Content-Range"))
	if err != nil || total != v.size || end-start+1 > MaxChunk ||
		(r.ContentLength >= 0 && r.ContentLength != end-start+1) {
		http.Error(w, "invalid-content-range-or-chunk-size", 400)
		return
	}
	if start > v.offset || (start < v.offset && end >= v.offset) {
		http.Error(w, "offset-conflict", 409)
		return
	}
	ctx, cancel := h.guard(w, r, v.ctx, func() bool {
		h.mu.RLock()
		defer h.mu.RUnlock()
		return h.uploadAuthorizedLocked(v, time.Now())
	})
	defer cancel()
	data, err := io.ReadAll(io.LimitReader(r.Body, end-start+2))
	if err != nil || int64(len(data)) != end-start+1 {
		http.Error(w, "invalid-body-length", 400)
		return
	}
	if ctx.Err() != nil {
		http.Error(w, "revoked", 403)
		return
	}
	f, err := os.OpenFile(v.path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		http.Error(w, "cache-write-failed", 507)
		return
	}
	defer f.Close()
	if start < v.offset {
		old := make([]byte, len(data))
		if _, err := f.ReadAt(old, start); err != nil || !bytes.Equal(old, data) {
			http.Error(w, "retry-data-conflict", 409)
			return
		}
		w.WriteHeader(204)
		return
	}
	if err := h.pace(ctx, len(data)); err != nil {
		return
	}
	if _, err := f.WriteAt(data, start); err != nil {
		_ = f.Truncate(v.offset)
		http.Error(w, "cache-write-failed", 507)
		return
	}
	if err := f.Sync(); err != nil {
		_ = f.Truncate(v.offset)
		http.Error(w, "cache-sync-failed", 507)
		return
	}
	v.offset = end + 1
	w.Header().Set("Upload-Offset", strconv.FormatInt(v.offset, 10))
	if v.offset == v.size {
		if _, err := f.Seek(0, io.SeekStart); err != nil {
			http.Error(w, "cache-read-failed", 500)
			return
		}
		hash := sha256.New()
		buffer := make([]byte, 64<<10)
		for ctx.Err() == nil {
			n, readErr := f.Read(buffer)
			if n > 0 {
				_, _ = hash.Write(buffer[:n])
			}
			if readErr == io.EOF {
				break
			}
			if readErr != nil {
				http.Error(w, "cache-read-failed", 500)
				return
			}
		}
		if ctx.Err() != nil {
			return
		}
		if hex.EncodeToString(hash.Sum(nil)) != v.hash {
			cancel()
			h.failContent(v, "hash-mismatch")
			http.Error(w, "hash-mismatch", 422)
			return
		}
		h.mu.Lock()
		if h.uploadAuthorizedLocked(v, time.Now()) {
			v.ready = true
			for _, g := range h.transfers.grants {
				if g.content == v && h.validGrantLocked(g, time.Now()) {
					if c := h.clients[g.recipient]; c != nil {
						_ = c.Send(&model.WSMessage{Type: "transfer", Transfer: h.transferLocked(g)})
					}
				}
			}
			h.scheduleLocked(v.owner, time.Now())
		}
		ready := v.ready
		h.mu.Unlock()
		if !ready {
			http.Error(w, "revoked", 403)
			return
		}
		w.Header().Set("Upload-Status", "ready")
	}
	w.WriteHeader(204)
}

func (h *Hub) failContent(v *relayContent, reason string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	v.failed = true
	v.cancel()
	for _, g := range h.transfers.grants {
		if g.content == v {
			if c := h.clients[g.recipient]; c != nil {
				_ = c.Send(&model.WSMessage{Type: "transfer-error", TransferID: g.id, Error: reason})
			}
			h.releaseLocked(g, time.Now())
		}
	}
	v.idle = time.Now().Add(-h.transfers.config.IdleTTL)
	h.scheduleLocked(v.owner, time.Now())
}

func parseContentRange(value string) (int64, int64, int64, error) {
	var start, end, total int64
	if !strings.HasPrefix(value, "bytes ") {
		return 0, 0, 0, errors.New("invalid range")
	}
	parts := strings.Split(strings.TrimPrefix(value, "bytes "), "/")
	if len(parts) != 2 {
		return 0, 0, 0, errors.New("invalid range")
	}
	bounds := strings.Split(parts[0], "-")
	if len(bounds) != 2 {
		return 0, 0, 0, errors.New("invalid range")
	}
	var err error
	if start, err = strconv.ParseInt(bounds[0], 10, 64); err != nil {
		return 0, 0, 0, err
	}
	if end, err = strconv.ParseInt(bounds[1], 10, 64); err != nil {
		return 0, 0, 0, err
	}
	if total, err = strconv.ParseInt(parts[1], 10, 64); err != nil {
		return 0, 0, 0, err
	}
	if start < 0 || end < start || total <= 0 || end >= total {
		return 0, 0, 0, errors.New("invalid range")
	}
	return start, end, total, nil
}

func parseDownloadRange(value string, size int64) (int64, int64, error) {
	if value == "" {
		return 0, size - 1, nil
	}
	if !strings.HasPrefix(value, "bytes=") || strings.Contains(value, ",") {
		return 0, 0, errors.New("invalid range")
	}
	bounds := strings.Split(strings.TrimPrefix(value, "bytes="), "-")
	if len(bounds) != 2 {
		return 0, 0, errors.New("invalid range")
	}
	if bounds[0] == "" {
		n, err := strconv.ParseInt(bounds[1], 10, 64)
		if err != nil || n <= 0 {
			return 0, 0, errors.New("invalid suffix")
		}
		if n > size {
			n = size
		}
		return size - n, size - 1, nil
	}
	start, err := strconv.ParseInt(bounds[0], 10, 64)
	if err != nil || start < 0 || start >= size {
		return 0, 0, errors.New("invalid start")
	}
	end := size - 1
	if bounds[1] != "" {
		end, err = strconv.ParseInt(bounds[1], 10, 64)
		if err != nil || end < start {
			return 0, 0, errors.New("invalid end")
		}
		if end >= size {
			end = size - 1
		}
	}
	return start, end, nil
}

func (h *Hub) download(w http.ResponseWriter, r *http.Request, id, action string) {
	if (action == "download" && r.Method != http.MethodGet && r.Method != http.MethodHead) ||
		(action == "complete" && r.Method != http.MethodPost) {
		http.Error(w, "method-not-allowed", 405)
		return
	}
	if action != "download" && action != "complete" {
		http.NotFound(w, r)
		return
	}
	h.mu.Lock()
	g := h.transfers.grants[id]
	if g != nil && equalToken(bearer(r), g.token) && !g.httpRate.allow(time.Now()) {
		h.mu.Unlock()
		w.Header().Set("Retry-After", "1")
		http.Error(w, "rate-limited", 429)
		return
	}
	if action == "complete" && g != nil && g.completed && equalToken(bearer(r), g.token) &&
		time.Now().Before(g.expires) && time.Now().Before(h.leases[g.owner]) &&
		h.clients[g.owner] != nil && h.clients[g.recipient] != nil {
		h.mu.Unlock()
		w.WriteHeader(204)
		return
	}
	if g == nil || !equalToken(bearer(r), g.token) || !h.validGrantLocked(g, time.Now()) {
		h.mu.Unlock()
		http.Error(w, "unauthorized-or-revoked", 403)
		return
	}
	if action == "complete" {
		// Keep a canceled, bounded tombstone so bearer retries are idempotent until expiry.
		h.notifyRevokedLocked(g,"released")
		g.cancel()
		g.completed = true
		if g.content != nil {
			g.content.refs--
			if g.content.refs == 0 {
				g.content.idle = time.Now()
				if !g.content.ready {
					g.content.failed = true
					g.content.cancel()
					g.content.idle = time.Now().Add(-h.transfers.config.IdleTTL)
				}
			}
			g.content = nil
		}
		h.scheduleLocked(g.owner, time.Now())
		h.mu.Unlock()
		w.WriteHeader(204)
		return
	}
	if g.mode != "relay" {
		h.mu.Unlock()
		http.Error(w, "p2p-only", 409)
		return
	}
	if !g.content.ready {
		h.mu.Unlock()
		w.Header().Set("Retry-After", "1")
		http.Error(w, "waiting", 425)
		return
	}
	v := g.content
	h.mu.Unlock()
	etag := `"` + g.file.SHA256 + `"`
	w.Header().Set("ETag", etag)
	w.Header().Set("Accept-Ranges", "bytes")
	w.Header().Set("Content-Type", "application/octet-stream")
	rangeHeader := r.Header.Get("Range")
	if value := r.Header.Get("If-Range"); value != "" && value != etag {
		rangeHeader = ""
	}
	start, end, err := parseDownloadRange(rangeHeader, g.file.Size)
	if err != nil {
		w.Header().Set("Content-Range", fmt.Sprintf("bytes */%d", g.file.Size))
		w.WriteHeader(416)
		return
	}
	f, err := os.Open(v.path)
	if err != nil {
		http.Error(w, "cache-unavailable", 503)
		return
	}
	defer f.Close()
	if _, err := f.Seek(start, io.SeekStart); err != nil {
		http.Error(w, "cache-read-failed", 500)
		return
	}
	ctx, cancel := h.guard(w, r, g.ctx, func() bool {
		h.mu.RLock()
		defer h.mu.RUnlock()
		return h.validGrantLocked(g, time.Now())
	})
	defer cancel()
	w.Header().Set("Content-Length", strconv.FormatInt(end-start+1, 10))
	status := 200
	if rangeHeader != "" {
		status = 206
		w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, end, g.file.Size))
	}
	w.WriteHeader(status)
	if r.Method == http.MethodHead {
		return
	}
	buffer := make([]byte, 64<<10)
	remaining := end - start + 1
	for remaining > 0 {
		if ctx.Err() != nil {
			return
		}
		n, err := f.Read(buffer[:min(int64(len(buffer)), remaining)])
		if n > 0 {
			if h.pace(ctx, n) != nil {
				return
			}
			h.mu.RLock()
			valid := h.validGrantLocked(g, time.Now())
			h.mu.RUnlock()
			if !valid {
				return
			}
			if _, writeErr := w.Write(buffer[:n]); writeErr != nil {
				return
			}
			remaining -= int64(n)
		}
		if err != nil {
			return
		}
	}
}

func (h *Hub) pace(ctx context.Context, n int) error {
	s := h.transfers
	s.rateMu.Lock()
	now := time.Now()
	if s.nextWrite.Before(now) {
		s.nextWrite = now
	}
	delay := s.nextWrite.Sub(now)
	s.nextWrite = s.nextWrite.Add(time.Duration(n) * time.Second / time.Duration(s.config.BytesPerSecond))
	s.rateMu.Unlock()
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}
