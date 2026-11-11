package node

import (
	"crypto/ed25519"
	"testing"

	"github.com/libp2p/go-libp2p/core/crypto"
	"github.com/libp2p/go-libp2p/core/peer"
)

// TestPeerIDVector pins the Ed25519 seed 0x00..0x1f peer ID shared with
// scripts/verify-candy-disk.swift (CryptoKit) and js-libp2p.
func TestPeerIDVector(t *testing.T) {
	seed := make([]byte, 32)
	for i := range seed {
		seed[i] = byte(i)
	}
	pub, err := crypto.UnmarshalEd25519PublicKey(ed25519.NewKeyFromSeed(seed).Public().(ed25519.PublicKey))
	if err != nil {
		t.Fatal(err)
	}
	id, _ := peer.IDFromPublicKey(pub)
	if id.String() != "12D3KooWA4Xop1JaT3MHxwYMkCepYsv4iPVopMXwCz5iHYdBfeSB" {
		t.Fatalf("peer id %s", id)
	}
}
