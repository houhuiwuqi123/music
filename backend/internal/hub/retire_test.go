package hub

import (
	"testing"
	"time"

	"github.com/google/uuid"
	"webtrc-signaling/internal/model"
)

func TestRetireStopsAdmissionWithoutRevokingExisting(t *testing.T) {
	data := []byte("retained source while hashing")
	h, owner, f, s := transferFixture(t, data)
	c, g, v := relayGrant(t, h, owner, f)
	uploadAll(t, s, v, data)
	other := &Client{ID: "intruder", Verified: true}
	h.Register(other)
	if err := h.RetireShare(other, f.ID); err == nil {
		t.Fatal("other owner retired publication")
	}
	if err := h.RetireShare(&Client{ID: owner.ID}, f.ID); err == nil {
		t.Fatal("stale socket retired share")
	}
	if err := h.RetireShare(owner, f.ID); err != nil {
		t.Fatal(err)
	}
	if err := h.RetireShare(owner, f.ID); err != nil {
		t.Fatal("retire retry not idempotent")
	}
	if h.files[f.ID] != nil || h.listening[owner.ID].state.File != nil || h.current[owner.ID] != "" {
		t.Fatal("retired file advertised")
	}
	now := time.Now()
	if !now.Before(h.leases[owner.ID]) || len(h.transfers.grants) != 3 {
		t.Fatal("retire revoked leases/grants")
	}
	msg := &model.WSMessage{RequestID: uuid.NewString(), FileID: f.ID, To: owner.ID}
	if _, err := h.RequestTransfer(other, msg, now); err == nil || err.Error() != "not-available" {
		t.Fatal("retired admission allowed")
	}
	msg.TransferID = g.ID
	if _, err := h.RequestTransfer(c, msg, now); err != nil {
		t.Fatal("retired grant renewal rejected", err)
	}
	response, body := gatewayRequest(t, s, "GET", "/v2/transfers/"+g.ID+"/download", g.Token, "", nil)
	if response.StatusCode != 200 || string(body) != string(data) {
		t.Fatal("retire aborted existing transfer")
	}
	next := f
	next.ID = uuid.NewString()
	if err := h.UpdateListening(owner, &model.Listening{OwnerName: "Owner", Title: "Next", File: &next}, now); err != nil {
		t.Fatal(err)
	}
	if _, err := h.RequestTransfer(c, msg, now); err != nil {
		t.Fatal("replacement revoked retired grant", err)
	}
	_ = h.UpdateListening(owner, nil, now)
	response, _ = gatewayRequest(t, s, "HEAD", "/v2/transfers/"+g.ID+"/download", g.Token, "", nil)
	if response.StatusCode != 403 {
		t.Fatal("privacy withdrawal did not revoke retired grant")
	}
}
