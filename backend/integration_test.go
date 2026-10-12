package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/gorilla/websocket"
	"webtrc-signaling/internal/model"
)

func TestBackendProcess(t *testing.T) {
	if os.Getenv("MUSIC_BACKEND_TEST_CHILD") != "1" {
		return
	}
	var arguments []string
	if err := json.Unmarshal([]byte(os.Getenv("MUSIC_BACKEND_TEST_ARGS")), &arguments); err != nil {
		t.Fatal(err)
	}
	os.Args = append([]string{os.Args[0]}, arguments...)
	main()
	os.Exit(0)
}

func isolatedPort(t *testing.T) int {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	listener.Close()
	return port
}

func receiveType(t *testing.T, conn *websocket.Conn, kind string) model.WSMessage {
	t.Helper()
	_ = conn.SetReadDeadline(time.Now().Add(10 * time.Second))
	for {
		var msg model.WSMessage
		if err := conn.ReadJSON(&msg); err != nil {
			t.Fatalf("receive %s: %v", kind, err)
		}
		if msg.Type == kind {
			return msg
		}
	}
}

func TestWebSocketGatewayEndToEnd(t *testing.T) {
	if os.Getenv("MUSIC_BACKEND_TEST_CHILD") == "1" {
		return
	}
	dir := filepath.Join(".test-artifacts", uuid.NewString())
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir); _ = os.Remove(".test-artifacts") })
	signalingPort, gatewayPort := isolatedPort(t), isolatedPort(t)
	if signalingPort == gatewayPort {
		gatewayPort = isolatedPort(t)
	}
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	arguments := []string{
		"-port=" + fmt.Sprint(signalingPort), "-gateway-port=" + fmt.Sprint(gatewayPort),
		"-gateway-public-url=https://gateway.test", "-identity-store=" + filepath.Join(dir, "identities.json"),
		"-gateway-cache-dir=" + filepath.Join(dir, "cache")}
	encodedArgs, _ := json.Marshal(arguments)
	command := exec.CommandContext(ctx, executable, "-test.run=^TestBackendProcess$")
	command.Env = append(os.Environ(), "MUSIC_BACKEND_TEST_CHILD=1", "MUSIC_BACKEND_TEST_ARGS="+string(encodedArgs), "TURN_URLS=turn:turn.test:3478", "TURN_REST_SECRET=integration-only-secret")
	var output bytes.Buffer
	command.Stdout = &output
	command.Stderr = &output
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = command.Process.Kill(); _ = command.Wait() })
	wsBase := fmt.Sprintf("ws://127.0.0.1:%d/ws", signalingPort)
	deadline := time.Now().Add(10 * time.Second)
	for {
		conn, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", signalingPort), 100*time.Millisecond)
		if err == nil {
			conn.Close()
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("isolated signaling did not start")
		}
		time.Sleep(50 * time.Millisecond)
	}
	dial := func(id, secret string) *websocket.Conn {
		t.Helper()
		conn, _, err := websocket.DefaultDialer.Dial(wsBase+"?id="+id+"&secret="+secret, nil)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { conn.Close() })
		config := receiveType(t, conn, "config")
		if config.ProtocolVersion != 2 || !config.GatewayEnabled || len(config.ICEServers) != 2 {
			t.Fatal("config missing", config)
		}
		receiveType(t, conn, "plaza")
		receiveType(t, conn, "listeners")
		return conn
	}
	ownerSecret := uuid.NewString() + uuid.NewString()
	owner := dial("source", ownerSecret)
	_, response, err := websocket.DefaultDialer.Dial(wsBase+"?id=source&secret="+uuid.NewString(), nil)
	if err == nil || response == nil || response.StatusCode != 403 {
		t.Fatal("TOFU impersonation accepted")
	}
	response.Body.Close()
	_, response, err = websocket.DefaultDialer.Dial(wsBase+"?id=source", nil)
	if err == nil || response == nil || response.StatusCode != 403 {
		t.Fatal("legacy bypassed pinned identity")
	}
	response.Body.Close()
	data := bytes.Repeat([]byte("actual websocket HTTP gateway test"), 50000)
	sum := sha256.Sum256(data)
	f := model.FileMeta{ID: uuid.NewString(), Name: "../../not-trusted.mp3", Size: int64(len(data)), SHA256: hex.EncodeToString(sum[:]), ProtocolVersion: 2}
	if err := owner.WriteJSON(model.WSMessage{Type: "listening", Listening: &model.Listening{OwnerName: "Source", Title: "Song", File: &f}}); err != nil {
		t.Fatal(err)
	}
	receiveType(t, owner, "listeners")
	receiveType(t, owner, "plaza")
	recipients := make([]*websocket.Conn, 3)
	grants := make([]*model.Transfer, 3)
	for i := range recipients {
		recipients[i] = dial(fmt.Sprintf("receiver-%d", i), uuid.NewString())
		requestID := uuid.NewString()
		_ = recipients[i].WriteJSON(model.WSMessage{Type: "transfer-request", RequestID: requestID, FileID: f.ID, To: "source"})
		msg := receiveType(t, recipients[i], "transfer")
		if msg.RequestID != requestID || msg.Transfer == nil {
			t.Fatal("transfer response")
		}
		grants[i] = msg.Transfer
	}
	if grants[0].Mode != "p2p" || grants[1].Mode != "p2p" || grants[2].Mode != "relay" {
		t.Fatal("admission modes")
	}
	authorized := receiveType(t, owner, "transfer-authorized")
	if authorized.From != "receiver-0" || authorized.Transfer == nil || authorized.Transfer.ID != grants[0].ID ||
		authorized.Transfer.Token != "" || authorized.Transfer.Generation != 1 {
		t.Fatal("owner authorization missing or leaked receiver bearer")
	}
	if second := receiveType(t, owner, "transfer-authorized"); second.Transfer == nil || second.Transfer.ID != grants[1].ID {
		t.Fatal("second P2P owner authorization missing")
	}
	upload := receiveType(t, owner, "upload-request").Transfer
	if upload == nil || upload.Token == grants[2].Token || !strings.HasPrefix(upload.UploadURL, "https://gateway.test/v2/uploads/") {
		t.Fatal("upload authorization")
	}
	gatewayBase := fmt.Sprintf("http://127.0.0.1:%d", gatewayPort)
	httpCall := func(method, path, token, contentRange string, data []byte) (*http.Response, []byte) {
		t.Helper()
		req, _ := http.NewRequest(method, gatewayBase+path, bytes.NewReader(data))
		req.Header.Set("Authorization", "Bearer "+token)
		if contentRange != "" {
			if method == "PUT" {
				req.Header.Set("Content-Range", contentRange)
			} else {
				req.Header.Set("Range", contentRange)
			}
		}
		response, err := (&http.Client{Timeout: 10 * time.Second}).Do(req)
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
	uploadPath := strings.TrimPrefix(upload.UploadURL, "https://gateway.test")
	downloadPath := strings.TrimPrefix(grants[2].DownloadURL, "https://gateway.test")
	response, _ = httpCall("HEAD", downloadPath, grants[2].Token, "", nil)
	if response.StatusCode != 425 {
		t.Fatal("waiting endpoint")
	}
	for start := 0; start < len(data); start += 1 << 20 {
		end := min(start+1<<20, len(data)) - 1
		response, body := httpCall("PUT", uploadPath, upload.Token, fmt.Sprintf("bytes %d-%d/%d", start, end, len(data)), data[start:end+1])
		if response.StatusCode != 204 {
			t.Fatalf("upload: %d %s", response.StatusCode, body)
		}
		response, _ = httpCall("HEAD", uploadPath, upload.Token, "", nil)
		if response.Header.Get("Upload-Offset") != fmt.Sprint(end+1) {
			t.Fatal("durable resume acknowledgment")
		}
	}
	ready := receiveType(t, recipients[2], "transfer")
	if ready.Transfer == nil || ready.Transfer.ID != grants[2].ID || ready.Transfer.Status != "ready" {
		t.Fatal("ready notification")
	}
	response, body := httpCall("GET", downloadPath, grants[2].Token, "bytes=123-", nil)
	if response.StatusCode != 206 || !bytes.Equal(body, data[123:]) || response.Header.Get("ETag") != `"`+f.SHA256+`"` {
		t.Fatal("range content")
	}
	inner, _ := json.Marshal(map[string]any{"transferId": grants[0].ID, "fileId": f.ID, "generation": 1, "kind": "offer", "sdp": "inner unchanged"})
	envelopeData, _ := json.Marshal(string(inner))
	_ = recipients[0].WriteJSON(model.WSMessage{Type: "signal", To: "source", TransferID: grants[0].ID, Generation: 1, Data: envelopeData})
	signal := receiveType(t, owner, "signal")
	if signal.From != "receiver-0" || !bytes.Equal(signal.Data, envelopeData) {
		t.Fatal("inner signal changed")
	}
	_ = recipients[0].WriteJSON(model.WSMessage{Type: "signal", To: "source", TransferID: grants[0].ID, Generation: 2, Data: envelopeData})
	if receiveType(t, recipients[0], "transfer-error").Error != "invalid-signal" {
		t.Fatal("wrong generation accepted")
	}
	_ = recipients[0].WriteJSON(model.WSMessage{Type: "transfer-request", RequestID: uuid.NewString(), TransferID: grants[0].ID, FileID: f.ID, To: "source"})
	resumed := receiveType(t, recipients[0], "transfer").Transfer
	if resumed == nil || resumed.Generation != 2 {
		t.Fatal("P2P resume generation")
	}
	authorization := receiveType(t, owner, "transfer-authorized")
	if authorization.Transfer == nil || authorization.Transfer.ID != grants[0].ID || authorization.Transfer.Generation != 2 ||
		authorization.From != "receiver-0" {
		t.Fatal("resume authorization not resent")
	}
	_ = recipients[0].WriteJSON(model.WSMessage{Type: "transfer-request", RequestID: uuid.NewString(), TransferID: grants[0].ID, FileID: f.ID, To: "source", Mode: "relay"})
	upgraded := receiveType(t, recipients[0], "transfer").Transfer
	if upgraded == nil || upgraded.Mode != "relay" || upgraded.Status != "ready" ||
		upgraded.ID != grants[0].ID || upgraded.Token != grants[0].Token {
		t.Fatal("wire relay fallback lost grant identity")
	}
	if revoked := receiveType(t, owner, "transfer-revoked"); revoked.TransferID != grants[0].ID || revoked.Error != "relay-upgrade" {
		t.Fatal("owner direct channel not stopped at fallback")
	}
	response, body = httpCall("GET", strings.TrimPrefix(upgraded.DownloadURL, "https://gateway.test"), upgraded.Token, "", nil)
	if response.StatusCode != 200 || !bytes.Equal(body, data) {
		t.Fatal("upgraded grant cannot download deduplicated content")
	}
	_ = recipients[1].WriteJSON(model.WSMessage{Type: "transfer-complete", TransferID: grants[1].ID})
	if completed := receiveType(t, owner, "transfer-completed"); completed.TransferID != grants[1].ID {
		t.Fatal("owner completion notification missing")
	}
	_ = recipients[1].WriteJSON(model.WSMessage{Type: "transfer-complete", TransferID: grants[1].ID})
	_ = owner.WriteJSON(model.WSMessage{Type: "share-retire", FileID: f.ID})
	retired := receiveType(t, owner, "listeners")
	for _, listener := range retired.Listeners {
		if listener.ClientID == "source" && listener.File != nil {
			t.Fatal("retired old share advertised")
		}
	}
	receiveType(t, owner, "plaza")
	response, body = httpCall("GET", downloadPath, grants[2].Token, "", nil)
	if response.StatusCode != 200 || !bytes.Equal(body, data) {
		t.Fatal("retire interrupted existing gateway grant")
	}
	_ = recipients[2].WriteJSON(model.WSMessage{Type: "transfer-request", RequestID: uuid.NewString(), FileID: f.ID, To: "source"})
	if receiveType(t, recipients[2], "transfer-error").Error != "not-available" {
		t.Fatal("retired old song admission allowed")
	}
	next := f
	next.ID = uuid.NewString()
	_ = owner.WriteJSON(model.WSMessage{Type: "listening", Listening: &model.Listening{OwnerName: "Source", Title: "Next", File: &next}})
	receiveType(t, owner, "listeners")
	receiveType(t, owner, "plaza")
	response, body = httpCall("GET", downloadPath, grants[2].Token, "", nil)
	if response.StatusCode != 200 || !bytes.Equal(body, data) {
		t.Fatal("cut song revoked existing transfer")
	}
	_ = recipients[2].WriteJSON(model.WSMessage{Type: "transfer-request", RequestID: uuid.NewString(), FileID: f.ID, To: "source"})
	if receiveType(t, recipients[2], "transfer-error").Error != "not-available" {
		t.Fatal("old song new request")
	}
	owner.Close()
	deadline = time.Now().Add(2 * time.Second)
	for {
		response, _ = httpCall("HEAD", downloadPath, grants[2].Token, "", nil)
		if response.StatusCode == 403 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("disconnect lease not revoked")
		}
		time.Sleep(20 * time.Millisecond)
	}
	if notice := receiveType(t, recipients[2], "transfer-revoked"); notice.TransferID != grants[2].ID || notice.Error != "revoked" {
		t.Fatal("disconnect revocation notification missing")
	}
	reconnected := dial("source", ownerSecret)
	_ = reconnected.WriteJSON(model.WSMessage{Type: "listening", Listening: &model.Listening{OwnerName: "Source", Title: "Current", File: &next}})
	receiveType(t, reconnected, "listeners")
	receiveType(t, reconnected, "plaza")
	_ = recipients[2].WriteJSON(model.WSMessage{Type: "transfer-request", RequestID: uuid.NewString(), FileID: f.ID, To: "source", TransferID: grants[2].ID})
	if receiveType(t, recipients[2], "transfer-error").Error != "invalid-or-revoked-transfer" {
		t.Fatal("revoked grant resurrected")
	}
	disk, _ := os.ReadFile(filepath.Join(dir, "identities.json"))
	if bytes.Contains(disk, []byte(ownerSecret)) {
		t.Fatal("secret persisted in plaintext")
	}
}
