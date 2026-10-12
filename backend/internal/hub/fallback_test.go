package hub

import (
	"testing"
	"time"

	"github.com/google/uuid"
	"webtrc-signaling/internal/model"
)

func TestRelayUpgradePreservesGrantAndOldPublication(t *testing.T) {
	data := []byte("fallback after failed ICE")
	h, owner, f, s := transferFixture(t, data)
	c, g := requestGrant(t, h, owner, f, "p2p-receiver")
	next := f
	next.ID = uuid.NewString()
	if err := h.UpdateListening(owner, &model.Listening{OwnerName: "Owner", Title: "Next", File: &next}, time.Now()); err != nil {
		t.Fatal(err)
	}
	msg := &model.WSMessage{RequestID: uuid.NewString(), TransferID: g.ID, FileID: f.ID, To: owner.ID, Mode: "relay"}
	relay, err := h.RequestTransfer(c, msg, time.Now())
	if err != nil || relay.Mode != "relay" || relay.ID != g.ID || relay.Token != g.Token || relay.ExpiresAt != g.ExpiresAt ||
		relay.File.ID != f.ID {
		t.Fatalf("upgrade changed grant %+v %v", relay, err)
	}
	content := h.transfers.grants[g.ID].content
	again, err := h.RequestTransfer(c, msg, time.Now())
	if err != nil || again.ID != g.ID || content.refs != 1 || len(h.transfers.contents) != 1 {
		t.Fatal("upgrade not idempotent")
	}
	_, first := requestGrant(t, h, owner, next, "slot-one")
	_, second := requestGrant(t, h, owner, next, "slot-two")
	if first.Mode != "p2p" || second.Mode != "p2p" {
		t.Fatal("upgraded grant retained P2P slot")
	}
	uploadAll(t, s, content, data)
	response, body := gatewayRequest(t, s, "GET", "/v2/transfers/"+g.ID+"/download", g.Token, "", nil)
	if response.StatusCode != 200 || string(body) != string(data) {
		t.Fatal("fallback bytes wrong")
	}
	forced := &Client{ID: "forced", Verified: true}
	h.Register(forced)
	grant, err := h.RequestTransfer(forced, &model.WSMessage{RequestID: uuid.NewString(), FileID: next.ID, To: owner.ID, Mode: "relay"}, time.Now())
	if err != nil || grant.Mode != "relay" || h.transfers.grants[grant.ID].content != content {
		t.Fatal("explicit relay not deduplicated")
	}
}

func TestRelayUpgradeFailureLeavesP2PValid(t *testing.T) {
	h, owner, f, _ := transferFixture(t, []byte("capacity"))
	c, g := requestGrant(t, h, owner, f, "recipient")
	h.transfers.config.MaxCacheBytes = 1
	msg := &model.WSMessage{RequestID: uuid.NewString(), TransferID: g.ID, FileID: f.ID, To: owner.ID, Mode: "relay"}
	if _, err := h.RequestTransfer(c, msg, time.Now()); err == nil || err.Error() != "cache-full" {
		t.Fatal("fallback quota ignored")
	}
	original := h.transfers.grants[g.ID]
	if original.mode != "p2p" || original.generation != 1 || original.content != nil || !h.validGrantLocked(original, time.Now()) {
		t.Fatal("failed admission damaged original grant")
	}
}
