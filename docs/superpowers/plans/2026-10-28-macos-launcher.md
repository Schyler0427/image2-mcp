# macOS Launcher Implementation Plan

> For agentic workers: use independent file ownership, test-first changes and independent review; execute the authorized Mac port continuously.

Goal: a universal native Mac GUI and DMG for the existing two-key offline MCP installer, with signed update checks/downloads.

Global constraints: backend version0.4.0; macOS12+; default Image2, explicit Gemini/banana/香蕉 -> Gemini 3.1 Flash Image; never real credentials or paid calls in tests; never mutate a real install; preserve all Windows behavior; no signing private keys in source/bundle; report no Developer ID/notarization and undeployed update host.

## Task1 native installer core (agent)
Files: macos/LauncherCore.swift, macos/tests/InstallerCoreTests.swift.
Interface: LauncherCredentials(image2Key: String, geminiKey: String), validate() throws, stdinData: Data. LauncherInstallationResult.output: String. NativeArchitecture.current() throws -> String (arm64 or amd64, native hardware including Rosetta). OfflineInstaller(resourcesURL: URL, homeURL: URL), install(credentials: LauncherCredentials, status: @escaping (String)->Void) throws -> LauncherInstallationResult.
- [x] Write/observe failing Swift executable tests for two-key validation, architecture, stdin/env isolation, output redaction incl overlaps, missing/tampered package, success/failure and no secret leakage. Native fixture uses isolated HOME and package fake scripts; actual package integration belongs to root.
- [x] Implement bounded hash-validated resource selection (Resources/packages/{arm64,amd64}/...), launch /bin/bash install-offline.sh with safe env/HOME and two stdin lines, bounded drain/output with full-value redaction. Wait for exit even on input failure; success requires exit0 and exact Verification: OK. No cancellation kill after transaction begins.
- [x] Run Swift tests; commit owned files and report evidence in .superpowers/sdd/macos-task1-report.md.

## Task2 native signed updater (agent)
Files: macos/LauncherUpdate.swift, macos/tests/LauncherUpdateTests.swift, macos/tests/fixtures/* only.
Interface: LauncherUpdateInfo(version,notes,assetURL,sha256,size,architectures,available). LauncherUpdater.init(currentVersion: String). check(completion: @escaping(Result<LauncherUpdateInfo,Error>)->Void). download(info: LauncherUpdateInfo, destinationDirectory: URL, completion: @escaping(Result<URL,Error>)->Void). cancel(). Foundation/CryptoKit only; no GUI references. Additional injectable local fixture initializer is internal and must not accept caller URL/env overrides in production.
- [x] Write/observe failing native tests for valid/tampered signatures, canonical Go signing compatibility incl escaping/nonASCII, unknown/duplicate fields and trailing data, semantic versions and downgrade, Mac architecture/path/host restrictions, manifest/asset bounds, SHA256 and no redirect/cookie/auth.
- [x] Implement fixed endpoint and existing trusted public key, canonical fixed-order JSON matching Go json.Marshal, strict manifest validation and bounded URLSession downloads to a private temp file. Enforce max manifest256KiB, asset256MiB, idle/overall timeout, no automatic retries or arbitrary URL override. Retain a verified DMG only after full digest/size check. No credential loading.
- [x] Run tests; commit owned files and report .superpowers/sdd/macos-task2-report.md.

## Task3 native GUI and packaging (root)
Files: macos/Launcher.swift, scripts/build-macos-launcher.sh, tests/test-macos-launcher.sh, docs/README and publisher CI as needed.
- [x] Add Swift compile/run contract tests and builder validation before implementation. Build AppKit window with two NSSecureTextFields, install/change and check/download buttons, busy status and safe window close. GUI calls installer off-main and updater on click; keys never enter updater. Bundle version from Info.plist.
- [x] Build real arm64/amd64 MCP binaries, existing full offline packages, app resource manifest hashes, universal Swift executable (lipo), Info.plist, ad-hoc signing, DMG with Applications link. Stage before replacing final artifacts; no real config/key reads. Provide optional Developer ID build/notarization path without pretending credentials exist.
- [x] Verify generated architecture/payload/content, native package install and local MCP handshake using isolated HOME, repeat/rollback/tamper cases, GUI launch without keys, signed update fixture; run existing Go/Bash suites, review diff, fix findings, create SHA256SUMS and Chinese usage notes and final artifact links.


## Final evidence — 2026-10-28

Native installer f24f376, updater 5c070d0 and GUI ea6a666 passed independent review. Test-only race repair 98e2e1f makes short success fixtures consume both stdin lines; five native and five Rosetta repeats passed. Production core did not need a change. Root corrected lipo argument ordering, bundle-version expectations, throwing test autoclosures and final artifact publication; output directories now swap atomically as a complete set.

Passed: native Swift core/updater/GUI fixtures; arm64+x86_64 macOS12 target compilation; existing Go tests/race/vet and all Bash installer/bootstrap/offline/contract/universal-Windows regressions; actual packaged installation in isolated HOME, four-tool handshake, repeat key replacement, backup and tamper refusal; full resource hashes; nested/bundle codesign integrity checks; DMG verification and read-only mount/version inspection; atomic replacement by a second complete builder run; workflow YAML parsing.

Artifact: /Users/schyler/Documents/image2-mcp/dist/macos-launcher/SchylerAI-Image2-mcp-macOS.dmg
Version: 0.4.0
Bytes: 14262625
SHA-256: 08d3287bfe2747ab0ad92dc6dcd769caad808f03b72e121e8fc5b79ebe3be2d0
The .app, SHA256SUMS.txt and Chinese usage notes are alongside the DMG; identical copies are in this worktree's dist/macos-launcher directory.

Limits: no Developer ID identity exists locally, so this is ad-hoc signed and not Apple notarized. GUI process launch succeeded, but visual inspection through Computer Use was blocked by the Mac lock screen. AppKit control/action tests passed. Intel hardware and macOS12 runtime were not available (x86_64 core ran under existing Rosetta). No real key or paid API was used, no real Codex configuration was changed, and no update host or remote release was deployed.
