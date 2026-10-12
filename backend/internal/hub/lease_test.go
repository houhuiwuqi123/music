package hub

import (
	"reflect"
	"testing"
	"time"

	"github.com/google/uuid"
	"webtrc-signaling/internal/model"
)

func TestRetiredShareLeaseRefreshCannotResurrect(t *testing.T) {
	h, owner, f, _ := transferFixture(t, []byte("hashing duration"))
	c, g := requestGrant(t, h, owner, f, "recipient")
	if err := h.RetireShare(owner, f.ID); err != nil {
		t.Fatal(err)
	}
	before := h.listening[owner.ID].state
	base := time.Now()
	for i := 1; i <= 6; i++ {
		now := base.Add(time.Duration(i) * 30 * time.Second)
		if err := h.RefreshLease(owner, now); err != nil {
			t.Fatal(err)
		}
		h.ExpireListening(now)
		h.SweepTransfers(now)
		if !reflect.DeepEqual(before, h.listening[owner.ID].state) || h.files[f.ID] != nil || h.current[owner.ID] != "" {
			t.Fatal("lease refresh republished/changed retired state")
		}
		if _, err := h.RequestTransfer(c, &model.WSMessage{RequestID: uuid.NewString(), TransferID: g.ID, FileID: f.ID, To: owner.ID}, now); err != nil {
			t.Fatal("lease refresh lost grant", err)
		}
		other := &Client{ID: "new", Verified: true}
		h.Register(other)
		if _, err := h.RequestTransfer(other, &model.WSMessage{RequestID: uuid.NewString(), FileID: f.ID, To: owner.ID}, now); err == nil {
			t.Fatal("lease refresh reopened admission")
		}
	}
	if err := h.RefreshLease(&Client{ID: owner.ID, Verified: true}, base); err == nil {
		t.Fatal("stale refresh accepted")
	}
	expired := base.Add(10 * time.Minute)
	if err := h.RefreshLease(owner, expired); err == nil {
		t.Fatal("expired source resurrected")
	}
	h.ExpireListening(expired)
	if err := h.RefreshLease(owner, expired); err == nil {
		t.Fatal("offline listener resurrected")
	}
	_ = h.UpdateListening(owner, nil, base)
	if err := h.RefreshLease(owner, base); err == nil {
		t.Fatal("missing listener resurrected")
	}
}
