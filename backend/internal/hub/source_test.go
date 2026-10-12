package hub

import (
	"testing"
	"time"

	"github.com/google/uuid"
	"webtrc-signaling/internal/model"
)

func TestSourceUnavailableOnlyRevokesMatchingPublication(t *testing.T) {
	data := []byte("old content")
	h, owner, f, s := transferFixture(t, data)
	oldRecipient, oldGrant, oldContent := relayGrant(t, h, owner, f)
	uploadAll(t, s, oldContent, data)
	newFile := f
	newFile.ID = uuid.NewString()
	if err := h.UpdateListening(owner, &model.Listening{OwnerName: "Owner", Title: "New", File: &newFile}, time.Now()); err != nil {
		t.Fatal(err)
	}
	currentRecipient, currentGrant := requestGrant(t, h, owner, newFile, "current-recipient")
	intruder := &Client{ID: "intruder", Verified: true}
	h.Register(intruder)
	if err := h.SourceUnavailable(intruder, f.ID); err == nil {
		t.Fatal("intruder revoked source")
	}
	if err := h.SourceUnavailable(&Client{ID: owner.ID}, f.ID); err == nil {
		t.Fatal("stale source hook accepted")
	}
	if err := h.SourceUnavailable(owner, f.ID); err != nil {
		t.Fatal(err)
	}
	if h.files[newFile.ID] == nil || h.listening[owner.ID].state.File == nil {
		t.Fatal("current song withdrawn")
	}
	if h.transfers.grants[oldGrant.ID] != nil {
		t.Fatal("old grant retained")
	}
	if h.transfers.grants[currentGrant.ID] == nil {
		t.Fatal("current grant revoked")
	}
	if _, err := h.RequestTransfer(oldRecipient, &model.WSMessage{RequestID: uuid.NewString(), TransferID: oldGrant.ID, To: owner.ID, FileID: f.ID}, time.Now()); err == nil {
		t.Fatal("unavailable source resumed")
	}
	if _, err := h.RequestTransfer(currentRecipient, &model.WSMessage{RequestID: uuid.NewString(), TransferID: currentGrant.ID, To: owner.ID, FileID: newFile.ID}, time.Now()); err != nil {
		t.Fatal("different publication sharing same hash revoked", err)
	}
	response, body := gatewayRequest(t, s, "GET", "/v2/transfers/"+currentGrant.ID+"/download", currentGrant.Token, "", nil)
	if response.StatusCode != 200 || string(body) != string(data) {
		t.Fatal("shared verified bytes lost")
	}
	response, _ = gatewayRequest(t, s, "HEAD", "/v2/transfers/"+oldGrant.ID+"/download", oldGrant.Token, "", nil)
	if response.StatusCode != 403 {
		t.Fatal("old source still downloadable")
	}
}
