# Image2 MCP Agent Key-Only Installation Design

Date: 2026-08-07

Status: approved design, pending implementation

## Goal

A customer sends one fixed sentence to a terminal-capable Agent. The Agent follows
the repository-owned instructions, asks for only the customer's API Key, installs
Image2 MCP from GitHub, configures Codex, verifies the local installation, and
reports the result.

The customer-facing sentence is:

```text
请安装并配置 Image2 MCP：读取并严格执行 https://raw.githubusercontent.com/Schyler0427/image2-mcp/main/AGENT_INSTALL.md，除 API Key 外不要向我询问其他配置，完成安装和验证后再结束。
```

The installation uses these fixed values:

- Repository: `https://github.com/Schyler0427/image2-mcp`
- GitHub repository slug: `Schyler0427/image2-mcp`
- API base URL: `https://api.schyler.top`
- Codex MCP server name: `image2`
- macOS/Linux install directory: `$HOME/.local/share/image2-mcp`
- Windows install directory: `%LOCALAPPDATA%\image2-mcp`

The only customer-supplied value is `OPENAI_IMAGE_API_KEY`. The Agent must not
ask the customer to choose a repository, branch, base URL, install path, build
method, shell, Codex config path, or whether to replace an existing Image2 MCP
configuration.

## Success Criteria

An installation is successful only when all of the following are true:

1. The source package is present at the fixed install directory.
2. The Release binary for the detected OS and architecture is installed and can
   be started through the repository runner.
3. `.env.local` contains the fixed base URL and a non-empty customer API Key.
4. The key is not printed, placed in a shell command, or written to Codex
   `config.toml`.
5. Codex `config.toml` contains exactly one active `image2` MCP definition that
   points at the fixed install directory.
6. Existing Codex settings and MCP definitions other than the `image2` namespace
   remain unchanged.
7. Verification completes without making a billable image-generation or
   image-edit request.
8. The Agent reports the installed paths and verification results without
   echoing or partially revealing the key.

## Architecture

The feature has four parts with separate responsibilities.

### `AGENT_INSTALL.md`

A new root-level `AGENT_INSTALL.md` is the stable, customer-facing Agent
contract. It contains deterministic macOS/Linux and Windows procedures. The
Agent detects the platform, obtains the repository, invokes the correct
key-only installer, handles its single secret input, and checks the final
status. It does not invent values or offer configuration choices.

The file must be usable when the customer's machine has Codex, terminal access,
and network access but has neither Git nor Go.

### Bash installer

`install.sh` continues to dispatch to `scripts/setup.sh`. The setup script gains
`--key-only`. This mode is additive: existing flags and workflows remain
available for maintainers.

`--key-only` is a complete preset. It implies all of the following:

- fixed base URL `https://api.schyler.top`;
- prebuilt Release binary, regardless of whether Go is installed;
- no source tests and no Go dependency;
- automatic Codex configuration;
- replacement of the existing `image2` MCP namespace;
- exactly one API Key read;
- local post-install verification.

Combining `--key-only` with options that alter its preset is an error. The mode
does not honor `OPENAI_IMAGE_BASE_URL`, an existing `.env.local` base URL, or a
previous API Key as substitutes for the single new key input.

### PowerShell installer

`install.ps1` gains `-KeyOnly` with the same semantics as Bash. It always uses a
Windows Release asset, writes the fixed gateway, replaces the `image2` MCP
namespace, and performs the same non-billable verification. Existing PowerShell
options remain available outside key-only mode.

### GitHub Release workflow

The existing tag-triggered Release workflow remains the binary source. The
implementation is not customer-ready merely because this workflow exists. A
new `v0.2.1` tag must successfully publish all six expected assets before
`AGENT_INSTALL.md` is advertised:

```text
image2-mcp_darwin_arm64.tar.gz
image2-mcp_darwin_amd64.tar.gz
image2-mcp_linux_arm64.tar.gz
image2-mcp_linux_amd64.tar.gz
image2-mcp_windows_arm64.zip
image2-mcp_windows_amd64.zip
```

The binary's reported MCP implementation version is updated to `0.2.1` for this
release. Installers continue using GitHub's `releases/latest/download` URLs, so
the `v0.2.1` Release must be the repository's latest non-draft, non-prerelease
release.

## Agent Bootstrap Flow

The Agent performs these steps without configuration questions:

1. Verify that Codex is installed, a supported shell is available, and GitHub is
   reachable.
2. Detect one of the supported targets: macOS or Linux on `arm64`/`amd64`, or
   Windows on `ARM64`/`AMD64`.
3. Use the fixed install directory. The directory is managed by this installer;
   the Agent does not ask the customer for another path.
4. If Git is available, clone the fixed repository for a first install. For an
   existing clean checkout of the same repository, update it with a fast-forward
   operation. Do not reset or discard local changes.
5. If Git is unavailable, download the GitHub default-branch source archive to a
   temporary directory and extract it into the fixed install directory. Set
   `IMAGE2_MCP_REPO=Schyler0427/image2-mcp` for the installer because an archive
   has no Git remote metadata.
6. On a repeated archive-based install, first stage and validate the complete new
   source tree in a temporary sibling directory. Treat the existing target as
   managed only when it contains the expected Image2 MCP repository files and a
   bootstrap marker containing the fixed repository slug. Preserve
   `.env.local` and `output/`, swap repository-owned content as a set, and keep
   the old tree as a temporary rollback copy until installer verification
   succeeds. If the identity check fails, stop instead of deleting unknown
   files.
7. Start `./install.sh --key-only` on macOS/Linux or
   `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
   -KeyOnly` on Windows.
8. Supply exactly one key line to the installer's standard input. With an
   attached terminal, the installer reads it with echo disabled. If the Agent
   must collect it in chat, it asks once and passes the value through the
   running process's standard input, never through a command argument or a
   printed environment assignment.
9. Wait for the installer's verification to finish. Do not report success from
   an archive download or binary extraction alone.

The bootstrap creates or refreshes the local identity marker only after it has
validated the staged source. Temporary bootstrap directories are removed on
success. On failure they are removed after the prior managed installation has
been restored, so a refresh cannot leave a partially replaced installation.

## One-Input Semantics

The key-only installer emits one prompt identifying `OPENAI_IMAGE_API_KEY` and
performs one read. The input is secret:

- Bash disables terminal echo and restores it on success, error, or interrupt.
- PowerShell uses `Read-Host -AsSecureString` for an attached terminal.
- A non-interactive standard-input line is accepted so a supervising Agent can
  feed the already collected secret without placing it in the command text.

An empty or whitespace-only key, or a key containing a NUL or line break, causes
an immediate non-zero exit. The installer does not re-prompt because that would
violate the one-input contract. The customer can explicitly rerun the original
request to try again.

The installer never prints the key, its prefix, suffix, length, hash, or a
command containing it. Diagnostic output refers to it only as `API Key`.

## Secret Storage

The key-only installer atomically replaces `.env.local` in the fixed install
directory with exactly these two logical values:

```dotenv
OPENAI_IMAGE_BASE_URL="https://api.schyler.top"
OPENAI_IMAGE_API_KEY="<customer input>"
```

Platform-appropriate escaping must round-trip the accepted one-line key. A
temporary file is created beside the destination and renamed only after a
successful write.

On macOS/Linux, `.env.local` is mode `0600`. On Windows, it is stored under the
current user's Local AppData directory and its ACL is restricted to the current
user, SYSTEM, and administrators when the platform permits it. A failure to
write or secure the file is fatal.

The key is not copied into `config.toml`, README output, verification logs,
process arguments, Git remotes, or Release downloads. `.env.local` remains
ignored by Git.

## Codex Configuration

The installer writes the platform runner, not the binary and not a key, to the
standard Codex configuration file:

- macOS/Linux: `$HOME/.codex/config.toml`
- Windows: `$HOME\.codex\config.toml`

The resulting entries are:

```toml
[mcp_servers.image2]
command = "/absolute/path/to/scripts/run-image2-mcp.sh"
```

or:

```toml
[mcp_servers.image2]
command = "powershell.exe"
args = ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "C:\\absolute\\path\\to\\scripts\\run-image2-mcp.ps1"]
```

Replacement is limited to the `image2` MCP namespace: the exact
`[mcp_servers.image2]` table and any descendant tables whose names begin with
`[mcp_servers.image2.`. Other MCP servers, top-level settings, comments, and
ordering remain intact. The operation leaves exactly one root
`[mcp_servers.image2]` table.

Configuration is written through a temporary file in the same directory and
renamed only after validation. If parsing or replacement cannot be completed
unambiguously, the installer fails and leaves the original file unchanged. It
must not solve an ambiguous file by replacing all of `config.toml`.

## Release Download

Key-only mode selects an asset from normalized platform values:

| Host | Accepted architecture names | Release asset |
| --- | --- | --- |
| macOS | `arm64`, `aarch64` | `image2-mcp_darwin_arm64.tar.gz` |
| macOS | `x86_64`, `amd64` | `image2-mcp_darwin_amd64.tar.gz` |
| Linux | `arm64`, `aarch64` | `image2-mcp_linux_arm64.tar.gz` |
| Linux | `x86_64`, `amd64` | `image2-mcp_linux_amd64.tar.gz` |
| Windows | `ARM64` | `image2-mcp_windows_arm64.zip` |
| Windows | `AMD64` | `image2-mcp_windows_amd64.zip` |

The download always uses the fixed repository slug. It is staged in a temporary
directory, extracted, checked for the expected binary name, and only then moved
into `dist/`. An HTTP error, missing asset, invalid archive, missing executable,
or unsupported platform is fatal. The previous working binary, when present,
is preserved until the replacement is ready.

## Verification

Key-only mode performs local, non-billable checks after all writes:

1. Confirm the expected binary exists, is non-empty, and is executable on
   macOS/Linux.
2. Start the runner with closed standard input and require a clean MCP process
   startup/EOF exit, catching loader, permission, and runner-path errors.
3. Confirm the runner file exists at the absolute path written to Codex config.
4. Parse `.env.local` and confirm the base URL is exactly
   `https://api.schyler.top` and the API Key value is non-empty, without printing
   either secret input or derived key data.
5. Confirm the Codex config contains exactly one `image2` root table, references
   the expected runner, and contains no API Key.
6. Confirm unrelated config fixture coverage through automated tests for both
   Bash and PowerShell replacement behavior.

The installer prints one status line per check and exits non-zero on the first
failure. It does not call `/v1/images/generations` or `/v1/images/edits` during
installation. A real image request remains an explicit maintainer or customer
action because it can consume balance.

The Agent's final report includes the install directory, binary path, runner
path, Codex config path, fixed base URL, and a reminder to restart Codex or open
a new task. It says only that the API Key is configured; it never displays it.

## Error Handling

The workflow fails with a concrete blocker and no additional configuration
question when it encounters:

- unsupported OS or architecture;
- no network path to the fixed GitHub repository or latest Release asset;
- no Git and no supported archive download mechanism;
- a Release that lacks the detected platform asset;
- an unsafe or locally modified existing install directory that cannot be
  refreshed without data loss;
- inability to write or secure `.env.local`;
- an ambiguous or unwritable Codex configuration;
- a binary, runner, environment, or configuration verification failure.

An error message identifies the failed stage and safe retry action. It does not
ask for another URL, repository, directory, build tool, or configuration value.
The customer may fix the reported prerequisite and send the same installation
sentence again.

## Test Strategy

Implementation tests cover behavior without using a real API Key or making a
network-billed image call:

- Bash argument parsing and key-only preset behavior.
- PowerShell argument parsing and key-only preset behavior where PowerShell is
  available in CI.
- exactly one input read, blank-key rejection, and no key in captured output.
- `.env.local` escaping, atomic replacement, and Unix file mode.
- platform and architecture to asset-name mapping.
- archive download/extraction failures using local fixtures or mocked download
  commands.
- replacement of a root `image2` table and its descendant tables while
  preserving unrelated TOML content.
- first install and repeat install bootstrap paths with and without Git.
- successful non-billable runner/config verification and representative failure
  cases.
- the existing Go unit test suite and a local build before publishing the tag.

Before release, the workflow itself is verified by confirming that the
`v0.2.1` GitHub Release is public and contains all six assets. At least one
macOS installation and one Windows installation are then exercised from the
published customer sentence on machines without relying on Go.

## Non-Goals

- Supporting repositories, gateways, install paths, or MCP names other than the
  fixed values in this document.
- Installing Codex itself.
- Installing Git, Go, curl, PowerShell, or operating-system package managers.
- Supporting operating systems or architectures outside the six Release
  targets.
- Asking customers to edit TOML or environment files manually.
- Storing keys in Codex config, a global shell profile, macOS Keychain, Windows
  Credential Manager, or a hosted service.
- Automatically making a billable image request during setup.
- Migrating or refactoring unrelated installer behavior.
- Automatically pushing a tag or publishing a Release before implementation and
  tests have been reviewed.

## Delivery Order

1. Add failing installer/configuration tests for the approved behavior.
2. Add `--key-only` and `-KeyOnly` while retaining legacy modes.
3. Add `AGENT_INSTALL.md` and update customer-facing README instructions.
4. Run unit, installer, shell/static, and local bootstrap verification.
5. Merge the installation work into the fork's default branch.
6. Create and push `v0.2.1` from the reviewed default-branch commit.
7. Verify the public Release and all six assets.
8. Run clean macOS and Windows Agent-driven acceptance installations.
9. Publish the fixed one-sentence customer instruction.
