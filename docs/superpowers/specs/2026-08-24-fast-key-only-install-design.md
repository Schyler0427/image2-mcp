# Fast Key-Only Installation Design

Date: 2026-08-24

Status: approved design; implementation pending

## Goal

Reduce Image2 MCP customer installation stalls without weakening the fixed
Release, secret-handling, target-ownership, rollback, or local-verification
contract. A customer still sends one instruction and supplies only one API Key.
The optimized flow must not require Git, Go, elevation, an administrator helper,
or a second configuration answer.

The change ships as public `v0.2.3`. Existing `v0.2.1` and `v0.2.2` tags and
Releases remain immutable.

## Evidence And Root Cause

The current Windows bootstrap performs up to three 30-second Release API
attempts with two 2-second sleeps. If that fails, each public-page request can
repeat the same schedule. The Release gate can therefore spend several minutes
before downloading the source archive. The source download has a 60-second
timeout, but the platform binary download has no explicit timeout.

Live probes on 2026-08-24 showed that the public Release and expanded-assets
pages returned in about two to four seconds while `api.github.com`,
`raw.githubusercontent.com`, `objects.githubusercontent.com`, and a Release
asset intermittently failed TLS connection establishment. The six Release
assets are each about 5.5 to 6.2 MB, so file size does not explain a multi-minute
pause before the key prompt.

The Agent contract also starts the helper before asking the customer for the
key. This leaves a terminal process open across a customer turn. In the observed
Windows run, the Agent introduced an administrator process and a separate stdin
forwarder, sent input before the expected prompt, inspected `.env.local` too
early, and entered `reconnecting 1/5`. That is an orchestration failure rather
than a Release 404.

## Customer And Agent Flow

The customer-facing instruction remains a single sentence. The Agent follows
this sequence:

1. Read `AGENT_INSTALL.md`, detect the platform, and ask exactly
   `请输入 API Key：` before starting a long-running helper.
2. After the customer replies, download the exact repository-owned helper to a
   newly created temporary file.
3. Start the helper once as the current user with real stdin/stdout/stderr. Do
   not elevate, create an administrator helper, create a forwarding script,
   restart the helper, or inspect installation output paths while it runs.
4. Keep the key only as the pending secret input. When the existing
   `OPENAI_IMAGE_API_KEY:` child prompt appears, send exactly that one line to
   the process stdin. Never put it in a command, argument, shell variable,
   environment variable, temporary file, diagnostic, or output stream.
5. Wait for process exit. Success still requires exit status zero and the exact
   line `Verification: OK`.

The helper continues to validate public Release state and stage the source
before its installer reads stdin. Supplying the key to the Agent first changes
only orchestration: it keeps download, prompt forwarding, installation, and
verification in one Agent turn instead of suspending a live process across a
customer turn.

## Network Strategy

Metadata and payload downloads have different policies.

### Public Release gate

The public Release page and expanded-assets page become the primary route. An
unauthenticated successful page proves that the fixed Release is public; the
page must identify exact tag `v0.2.3`, must not identify a prerelease, and the
expanded-assets page must contain all six exact asset paths.

The GitHub Release API remains a fallback and must still validate exact tag,
`draft=false`, `prerelease=false`, and all six assets. Each metadata endpoint is
attempted once with a short bounded timeout. Failure of both page and API routes
produces one clear Release-gate error before target mutation or key input.

Metadata requests do not use multi-minute retries. The total Release-gate
network budget should be approximately 30 to 45 seconds when all routes are
unreachable, excluding platform DNS behavior outside the shell or PowerShell
timeout implementation.

### Source and binary payloads

The pinned `v0.2.3` source archive remains mandatory and is validated before
extraction. Its request receives a bounded payload timeout and a clear stage
message.

The selected 5-7 MB Release binary also receives an explicit bounded payload
timeout. A partial or failed download remains staged in a unique temporary path
and never replaces the active binary. Bash `curl`/`wget` and Windows PowerShell
use equivalent bounded behavior where their native semantics allow it.

This release does not introduce a third-party download proxy. If GitHub asset
delivery is consistently unavailable in a customer region, a separately owned
binary mirror on `api.schyler.top` is a future distribution change requiring
its own integrity and deployment design.

## Progress And Errors

Both helpers print short non-secret milestones before potentially slow work:

- `Checking public Release...`
- `Downloading source package...`
- `Preparing installation...`
- `Installing platform binary...`
- `Verifying local installation...`

The platform installers retain their existing binary URL line, but errors must
identify the failed stage and URL category without exposing the key or customer
configuration. No timer, retry, or diagnostic may print request headers,
environment contents, stdin, `.env.local`, or Codex configuration values.

The Agent must treat a running milestone as progress. It must not restart the
helper, create a second install, or infer failure from the absence of
`.env.local`; only process exit and helper output determine completion.

## Safety And Compatibility

All existing safety boundaries remain required:

- fixed repository `Schyler0427/image2-mcp` and base URL
  `https://api.schyler.top`;
- fixed public non-draft/non-prerelease `v0.2.3` Release and six exact assets;
- Bash 3.2 and Windows PowerShell 5.1 compatibility;
- current-user Windows installation with no elevation requirement;
- strict archive, existing-target, and Codex TOML validation;
- atomic `.env.local` and binary replacement;
- complete previous-target/config rollback or retained evidence;
- local verification with no image generation or billable API request;
- API Key never printed or stored in Codex configuration.

## Test Strategy

Tests are written before production changes and must demonstrate these
behaviors:

1. Contract tests reject the old start-helper-before-asking-key wording and
   require the no-elevation, no-forwarder, single-process sequence.
2. Bash and PowerShell fixtures prove public pages are attempted before the API
   and that an API fallback still succeeds.
3. Failure fixtures count metadata calls and prove the long three-attempt loops
   are gone.
4. Mocks require explicit timeout parameters on source and binary downloads.
5. Existing API-failure fallback, archive-hardening, rollback, repeat install,
   secret-redaction, ACL, Codex configuration, and local verification tests
   continue to pass.
6. GitHub Actions runs the Bash suites on Ubuntu and the PowerShell 5.1 suites
   on Windows before building all six `v0.2.3` assets.
7. Post-release verification checks workflow success, public Release metadata,
   all six HTTP download paths, raw helpers on `main`, and the pinned source
   archive. It does not call an image API.

## Release Acceptance

The optimization is complete only when:

- `main` contains the reviewed `v0.2.3` contract and implementation;
- the annotated `v0.2.3` tag points at that commit without moving older tags;
- the public Release is neither draft nor prerelease and contains all six exact
  assets;
- Ubuntu and Windows installer tests and all six builds pass;
- a repeated customer instruction requires only one API Key and never invokes
  an administrator process or stdin forwarding script;
- blocked GitHub metadata fails within the bounded gate rather than retrying for
  several minutes, and payload downloads either complete or exit with a clear
  bounded error.
