package main

import (
	"crypto/ed25519"
	"encoding/base64"
)

// UpdateManifestHost is the only host accepted for signed launcher updates.
// Keep this value in sync with the release publisher and do not derive it from
// user input or an environment variable.
const UpdateManifestHost = "api.schyler.top"

// UpdateManifestURL is the fixed endpoint used by the launcher update check.
const UpdateManifestURL = "https://api.schyler.top/image2/releases/latest/launcher.json"

// UpdatePublicKeyBase64 is the release signing key in standard base64 form.
// The corresponding private key is held by the release publisher only.
const UpdatePublicKeyBase64 = "hoZAzBNEtj4w+AMVbYWCRKYpOybi3Y0ekgfkDBNkIVI="

// UpdatePublicKey is the parsed release key used by the launcher verifier.
var UpdatePublicKey = mustDecodeUpdatePublicKey()

func mustDecodeUpdatePublicKey() ed25519.PublicKey {
	key, err := base64.StdEncoding.DecodeString(UpdatePublicKeyBase64)
	if err != nil || len(key) != ed25519.PublicKeySize {
		panic("invalid launcher update public key")
	}
	return ed25519.PublicKey(key)
}
