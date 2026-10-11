package hub

import (
	"crypto/hmac"
	"crypto/sha1" // TURN REST specifies HMAC-SHA1.
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"time"

	"github.com/google/uuid"
	"webtrc-signaling/internal/model"
)

type IdentityStore struct {
	mu         sync.Mutex
	path       string
	identities map[string]string
}

func OpenIdentityStore(path string) (*IdentityStore, error) {
	s := &IdentityStore{path: path, identities: map[string]string{}}
	data, err := os.ReadFile(path)
	if err == nil {
		if err := json.Unmarshal(data, &s.identities); err != nil {
			return nil, err
		}
		if s.identities == nil {
			return nil, errors.New("invalid identity store")
		}
		for id, digest := range s.identities {
			if id == "" || len(id) > 128 || !hashPattern.MatchString(digest) {
				return nil, errors.New("invalid identity store")
			}
		}
	} else if !os.IsNotExist(err) {
		return nil, err
	}
	return s, nil
}

// Authenticate is persisted TOFU, not a user account or proof of a person's identity.
func (s *IdentityStore) Authenticate(id, secret string) (bool, error) {
	if id == "" || len(id) > 128 {
		return false, errors.New("invalid id")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if secret == "" {
		if _, exists := s.identities[id]; exists {
			return false, errors.New("identity-secret-required")
		}
		return false, nil
	}
	if _, err := uuid.Parse(secret); err != nil {
		return false, errors.New("invalid secret")
	}
	sum := sha256.Sum256([]byte(secret))
	digest := hex.EncodeToString(sum[:])
	if stored, exists := s.identities[id]; exists {
		if !hmac.Equal([]byte(stored), []byte(digest)) {
			return false, errors.New("identity-mismatch")
		}
		return true, nil
	}
	if len(s.identities) >= 100000 {
		return false, errors.New("identity-store-full")
	}
	s.identities[id] = digest
	data, err := json.Marshal(s.identities)
	if err == nil {
		err = os.MkdirAll(filepath.Dir(s.path), 0700)
	}
	if err == nil {
		var f *os.File
		f, err = os.OpenFile(s.path+".new", os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0600)
		if err == nil {
			_, err = f.Write(data)
			if err == nil {
				err = f.Sync()
			}
			closeErr := f.Close()
			if err == nil {
				err = closeErr
			}
		}
	}
	if err == nil {
		err = os.Rename(s.path+".new", s.path)
	}
	if err != nil {
		delete(s.identities, id)
		_ = os.Remove(s.path + ".new")
		return false, errors.New("identity-persistence-failed")
	}
	return true, nil
}

func ICEConfig(id string, now time.Time, turnURLs []string, secret string) []model.ICEServer {
	result := []model.ICEServer{{URLs: []string{"stun:stun.l.google.com:19302"}}}
	if len(turnURLs) != 0 && secret != "" {
		username := strconv.FormatInt(now.Add(10*time.Minute).Unix(), 10) + ":" + id
		mac := hmac.New(sha1.New, []byte(secret))
		_, _ = mac.Write([]byte(username))
		result = append(result, model.ICEServer{URLs: turnURLs, Username: username, Credential: base64.StdEncoding.EncodeToString(mac.Sum(nil))})
	}
	return result
}
