# macOS Task 2: native signed updater

Implemented only the updater source, native tests and local updater fixtures. GUI and installer files remain with their owners.

API: `LauncherUpdateInfo` exposes version/notes/assetURL (URL)/sha256/size (Int64)/architectures ([String])/available. `LauncherUpdater(currentVersion:)` provides check/download/cancel, with completions on the main queue. A fixture-only internal initializer injects URLProtocol/public key/architecture/time limits; the host, endpoint and versioned DMG path never accept caller or environment overrides. Download re-verifies the originating signed manifest rather than trusting caller-created metadata.

Security behavior: fixed `launcher-macos.json` endpoint; existing release Ed25519 public key; strict JSON parser rejecting unknown/duplicate fields, invalid UTF-8, bad field types, fractional/overflow sizes and trailing data; canonical fixed-order Go JSON signing bytes including HTML/control/U+2028/U+2029 escaping and non-ASCII UTF-8; strict numeric three-component version comparison with downgrade refusal; RFC3339 calendar validation; current native Mac architecture with Rosetta-aware hardware detection; exact same-host HTTPS versioned macOS DMG URL.

Transport: isolated ephemeral URLSession with no cookies, credential storage, cache or caller headers; HTTP/client authentication cancelled and normal system TLS trust evaluation retained; no redirect/retry loop; 256 KiB manifest and 256 MiB asset caps; 15-second idle and 300-second overall production timers. Assets stream into a private 0700 download directory and 0600 partial file. Exact byte count and incremental SHA256 must match before renaming to the retained DMG. Failure, cancellation and timeouts remove the entire partial directory.

Test-first evidence: wrote the native test contract and Go-generated canonical/signature vectors first. Initial Swift compilation failed because `macos/LauncherUpdate.swift` did not exist. First implementation run exposed timestamp validation errors. Additional tests demonstrated that Foundation accepts invalid calendar dates such as February 31; explicit calendar validation fixes that case. Expanded cancellation and idle/overall timeout tests stream partial bytes and verify cleanup.

Fresh verification:

```text
xcrun swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos12 macos/LauncherUpdate.swift macos/tests/LauncherUpdateTests.swift -o /tmp/image2-launcher-update-tests
/tmp/image2-launcher-update-tests
13/13 updater test groups passed

xcrun swiftc -swift-version 5 -parse-as-library -target x86_64-apple-macos12 macos/LauncherUpdate.swift macos/tests/LauncherUpdateTests.swift -o /tmp/image2-launcher-update-tests-x86_64
file /tmp/image2-launcher-update-tests-x86_64
Mach-O 64-bit executable x86_64
```

All HTTP interactions use a local custom URLProtocol. Go fixture generation creates an ephemeral test signing key and saves only its public key, canonical bytes, signed manifest and harmless 18-byte fake asset. No release private key, real API credential, paid call or live update host is used. x86_64 compilation is verified; Intel hardware execution is not claimed. Remote update deployment is outside this task. Developer ID signing and notarization remain publisher prerequisites outside this updater implementation.
