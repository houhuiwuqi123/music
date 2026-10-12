package hub

import (
	"testing"
	"time"

	"github.com/google/uuid"
	"webtrc-signaling/internal/model"
)

func TestCancelBeforeResponseAndBeforeRequest(t *testing.T) {
	h, owner, f, _ := transferFixture(t, []byte("cancel race"))
	c := &Client{ID: "cancel", Verified: true}
	h.Register(c)
	id := uuid.NewString()
	if err := h.CancelTransfer(c, id, ""); err != nil {
		t.Fatal(err)
	}
	msg := &model.WSMessage{RequestID: id, FileID: f.ID, To: owner.ID}
	if _, err := h.RequestTransfer(c, msg, time.Now()); err == nil || err.Error() != "request-canceled" {
		t.Fatal("delayed request allocated")
	}
	msg.RequestID = uuid.NewString()
	g, err := h.RequestTransfer(c, msg, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if err := h.CancelTransfer(c, msg.RequestID, ""); err != nil {
		t.Fatal(err)
	}
	if h.transfers.grants[g.ID] != nil {
		t.Fatal("cancel before response leaked grant")
	}
	if _, err := h.RequestTransfer(c, msg, time.Now()); err == nil {
		t.Fatal("retry resurrected canceled grant")
	}
	h.mu.Lock()
	h.canceledRequests[c.ID][id] = time.Now().Add(-time.Second)
	h.mu.Unlock()
	h.SweepTransfers(time.Now())
	if _, exists := h.canceledRequests[c.ID][id]; exists {
		t.Fatal("cancel tombstone leaked")
	}
}

func TestOwnerUploadErrorFreesQueueSlot(t *testing.T) {
	h, owner, f, s := transferFixture(t, []byte("upload failure"))
	_, oldGrant, v := relayGrant(t, h, owner, f)
	next := f
	next.ID = uuid.NewString()
	next.SHA256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	_ = h.UpdateListening(owner, &model.Listening{OwnerName: "Owner", Title: "Next", File: &next}, time.Now())
	_, nextGrant := requestGrant(t, h, owner, next, "queued")
	nextContent := h.transfers.grants[nextGrant.ID].content
	if nextContent.scheduled {
		t.Fatal("queue concurrency")
	}
	if err := h.UploadError(&Client{ID: owner.ID, Verified: true}, v.id); err == nil {
		t.Fatal("stale upload error accepted")
	}
	if err := h.UploadError(h.clients["queued"], v.id); err == nil {
		t.Fatal("recipient failed owner upload")
	}
	if err := h.UploadError(owner, v.id); err != nil {
		t.Fatal(err)
	}
	if h.transfers.grants[oldGrant.ID] != nil || !v.failed || !nextContent.scheduled {
		t.Fatal("upload failure did not release slot/grants")
	}
	response, _ := gatewayRequest(t, s, "HEAD", "/v2/uploads/"+v.id, v.token, "", nil)
	if response.StatusCode != 403 {
		t.Fatal("failed upload bearer still allowed")
	}
}
