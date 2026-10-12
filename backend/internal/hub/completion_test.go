package hub

import (
	"bytes"
	"io"
	"net/http"
	"testing"
)

func TestIfMatchAndCompletion(t *testing.T) {
	data := []byte("verified content")
	h, owner, f, s := transferFixture(t, data)
	c, g, v := relayGrant(t, h, owner, f)
	uploadAll(t, s, v, data)
	for _, value := range []string{`"wrong"`, `W/"` + f.SHA256 + `"`, `"` + f.SHA256 + `"`, "*"} {
		req, _ := http.NewRequest("GET", s.URL+"/v2/transfers/"+g.ID+"/download", nil)
		req.Header.Set("Authorization", "Bearer "+g.Token)
		req.Header.Set("If-Match", value)
		req.Header.Set("Range", "bytes=0-3")
		response, err := s.Client().Do(req)
		if err != nil {
			t.Fatal(err)
		}
		body, err := io.ReadAll(response.Body)
		response.Body.Close()
		if err != nil {
			t.Fatal(err)
		}
		if value == `"wrong"` || value == `W/"`+f.SHA256+`"` {
			if response.StatusCode != 412 {
				t.Fatal("If-Match mismatch not rejected")
			}
		} else if response.StatusCode != 206 || !bytes.Equal(body, data[:4]) {
			t.Fatal("If-Match correct range rejected")
		}
	}
	if err := h.CompleteTransfer(c, g.ID); err != nil {
		t.Fatal(err)
	}
	if err := h.CompleteTransfer(c, g.ID); err != nil {
		t.Fatal("completion not idempotent")
	}
	if h.transfers.grants[g.ID] != nil {
		t.Fatal("completed grant active")
	}
	if err := h.CompleteTransfer(&Client{ID: c.ID}, g.ID); err == nil {
		t.Fatal("stale client completion allowed")
	}
	if h.Active(owner) == false {
		t.Fatal("completion disconnected owner")
	}
}
