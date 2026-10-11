package hub

import (
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"webtrc-signaling/internal/model"
)

func TestManifestAndAdmissionLimits(t *testing.T) {
	data := []byte("file")
	h, owner, f, _ := transferFixture(t, data)
	for _, mutate := range []func(*model.FileMeta){
		func(f *model.FileMeta) { f.SHA256 = strings.ToUpper(f.SHA256) },
		func(f *model.FileMeta) { f.SHA256 = "short" },
		func(f *model.FileMeta) { f.ProtocolVersion = 1 },
		func(f *model.FileMeta) { f.ID = "../not-a-publication" },
	} {
		bad := f
		mutate(&bad)
		if err := h.UpdateListening(owner, &model.Listening{OwnerName: "Owner", Title: "Song", File: &bad}, time.Now()); err == nil {
			t.Fatal("bad manifest accepted")
		}
	}
	bad := f
	bad.Size++
	if err := h.UpdateListening(owner, &model.Listening{OwnerName: "Owner", Title: "Song", File: &bad}, time.Now()); err == nil {
		t.Fatal("mutable manifest accepted")
	}
	c := &Client{ID: "receiver", Verified: true}
	h.Register(c)
	request := func(file model.FileMeta) error {
		_, err := h.RequestTransfer(c, &model.WSMessage{RequestID: uuid.NewString(), To: owner.ID, FileID: file.ID}, time.Now())
		return err
	}
	big := f
	big.ID = uuid.NewString()
	big.Size = h.transfers.config.MaxFileSize + 1
	if err := h.UpdateListening(owner, &model.Listening{OwnerName: "Owner", Title: "Huge", File: &big}, time.Now()); err != nil {
		t.Fatal(err)
	}
	if err := request(big); err == nil || err.Error() != "file-too-large" {
		t.Fatal("file bound missing", err)
	}
	legacy := f
	legacy.ID = uuid.NewString()
	legacy.SHA256 = ""
	legacy.ProtocolVersion = 0
	_ = h.UpdateListening(owner, &model.Listening{OwnerName: "Owner", Title: "Legacy", File: &legacy}, time.Now())
	if err := request(legacy); err == nil || err.Error() != "manifest-required" {
		t.Fatal("missing hash accepted", err)
	}
	_ = h.UpdateListening(owner, &model.Listening{OwnerName: "Owner", Title: "Song", File: &f}, time.Now())
	h.transfers.config.MaxRecipientGrants = 1
	if err := request(f); err != nil {
		t.Fatal(err)
	}
	if err := request(f); err == nil || err.Error() != "full" {
		t.Fatal("recipient bound missing", err)
	}
	h.transfers.config.MaxRecipientGrants = 4
	h.transfers.config.MaxOwnerGrants = 1
	other := &Client{ID: "other", Verified: true}
	h.Register(other)
	if _, err := h.RequestTransfer(other, &model.WSMessage{RequestID: uuid.NewString(), To: owner.ID, FileID: f.ID}, time.Now()); err == nil || err.Error() != "full" {
		t.Fatal("owner bound missing", err)
	}
}

func TestRateAndUploadQueueLimits(t *testing.T) {
	c := &Client{ID: "rate"}
	now := time.Now()
	for i := 0; i < 30; i++ {
		if !c.AllowMessage(now) {
			t.Fatal("message denied before limit")
		}
	}
	if c.AllowMessage(now) || !c.AllowMessage(now.Add(time.Second)) {
		t.Fatal("message rate not bounded/reset")
	}
	h, owner, f, s := transferFixture(t, []byte("bounded"))
	_, _, v := relayGrant(t, h, owner, f)
	h.mu.Lock()
	v.httpRate = requestRate{start: time.Now(), count: 120}
	h.mu.Unlock()
	response, _ := gatewayRequest(t, s, "HEAD", "/v2/uploads/"+v.id, v.token, "", nil)
	if response.StatusCode != 429 || response.Header.Get("Retry-After") != "1" {
		t.Fatal("HTTP rate not bounded")
	}
	h.transfers.config.MaxPendingUploads = 1
	next := f
	next.ID = uuid.NewString()
	next.SHA256 = strings.Repeat("d", 64)
	_ = h.UpdateListening(owner, &model.Listening{OwnerName: "Owner", Title: "Queued", File: &next}, time.Now())
	receiver := &Client{ID: "queue", Verified: true}
	h.Register(receiver)
	if _, err := h.RequestTransfer(receiver, &model.WSMessage{RequestID: uuid.NewString(), To: owner.ID, FileID: next.ID}, time.Now()); err == nil || err.Error() != "busy" {
		t.Fatal("upload queue not bounded", err)
	}
}
