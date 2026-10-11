package hub

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha1"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"webtrc-signaling/internal/model"
)

func testDirectory(t *testing.T) string {
	t.Helper()
	dir := filepath.Join(".test-artifacts", uuid.NewString())
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := os.RemoveAll(dir); err != nil {
			t.Error(err)
		}
		_ = os.Remove(".test-artifacts")
	})
	return dir
}

func transferFixture(t *testing.T, data []byte) (*Hub, *Client, model.FileMeta, *httptest.Server) {
	t.Helper()
	h := New()
	cfg := DefaultTransferConfig(testDirectory(t), "https://gateway.example")
	cfg.BytesPerSecond = 1 << 30
	if err := h.EnableTransfers(cfg); err != nil {
		t.Fatal(err)
	}
	owner := &Client{ID: "owner", Verified: true}
	h.Register(owner)
	hash := sha256.Sum256(data)
	f := model.FileMeta{ID: uuid.NewString(), Name: "../../outside.mp3", Size: int64(len(data)), SHA256: hex.EncodeToString(hash[:]), ProtocolVersion: 2}
	if err := h.UpdateListening(owner, &model.Listening{OwnerName: "Owner", Title: "Song", File: &f}, time.Now()); err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(h.Gateway())
	t.Cleanup(server.Close)
	return h, owner, f, server
}

func requestGrant(t *testing.T, h *Hub, owner *Client, f model.FileMeta, id string) (*Client, *model.Transfer) {
	t.Helper()
	c := &Client{ID: id, Verified: true}
	h.Register(c)
	g, err := h.RequestTransfer(c, &model.WSMessage{RequestID: uuid.NewString(), FileID: f.ID, To: owner.ID}, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	return c, g
}

func relayGrant(t *testing.T, h *Hub, owner *Client, f model.FileMeta) (*Client, *model.Transfer, *relayContent) {
	t.Helper()
	requestGrant(t, h, owner, f, "p2p-one")
	requestGrant(t, h, owner, f, "p2p-two")
	c, g := requestGrant(t, h, owner, f, "relay-recipient")
	h.mu.RLock()
	content := h.transfers.grants[g.ID].content
	h.mu.RUnlock()
	if g.Mode != "relay" || content == nil {
		t.Fatal("relay not selected")
	}
	return c, g, content
}

func gatewayRequest(t *testing.T, s *httptest.Server, method, path, token, contentRange string, data []byte) (*http.Response, []byte) {
	t.Helper()
	req, err := http.NewRequest(method, s.URL+path, bytes.NewReader(data))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer "+token)
	if contentRange != "" {
		if method == "PUT" {
			req.Header.Set("Content-Range", contentRange)
		} else {
			req.Header.Set("Range", contentRange)
		}
	}
	response, err := s.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	body, err := io.ReadAll(response.Body)
	response.Body.Close()
	if err != nil {
		t.Fatal(err)
	}
	return response, body
}

func uploadAll(t *testing.T, s *httptest.Server, v *relayContent, data []byte) {
	t.Helper()
	for start := 0; start < len(data); start += MaxChunk {
		end := min(start+MaxChunk, len(data)) - 1
		response, body := gatewayRequest(t, s, "PUT", "/v2/uploads/"+v.id, v.token,
			fmt.Sprintf("bytes %d-%d/%d", start, end, len(data)), data[start:end+1])
		if response.StatusCode != 204 {
			t.Fatalf("upload: %d %s", response.StatusCode, body)
		}
	}
}

func TestTransferOwnershipIdentityAndSignals(t *testing.T) {
	h, owner, f, _ := transferFixture(t, []byte("original song"))
	c, g := requestGrant(t, h, owner, f, "recipient")
	if g.Mode != "p2p" || g.Generation != 1 {
		t.Fatal(g)
	}
	message := &model.WSMessage{RequestID: uuid.NewString(), FileID: f.ID, To: owner.ID, TransferID: g.ID}
	other := &Client{ID: "other", Verified: true}
	h.Register(other)
	if _, err := h.RequestTransfer(other, message, time.Now()); err == nil {
		t.Fatal("grant stolen")
	}
	if err := h.ReleaseTransfer(other, g.ID); err == nil {
		t.Fatal("grant canceled by other")
	}
	if _, err := h.RequestTransfer(&Client{ID: c.ID, Verified: true}, message, time.Now()); err == nil {
		t.Fatal("stale socket accepted")
	}
	legacy := &Client{ID: "legacy"}
	h.Register(legacy)
	if _, err := h.RequestTransfer(legacy, &model.WSMessage{RequestID: uuid.NewString(), FileID: f.ID, To: owner.ID}, time.Now()); err == nil {
		t.Fatal("legacy grant")
	}
	inner, _ := json.Marshal(map[string]any{"transferId": g.ID, "fileId": f.ID, "generation": 1, "kind": "offer", "sdp": "unchanged"})
	data, _ := json.Marshal(string(inner))
	signal := &model.WSMessage{To: owner.ID, TransferID: g.ID, Generation: 1, Data: data}
	if !h.RelaySignal(c, signal) {
		t.Fatal("authorized signal rejected")
	}
	signal.Generation = 2
	if h.RelaySignal(c, signal) {
		t.Fatal("wrong envelope generation")
	}
	signal.Generation = 1
	signal.To = other.ID
	if h.RelaySignal(c, signal) {
		t.Fatal("signal target spoofed")
	}
	signal.To = owner.ID
	if h.RelaySignal(other, signal) {
		t.Fatal("signal sender spoofed")
	}
	signal.Data = inner
	if h.RelaySignal(c, signal) {
		t.Fatal("non-string signal accepted")
	}
	resumed, err := h.RequestTransfer(c, message, time.Now())
	if err != nil || resumed.Generation != 2 {
		t.Fatalf("resume: %+v %v", resumed, err)
	}
	again, err := h.RequestTransfer(c, message, time.Now())
	if err != nil || again.Generation != 2 {
		t.Fatal("resume not idempotent")
	}
	signal.Data = data
	if h.RelaySignal(c, signal) {
		t.Fatal("old signal generation accepted")
	}
	if err := h.UnpublishClient(other, f.ID); err == nil {
		t.Fatal("unpublish ownership missing")
	}
	if err := h.PublishClient(other, &model.FileMeta{ID: f.ID}); err == nil {
		t.Fatal("publish ownership missing")
	}
}

func TestCutSongRetainsGrantOptOutAndDisconnectRevoke(t *testing.T) {
	for _, action := range []string{"opt-out", "no-file", "disconnect", "heartbeat", "replace"} {
		t.Run(action, func(t *testing.T) {
			data := []byte("bytes kept for authorized old song")
			h, owner, f, s := transferFixture(t, data)
			c, g, v := relayGrant(t, h, owner, f)
			uploadAll(t, s, v, data)
			newFile := f
			newFile.ID = uuid.NewString()
			if err := h.UpdateListening(owner, &model.Listening{OwnerName: "Owner", Title: "New", File: &newFile}, time.Now()); err != nil {
				t.Fatal(err)
			}
			resumed, err := h.RequestTransfer(c, &model.WSMessage{RequestID: uuid.NewString(), FileID: f.ID, To: owner.ID, TransferID: g.ID}, time.Now())
			if err != nil || resumed.File.ID != f.ID {
				t.Fatal("cut revoked existing grant", err)
			}
			newRecipient := &Client{ID: "new", Verified: true}
			h.Register(newRecipient)
			if _, err := h.RequestTransfer(newRecipient, &model.WSMessage{RequestID: uuid.NewString(), FileID: f.ID, To: owner.ID}, time.Now()); err == nil {
				t.Fatal("old file admitted")
			}
			path := "/v2/transfers/" + g.ID + "/download"
			response, body := gatewayRequest(t, s, "GET", path, g.Token, "", nil)
			if response.StatusCode != 200 || !bytes.Equal(body, data) {
				t.Fatal("old transfer no longer readable")
			}
			switch action {
			case "opt-out":
				_ = h.UpdateListening(owner, nil, time.Now())
			case "no-file":
				_ = h.UpdateListening(owner, &model.Listening{OwnerName: "Owner", Title: "Song"}, time.Now())
			case "disconnect":
				h.DisconnectListening(owner, time.Now())
			case "heartbeat":
				h.ExpireListening(time.Now().Add(ListeningTTL))
			case "replace":
				h.Register(&Client{ID: owner.ID, Verified: true})
			}
			response, _ = gatewayRequest(t, s, "GET", path, g.Token, "", nil)
			if response.StatusCode != 403 {
				t.Fatal("revoked download allowed", response.StatusCode)
			}
			if _, err := h.RequestTransfer(c, &model.WSMessage{RequestID: uuid.NewString(), FileID: f.ID, To: owner.ID, TransferID: g.ID}, time.Now()); err == nil {
				t.Fatal("revoked grant resumed")
			}
		})
	}
}

func TestUploadResumeRangesHashAndQuota(t *testing.T) {
	data := bytes.Repeat([]byte("bounded chunk content"), 100000)
	h, owner, f, s := transferFixture(t, data)
	c, g, v := relayGrant(t, h, owner, f)
	uploadPath := "/v2/uploads/" + v.id
	downloadPath := "/v2/transfers/" + g.ID + "/download"
	response, _ := gatewayRequest(t, s, "HEAD", downloadPath, g.Token, "", nil)
	if response.StatusCode != 425 {
		t.Fatal("waiting not explicit")
	}
	response, _ = gatewayRequest(t, s, "HEAD", uploadPath, v.token, "", nil)
	if response.Header.Get("Upload-Offset") != "0" {
		t.Fatal("initial offset")
	}
	part := data[:MaxChunk]
	cr := fmt.Sprintf("bytes 0-%d/%d", len(part)-1, len(data))
	response, _ = gatewayRequest(t, s, "PUT", uploadPath, v.token, cr, part)
	if response.StatusCode != 204 || response.Header.Get("Upload-Offset") != fmt.Sprint(MaxChunk) {
		t.Fatal("durable prefix", response.StatusCode)
	}
	response, _ = gatewayRequest(t, s, "PUT", uploadPath, v.token, cr, part)
	if response.StatusCode != 204 || v.offset != MaxChunk {
		t.Fatal("retry not idempotent")
	}
	bad := bytes.Clone(part)
	bad[0] ^= 1
	response, _ = gatewayRequest(t, s, "PUT", uploadPath, v.token, cr, bad)
	if response.StatusCode != 409 {
		t.Fatal("conflicting retry accepted")
	}
	response, _ = gatewayRequest(t, s, "PUT", uploadPath, v.token, fmt.Sprintf("bytes %d-%d/%d", MaxChunk+10, MaxChunk+10, len(data)), []byte{1})
	if response.StatusCode != 409 {
		t.Fatal("offset gap accepted")
	}
	response, _ = gatewayRequest(t, s, "PUT", uploadPath, v.token, fmt.Sprintf("bytes 0-%d/%d", MaxChunk, len(data)), data[:MaxChunk+1])
	if response.StatusCode != 400 {
		t.Fatal("oversize chunk accepted")
	}
	uploadAll(t, s, v, data)
	response, body := gatewayRequest(t, s, "GET", downloadPath, g.Token, "bytes=11-999", nil)
	if response.StatusCode != 206 || !bytes.Equal(body, data[11:1000]) ||
		response.Header.Get("ETag") != `"`+f.SHA256+`"` {
		t.Fatal("range incorrect")
	}
	response, body = gatewayRequest(t, s, "GET", downloadPath, g.Token, "bytes=-15", nil)
	if response.StatusCode != 206 || !bytes.Equal(body, data[len(data)-15:]) {
		t.Fatal("suffix range")
	}
	response, _ = gatewayRequest(t, s, "HEAD", downloadPath, g.Token, "bytes=99999999-", nil)
	if response.StatusCode != 416 || response.Header.Get("Content-Range") != fmt.Sprintf("bytes */%d", len(data)) {
		t.Fatal("416 range")
	}
	response, _ = gatewayRequest(t, s, "GET", downloadPath, v.token, "", nil)
	if response.StatusCode != 403 {
		t.Fatal("upload token used to download")
	}
	response, _ = gatewayRequest(t, s, "HEAD", "/v2/uploads/..%2f..%2foutside.mp3", v.token, "", nil)
	if response.StatusCode != 404 {
		t.Fatal("encoded traversal accepted", response.StatusCode)
	}
	entries, _ := os.ReadDir(h.transfers.config.CacheDir)
	if len(entries) != 1 || !artifactPattern.MatchString(entries[0].Name()) {
		t.Fatal("filename trusted")
	}
	response, _ = gatewayRequest(t, s, "POST", "/v2/transfers/"+g.ID+"/complete", g.Token, "", nil)
	if response.StatusCode != 204 {
		t.Fatal("complete failed")
	}
	h.SweepTransfers(time.Now())
	response, _ = gatewayRequest(t, s, "POST", "/v2/transfers/"+g.ID+"/complete", g.Token, "", nil)
	if response.StatusCode != 204 {
		t.Fatal("complete retry failed")
	}
	if err := h.ReleaseTransfer(c, g.ID); err != nil {
		t.Fatal(err)
	}
}

func TestHashMismatchAdmissionAndCleanup(t *testing.T) {
	data := []byte("original")
	h, owner, f, s := transferFixture(t, data)
	_, g, v := relayGrant(t, h, owner, f)
	response, _ := gatewayRequest(t, s, "PUT", "/v2/uploads/"+v.id, v.token, "bytes 0-7/8", []byte("modified"))
	if response.StatusCode != 422 {
		t.Fatal("hash mismatch not rejected", response.StatusCode)
	}
	response, _ = gatewayRequest(t, s, "GET", "/v2/transfers/"+g.ID+"/download", g.Token, "", nil)
	if response.StatusCode != 403 {
		t.Fatal("corrupt file served")
	}
	h.SweepTransfers(time.Now().Add(time.Second))
	if h.transfers.reserved != 0 || len(h.transfers.contents) != 0 {
		t.Fatal("failed cache leaked")
	}
	_, _, v = relayGrant(t, h, owner, f)
	h.transfers.config.MaxCacheBytes = int64(len(data))
	newFile := f
	newFile.ID = uuid.NewString()
	newFile.SHA256 = strings.Repeat("a", 64)
	_ = h.UpdateListening(owner, &model.Listening{OwnerName: "Owner", Title: "Next", File: &newFile}, time.Now())
	c := &Client{ID: "quota-recipient", Verified: true}
	h.Register(c)
	if _, err := h.RequestTransfer(c, &model.WSMessage{RequestID: uuid.NewString(), FileID: newFile.ID, To: owner.ID}, time.Now()); err == nil || err.Error() != "cache-full" {
		t.Fatal("quota not enforced", err)
	}
	h.transfers.config.MaxGrants = len(h.transfers.grants)
	if _, err := h.RequestTransfer(c, &model.WSMessage{RequestID: uuid.NewString(), FileID: newFile.ID, To: owner.ID}, time.Now()); err == nil || err.Error() != "full" {
		t.Fatal("grant limit not enforced", err)
	}
	_ = h.UpdateListening(owner, nil, time.Now())
	h.SweepTransfers(time.Now().Add(time.Second))
	if _, err := os.Stat(v.path); !os.IsNotExist(err) {
		t.Fatal("revoked artifact kept")
	}
}

func TestHundredConcurrentRecipientsSinglePhysicalUpload(t *testing.T) {
	data := bytes.Repeat([]byte("verified hot music"), 10000)
	h, owner, f, s := transferFixture(t, data)
	requestGrant(t, h, owner, f, "p2p-one")
	requestGrant(t, h, owner, f, "p2p-two")
	const recipients = 100
	grants := make([]*model.Transfer, recipients)
	var wg sync.WaitGroup
	for i := 0; i < recipients; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			_, grants[i] = requestGrant(t, h, owner, f, fmt.Sprint("download-", i))
		}(i)
	}
	wg.Wait()
	if len(h.transfers.contents) != 1 {
		t.Fatal("upload not deduplicated")
	}
	var v *relayContent
	for _, value := range h.transfers.contents {
		v = value
	}
	if v.refs != recipients || !v.scheduled {
		t.Fatal("deduplicated reference count")
	}
	uploadAll(t, s, v, data)
	errors := make(chan error, recipients)
	for _, g := range grants {
		wg.Add(1)
		go func(g *model.Transfer) {
			defer wg.Done()
			req, _ := http.NewRequest("GET", s.URL+"/v2/transfers/"+g.ID+"/download", nil)
			req.Header.Set("Authorization", "Bearer "+g.Token)
			response, err := s.Client().Do(req)
			if err != nil {
				errors <- err
				return
			}
			body, err := io.ReadAll(response.Body)
			response.Body.Close()
			hash := sha256.Sum256(body)
			if err != nil || response.StatusCode != 200 || hex.EncodeToString(hash[:]) != f.SHA256 || !bytes.Equal(data, body) {
				errors <- fmt.Errorf("recipient %s: status=%d error=%v", g.ID, response.StatusCode, err)
			}
		}(g)
	}
	wg.Wait()
	close(errors)
	for err := range errors {
		t.Error(err)
	}
	if v.offset != int64(len(data)) || len(h.transfers.contents) != 1 {
		t.Fatal("source uploaded more than once")
	}
	entries, _ := os.ReadDir(h.transfers.config.CacheDir)
	if len(entries) != 1 {
		t.Fatal("multiple physical artifacts")
	}
	if err := h.ReleaseTransfer(h.clients[grants[0].File.OwnerID], grants[0].ID); err == nil {
		t.Fatal("owner completed receiver grant")
	}
	first := h.transfers.grants[grants[0].ID]
	if err := h.ReleaseTransfer(h.clients[first.recipient], first.id); err != nil {
		t.Fatal(err)
	}
	h.mu.Lock()
	h.leases[owner.ID] = time.Now().Add(12 * time.Minute)
	h.mu.Unlock()
	h.SweepTransfers(time.Now().Add(11 * time.Minute))
	if _, err := os.Stat(v.path); err != nil {
		t.Fatal("cache deleted with other active grants", err)
	}
}

func TestIdentityPersistenceAndTURN(t *testing.T) {
	dir := testDirectory(t)
	path := filepath.Join(dir, "identities.json")
	s, err := OpenIdentityStore(path)
	if err != nil {
		t.Fatal(err)
	}
	secret := uuid.NewString()
	if verified, err := s.Authenticate("owner", secret); err != nil || !verified {
		t.Fatal(err)
	}
	s, err = OpenIdentityStore(path)
	if err != nil {
		t.Fatal(err)
	}
	if verified, err := s.Authenticate("owner", secret); err != nil || !verified {
		t.Fatal("identity not persisted")
	}
	for _, bad := range []string{"", uuid.NewString(), "not uuid"} {
		if _, err := s.Authenticate("owner", bad); err == nil {
			t.Fatal("identity impersonated")
		}
	}
	if verified, err := s.Authenticate("legacy", ""); err != nil || verified {
		t.Fatal("legacy compatibility")
	}
	disk, _ := os.ReadFile(path)
	if bytes.Contains(disk, []byte(secret)) {
		t.Fatal("plaintext secret persisted")
	}
	now := time.Unix(100000, 0)
	ice := ICEConfig("owner", now, []string{"turn:example:3478"}, "environment-secret")
	if len(ice) != 2 || ice[1].Username != "100600:owner" {
		t.Fatal("TURN expiration")
	}
	mac := hmac.New(sha1.New, []byte("environment-secret"))
	_, _ = mac.Write([]byte(ice[1].Username))
	if ice[1].Credential != base64.StdEncoding.EncodeToString(mac.Sum(nil)) {
		t.Fatal("TURN HMAC")
	}
	if len(ICEConfig("owner", now, []string{"turn:example"}, "")) != 1 {
		t.Fatal("TURN secret optional")
	}
}

func TestRestartDeletesOnlyExactArtifacts(t *testing.T) {
	dir := testDirectory(t)
	artifact := "relay-" + uuid.NewString() + ".part"
	for _, name := range []string{artifact, "unrelated.mp3", "relay-not-a-uuid.part"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("data"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	h := New()
	if err := h.EnableTransfers(DefaultTransferConfig(dir, "https://example")); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dir, artifact)); !os.IsNotExist(err) {
		t.Fatal("restart retained content")
	}
	for _, name := range []string{"unrelated.mp3", "relay-not-a-uuid.part"} {
		if _, err := os.Stat(filepath.Join(dir, name)); err != nil {
			t.Fatal("restart deleted unrelated artifact")
		}
	}
}

func TestStreamingRevocationAndLeaseTimer(t *testing.T) {
	for _, action := range []string{"opt-out", "lease", "cancel"} {
		t.Run(action, func(t *testing.T) {
			data := bytes.Repeat([]byte("stream bytes"), 50000)
			h, owner, f, s := transferFixture(t, data)
			c, g, v := relayGrant(t, h, owner, f)
			uploadAll(t, s, v, data)
			h.transfers.config.BytesPerSecond = 64 << 10
			h.transfers.nextWrite = time.Time{}
			if action == "lease" {
				h.mu.Lock()
				h.leases[owner.ID] = time.Now().Add(150 * time.Millisecond)
				h.mu.Unlock()
			}
			req, _ := http.NewRequest("GET", s.URL+"/v2/transfers/"+g.ID+"/download", nil)
			req.Header.Set("Authorization", "Bearer "+g.Token)
			response, err := s.Client().Do(req)
			if err != nil {
				t.Fatal(err)
			}
			first := make([]byte, 1024)
			if _, err := io.ReadFull(response.Body, first); err != nil {
				t.Fatal(err)
			}
			start := time.Now()
			switch action {
			case "opt-out":
				_ = h.UpdateListening(owner, nil, time.Now())
			case "cancel":
				_ = h.ReleaseTransfer(c, g.ID)
			}
			done := make(chan struct{})
			var remaining []byte
			go func() { remaining, _ = io.ReadAll(response.Body); response.Body.Close(); close(done) }()
			select {
			case <-done:
			case <-time.After(2 * time.Second):
				response.Body.Close()
				t.Fatal("stream not canceled promptly")
			}
			if len(remaining)+len(first) >= len(data) || time.Since(start) > time.Second {
				t.Fatal("revoked stream finished or lease timer slow")
			}
		})
	}
}

func TestOwnerUploadConcurrencyAndIdleCleanup(t *testing.T) {
	data := []byte("one owner upload")
	h, owner, f, s := transferFixture(t, data)
	_, g, v := relayGrant(t, h, owner, f)
	next := f
	next.ID = uuid.NewString()
	next.SHA256 = strings.Repeat("b", 64)
	if err := h.UpdateListening(owner, &model.Listening{OwnerName: "Owner", Title: "Other", File: &next}, time.Now()); err != nil {
		t.Fatal(err)
	}
	_, nextGrant := requestGrant(t, h, owner, next, "next-recipient")
	nextContent := h.transfers.grants[nextGrant.ID].content
	if nextContent == nil || nextContent.scheduled {
		t.Fatal("two simultaneous source uploads")
	}
	response, _ := gatewayRequest(t, s, "HEAD", "/v2/uploads/"+nextContent.id, nextContent.token, "", nil)
	if response.StatusCode != 403 {
		t.Fatal("unscheduled owner upload accepted")
	}
	uploadAll(t, s, v, data)
	if !nextContent.scheduled {
		t.Fatal("next content not scheduled")
	}
	g1 := h.transfers.grants[g.ID]
	if err := h.ReleaseTransfer(h.clients[g1.recipient], g.ID); err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	h.mu.Lock()
	h.leases[owner.ID] = now.Add(12 * time.Minute)
	h.mu.Unlock()
	h.SweepTransfers(now.Add(9 * time.Minute))
	if _, err := os.Stat(v.path); err != nil {
		t.Fatal("idle cache expired early")
	}
	h.SweepTransfers(now.Add(11 * time.Minute))
	if _, err := os.Stat(v.path); !os.IsNotExist(err) {
		t.Fatal("idle cache not cleaned")
	}
}
