# macOS installer core — Task 1

Owned implementation: `macos/LauncherCore.swift`, `macos/tests/InstallerCoreTests.swift`.

Commit: `f24f376 feat: add verified native macOS installer core`. The report stays in the repository's ignored `.superpowers/sdd` execution-report directory.

The planned credential/result/native-architecture/installer interfaces are implemented. The compatible installer initializer also accepts optional `expectedVersion`, defaulting to the app bundle version; unbundled fixture executables can provide a version explicitly. Resource versions must be bounded stable three-part versions, and a bundle version must match. A future `0.4.1` resource set is covered.

Resource loading bounds the manifest at 256 KiB/512 entries and the selected package at 256 MiB. Directory-descriptor traversal rejects symlinks, hardlinks, special files, unlisted files, traversal/absolute paths, duplicate case-folded paths, missing resources, size/digest mismatches and incompatible versions. Selected files are hashed while copied through no-follow descriptors into a mode-0700 private temporary directory; only the completed verified copy can execute. Executable permission bits are retained for real package helper scripts. The source application/DMG is never written.

The child receives a fixed environment, explicit caller HOME/private TMPDIR and exactly two key lines on stdin. No credentials enter process arguments/environment. A translated x86_64 launcher on Apple Silicon selects the arm64 payload and launches `/usr/bin/arch -arm64 /bin/bash`; native launches directly use `/bin/bash`.

Output drains concurrently and retains at most 256 KiB plus a truncation label. Exact byte matches are masked across read boundaries and overlapping values; UTF-8 decoding, generated mask/truncation labels, statuses and errors are sanitized as well. Exit zero plus an exact `Verification: OK` line are both required. Broken stdin, output-read failures, signals, nonzero exits and missing verification fail. There is no process cancellation/termination call: even an EPIPE waits for the transaction to finish.

## TDD evidence

- Initial credential/native tests failed on the absent core source; then passed after implementation.
- Installer fixtures compiled against the API stub and failed at the expected unavailable-resource error before resource/process implementation.
- Added regressions observed failures for redaction-marker collision, status-label key collision, CRLF key validation, future-version API/checks and invalid UTF-8 decoding; fixes were followed by passing full runs.
- Descriptor traversal fixed a reproduced Foundation `/var` versus `/private/var` enumeration mismatch without permitting resource links.

## Fresh verification

`swiftc -swift-version 5 -warnings-as-errors -target arm64-apple-macos12.0 macos/LauncherCore.swift macos/tests/InstallerCoreTests.swift -o /tmp/image2-core-tests-arm64` followed by native execution: exit 0.

`swiftc -swift-version 5 -warnings-as-errors -target x86_64-apple-macos12.0 macos/LauncherCore.swift macos/tests/InstallerCoreTests.swift -o /tmp/image2-core-tests-amd64` followed by `/usr/bin/arch -x86_64 /tmp/image2-core-tests-amd64`: exit 0 using the previously installed Rosetta runtime.

Both outputs: `PASS: InstallerCoreTests (credentials, architecture, process isolation, result/redaction, resource refusal, package versions, bounded drain, transaction wait)`.

`git diff --check`: exit 0.

The fixture covers a 60-file package, executable helper, environment/startup isolation, exactly two stdin lines, source preservation/private-copy cleanup, output over 1 MiB, Unicode/cross-read/overlapping-value redaction, exact result checks, all listed resource refusals, version upgrades/mismatch and deterministic broken stdin. The broken-input fixture closes stdin before the launcher write, later writes a completion sentinel and exits zero with verification; the launcher waits and then refuses success. The shell architecture fixture confirms native arm64 execution even from the translated test binary.

All fixture installs use generated fake scripts, dummy credentials and an isolated temporary HOME. No real user configuration/keys were read or changed; no paid APIs, network calls or actual offline packages were invoked by this task. Actual bundled-package installation, GUI/DMG validation and full repository suites belong to root. x86_64 execution here is Rosetta evidence rather than Intel hardware; macOS 12 is a deployment-target compile check rather than a macOS 12 runtime claim.

## Follow-up: short fixture stdin race

Root's wrapper observed a nondeterministic fixture failure with output exactly `Verification: OK`. A 10 ms callback delay reproduced it deterministically in the package-version group: that fake child printed success and exited without reading stdin, so the launcher's correct EPIPE guard rejected it. Production installer behavior did not change. All short success and result-verification fixtures now consume both credential lines. The delay remains in the version fixture as a regression check, and the explicit broken-stdin transaction-wait fixture remains unchanged. Test groups now report named failures instead of an uncaught top-level error.

Fresh follow-up verification: arm64 and x86_64 macOS12 targets compiled with `-warnings-as-errors`; five consecutive full native runs and five consecutive full Rosetta runs each exited 0. `git diff --check` exited 0. Only `macos/tests/InstallerCoreTests.swift` changed.

Follow-up commit: `98e2e1f test: make macOS installer fixtures consume credentials`.
