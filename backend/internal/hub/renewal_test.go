package hub

import (
	"testing"
	"time"

	"github.com/google/uuid"
	"webtrc-signaling/internal/model"
)

func TestLongTransferRenewalOldSongStableBearerAndGeneration(t *testing.T) {
	h, owner, f, _ := transferFixture(t, []byte("long download"))
	c, g := requestGrant(t, h, owner, f, "long-recipient")
	initial := h.transfers.grants[g.ID]
	requestID := initial.requestID
	start := time.Now()
	next := f
	next.ID = uuid.NewString()
	if err := h.UpdateListening(owner, &model.Listening{OwnerName: "Owner", Title: "Next", File: &next}, start); err != nil {
		t.Fatal(err)
	}
	for minutes := 15; minutes <= 90; minutes += 15 {
		now := start.Add(time.Duration(minutes) * time.Minute)
		h.mu.Lock()
		h.leases[owner.ID] = now.Add(ListeningTTL)
		h.mu.Unlock()
		renewed, err := h.RequestTransfer(c, &model.WSMessage{RequestID: requestID, TransferID: g.ID, FileID: f.ID, To: owner.ID}, now)
		if err != nil || renewed.ID != g.ID || renewed.Token != g.Token || renewed.Generation != g.Generation ||
			renewed.ExpiresAt != now.Add(h.transfers.config.GrantTTL).Unix() || renewed.File.ID != f.ID {
			t.Fatalf("renewal minute %d: %+v %v", minutes, renewed, err)
		}
		h.SweepTransfers(now)
	}
	h.DisconnectListening(owner, time.Now())
	if _, err := h.RequestTransfer(c, &model.WSMessage{RequestID: requestID, TransferID: g.ID, FileID: f.ID, To: owner.ID}, time.Now()); err == nil {
		t.Fatal("revoked grant renewed")
	}
}

func TestUploadTokenLongLifetimeRenewal(t *testing.T) {
	h, owner, f, _ := transferFixture(t, []byte("long upload"))
	_, _, v := relayGrant(t, h, owner, f)
	oldExpires, token := v.expires, v.token
	if time.Until(oldExpires) < 90*time.Minute {
		t.Fatal("upload lifetime too short")
	}
	now := oldExpires.Add(-30 * time.Second)
	h.mu.Lock()
	h.leases[owner.ID] = now.Add(ListeningTTL)
	for _, g := range h.transfers.grants {
		g.expires = now.Add(h.transfers.config.GrantTTL)
	}
	h.mu.Unlock()
	h.SweepTransfers(now)
	if v.token != token || !v.expires.After(oldExpires) || !h.uploadAuthorizedLocked(v, now) {
		t.Fatal("upload renewal rotated bearer or expired online source")
	}
}
