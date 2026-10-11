package hub

import (
	"testing"
	"time"

	"webtrc-signaling/internal/model"
)

func TestListeningExpiry(t *testing.T) {
	h := New()
	now := time.Now()
	h.listening["fresh"] = listeningEntry{state: model.Listening{ClientID: "fresh"}, updated: now}
	h.listening["stale"] = listeningEntry{state: model.Listening{ClientID: "stale", File: &model.FileMeta{ID: "song"}}, updated: now.Add(-ListeningTTL)}
	h.files["song"] = &model.FileMeta{ID: "song", OwnerID: "stale"}
	h.ExpireListening(now)
	list := h.listeningSnapshotLocked()
	if len(list) != 1 || list[0].ClientID != "fresh" {
		t.Fatalf("unexpected snapshot: %+v", list)
	}
	if len(h.files) != 0 {
		t.Fatal("expired automatic file retained")
	}
	h.ExpireListening(now.Add(ListeningTTL))
	if len(h.listeningSnapshotLocked()) != 0 {
		t.Fatal("expired state retained")
	}
}

func TestListeningRejectsInvalidMetadata(t *testing.T) {
	h := New()
	client := &Client{ID: "a"}
	h.Register(client)
	for _, state := range []model.Listening{
		{OwnerName: "visitor", Title: " "},
		{OwnerName: "", Title: "song"},
	} {
		if err := h.UpdateListening(client, &state, time.Now()); err == nil {
			t.Fatal("invalid metadata accepted")
		}
	}
	if len(h.listening) != 0 {
		t.Fatal("invalid metadata published")
	}
	if err := h.UpdateListening(&Client{ID: "a"}, nil, time.Now()); err == nil {
		t.Fatal("replaced client accepted")
	}
}

func TestListeningHeartbeatAndSorting(t *testing.T) {
	h := New()
	client := &Client{ID: "b"}
	h.Register(client)
	state := model.Listening{ClientID: "b", OwnerName: "visitor", Title: "song", IsPlaying: true, Region: "地区未知"}
	now := time.Now()
	h.listening["b"] = listeningEntry{state: state, updated: now.Add(-time.Minute)}
	state.ClientID = "spoofed"
	if err := h.UpdateListening(client, &state, now); err != nil {
		t.Fatal(err)
	}
	if h.listening["b"].state.ClientID != "b" || !h.listening["b"].updated.Equal(now) {
		t.Fatal("heartbeat/identity failed")
	}
	h.listening["a"] = listeningEntry{state: model.Listening{ClientID: "a"}, updated: now}
	if h.listeningSnapshotLocked()[0].ClientID != "a" {
		t.Fatal("snapshot order is unstable")
	}
}
