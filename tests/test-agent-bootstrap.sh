#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="$root/scripts/bootstrap-agent-install.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { grep -Fq "$2" "$1" || fail "$1 is missing expected text"; }
assert_not_contains() { ! grep -Fq "$2" "$1" || fail "$1 contains secret text"; }

[[ -x "$helper" ]] || fail 'Bash Agent bootstrap helper is missing or not executable'

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fakebin="$tmp/bin"
mkdir -p "$fakebin" "$tmp/sources"

release_json="$tmp/release.json"
cat >"$release_json" <<'JSON'
{
  "tag_name": "v0.3.1",
  "draft": false,
  "prerelease": false,
  "assets": [
    {"name": "image2-mcp_darwin_arm64.tar.gz"},
    {"name": "image2-mcp_darwin_amd64.tar.gz"},
    {"name": "image2-mcp_linux_arm64.tar.gz"},
    {"name": "image2-mcp_linux_amd64.tar.gz"},
    {"name": "image2-mcp_windows_arm64.zip"},
    {"name": "image2-mcp_windows_amd64.zip"}
  ]
}
JSON

release_page="$tmp/release.html"
cat >"$release_page" <<'HTML'
<title>Release v0.3.1 · Schyler0427/image2-mcp · GitHub</title>
HTML
release_assets_page="$tmp/release-assets.html"
cat >"$release_assets_page" <<'HTML'
<a href="/Schyler0427/image2-mcp/releases/download/v0.3.1/image2-mcp_darwin_arm64.tar.gz">image2-mcp_darwin_arm64.tar.gz</a>
<a href="/Schyler0427/image2-mcp/releases/download/v0.3.1/image2-mcp_darwin_amd64.tar.gz">image2-mcp_darwin_amd64.tar.gz</a>
<a href="/Schyler0427/image2-mcp/releases/download/v0.3.1/image2-mcp_linux_arm64.tar.gz">image2-mcp_linux_arm64.tar.gz</a>
<a href="/Schyler0427/image2-mcp/releases/download/v0.3.1/image2-mcp_linux_amd64.tar.gz">image2-mcp_linux_amd64.tar.gz</a>
<a href="/Schyler0427/image2-mcp/releases/download/v0.3.1/image2-mcp_windows_arm64.zip">image2-mcp_windows_arm64.zip</a>
<a href="/Schyler0427/image2-mcp/releases/download/v0.3.1/image2-mcp_windows_amd64.zip">image2-mcp_windows_amd64.zip</a>
HTML

cat >"$fakebin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${BOOTSTRAP_FIXTURE_NETWORK_LOG:-}" ]]; then
  printf '%s\n' "$*" >>"$BOOTSTRAP_FIXTURE_NETWORK_LOG"
fi
url=''
out=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    --retry|--retry-delay|--connect-timeout|--max-time) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
  case "$url" in
    https://api.github.com/repos/Schyler0427/image2-mcp/releases/tags/v0.3.1)
    if [[ "${BOOTSTRAP_FIXTURE_RELEASE_API_FAIL:-0}" == 1 ]]; then
      exit 22
    fi
    cp "$BOOTSTRAP_FIXTURE_RELEASE_JSON" "$out"
    ;;
  https://github.com/Schyler0427/image2-mcp/releases/tag/v0.3.1)
    if [[ "${BOOTSTRAP_FIXTURE_RELEASE_PAGE_FAIL:-0}" == 1 ]]; then
      exit 22
    fi
    cp "$BOOTSTRAP_FIXTURE_RELEASE_PAGE" "$out"
    ;;
  https://github.com/Schyler0427/image2-mcp/releases/expanded_assets/v0.3.1)
    cp "$BOOTSTRAP_FIXTURE_RELEASE_ASSETS_PAGE" "$out"
    ;;
  https://github.com/Schyler0427/image2-mcp/archive/refs/tags/v0.3.1.tar.gz)
    if [[ -n "${BOOTSTRAP_FIXTURE_SOURCE_DOWNLOAD_MARKER:-}" ]]; then
      : >"$BOOTSTRAP_FIXTURE_SOURCE_DOWNLOAD_MARKER"
    fi
    cp "$BOOTSTRAP_FIXTURE_SOURCE_ARCHIVE" "$out"
    if [[ -f "$HOME/.fixture-signal-int-on-source" ]]; then
      kill -INT "$PPID"
      sleep 1
    fi
    ;;
  *)
    exit 22
    ;;
esac
CURL
chmod +x "$fakebin/curl"

cat >"$fakebin/git" <<'GIT'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${BOOTSTRAP_FIXTURE_BLOCK_GIT:-0}" == 1 ]]; then
  exit 97
fi
if [[ -n "${BOOTSTRAP_FIXTURE_GIT_TOPLEVEL:-}" &&
      "$*" == *"rev-parse --show-toplevel"* ]]; then
  printf '%s\n' "$BOOTSTRAP_FIXTURE_GIT_TOPLEVEL"
  exit 0
fi
exec /usr/bin/git "$@"
GIT
chmod +x "$fakebin/git"

cat >"$fakebin/mv" <<'MV'
#!/usr/bin/env bash
set -euo pipefail
source_path=''
destination=''
for argument in "$@"; do
  source_path="$destination"
  destination="$argument"
done
if [[ -f "$HOME/.fixture-fail-target-restore" &&
      "$source_path" == */image2-mcp.backup.*/previous &&
      "$destination" == */image2-mcp ]]; then
  exit 73
fi
if [[ -f "$HOME/.fixture-fail-old-target-move" &&
      "$source_path" == */image2-mcp &&
      "$destination" == */image2-mcp.backup.*/previous ]]; then
  exit 75
fi
/bin/mv "$@"
if [[ -f "$HOME/.fixture-signal-after-old-move" &&
      "$destination" == */image2-mcp.backup.*/previous ]]; then
  kill -TERM "$PPID"
  sleep 1
fi
if [[ -f "$HOME/.fixture-signal-during-rollback" &&
      "$destination" == */.image2-mcp-bootstrap.*/failed-target ]]; then
  kill -TERM "$PPID"
  sleep 1
fi
MV
chmod +x "$fakebin/mv"

cat >"$fakebin/cp" <<'CP'
#!/usr/bin/env bash
set -euo pipefail
source_path=''
destination=''
for argument in "$@"; do
  source_path="$destination"
  destination="$argument"
done
if [[ -f "$HOME/.fixture-fail-config-restore" &&
      "$source_path" == */.image2-mcp-bootstrap.*/config.toml.before &&
      "$destination" == */.codex/config.toml ]]; then
  exit 74
fi
/bin/cp "$@"
CP
chmod +x "$fakebin/cp"

cat >"$fakebin/rm" <<'RM'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${BOOTSTRAP_FIXTURE_FAIL_TXN_CLEANUP:-0}" == 1 ]]; then
  for argument in "$@"; do
    case "$argument" in
      */.image2-mcp-bootstrap.*) exit 76 ;;
    esac
  done
fi
/bin/rm "$@"
RM
chmod +x "$fakebin/rm"

make_source_archive() {
  local name="$1" version="$2" mode="${3:-ok}" tree archive
  tree="$tmp/sources/$name/image2-mcp-0.3.1"
  archive="$tmp/sources/$name.tar.gz"
  mkdir -p "$tree/scripts"
  printf 'module fixture\n' >"$tree/go.mod"
  printf '%s\n' "$version" >"$tree/version.txt"
  printf 'placeholder\n' >"$tree/install.ps1"
  printf 'placeholder\n' >"$tree/scripts/run-image2-mcp.sh"
  cat >"$tree/install.sh" <<'INSTALL'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == '--key-only' ]] || exit 64
if [[ ! -f .env.local ]]; then
  printf 'OPENAI_IMAGE_API_KEY: ' >&2
  IFS= read -r fixture_key || exit 65
  printf '\n' >&2
  [[ "$fixture_key" =~ [^[:space:]] ]] || exit 66
  printf 'OPENAI_IMAGE_BASE_URL=https://api.schyler.top\nOPENAI_IMAGE_API_KEY=stored\n' >.env.local
else
  printf '==> Existing API Key configuration found; reusing it.\n'
fi
chmod 600 .env.local
mkdir -p dist "$HOME/.codex"
printf 'fixture binary\n' >dist/image2-mcp
printf '[mcp_servers.image2]\ncommand = "fixture"\n' >"$HOME/.codex/config.toml"
if [[ -f .fixture-install-fail ]]; then
  exit 41
fi
printf 'Verification: OK\n'
INSTALL
  chmod +x "$tree/install.sh"
  case "$mode" in
    collision)
      mkdir -p "$tree/customer-prefix" "$tree/collision"
      printf 'new prefix content\n' >"$tree/customer-prefix/child.txt"
      printf 'new tracked content\n' >"$tree/collision/ignored.txt"
      ;;
    fail)
      : >"$tree/.fixture-install-fail"
      ;;
    symlink)
      ln -s ../../outside "$tree/repository-link"
      ;;
    invalid)
      rm -f "$tree/go.mod"
      ;;
    missing-runner)
      rm -f "$tree/scripts/run-image2-mcp.sh"
      ;;
  esac
  tar -czf "$archive" -C "$tmp/sources/$name" image2-mcp-0.3.1
  printf '%s\n' "$archive"
}

make_canonical_duplicate_archive() {
  local base_archive="$1" plain="$tmp/sources/canonical-duplicate.tar"
  local archive="$tmp/sources/canonical-duplicate.tar.gz"
  local file_tree="$tmp/sources/canonical-file" directory_tree="$tmp/sources/canonical-directory"
  gzip -dc "$base_archive" >"$plain"
  mkdir -p "$file_tree/image2-mcp-0.3.1" "$directory_tree/image2-mcp-0.3.1/canonical-path"
  printf 'file at canonical path\n' >"$file_tree/image2-mcp-0.3.1/canonical-path"
  tar -rf "$plain" -C "$file_tree" image2-mcp-0.3.1/canonical-path
  tar -rf "$plain" -C "$directory_tree" image2-mcp-0.3.1/canonical-path
  gzip -c "$plain" >"$archive"
  printf '%s\n' "$archive"
}

make_repeated_slash_archive() {
  local base_archive="$1" plain="$tmp/sources/repeated-slash.tar"
  local archive="$tmp/sources/repeated-slash.tar.gz" tree="$tmp/sources/repeated-slash"
  gzip -dc "$base_archive" >"$plain"
  mkdir -p "$tree/image2-mcp-0.3.1/repeated"
  printf 'repeated slash path\n' >"$tree/image2-mcp-0.3.1/repeated/path.txt"
  tar -rf "$plain" -C "$tree" image2-mcp-0.3.1//repeated/path.txt
  gzip -c "$plain" >"$archive"
  printf '%s\n' "$archive"
}

make_case_ambiguous_archive() {
  local base_archive="$1" plain="$tmp/sources/case-ambiguous.tar"
  local archive="$tmp/sources/case-ambiguous.tar.gz"
  local upper_tree="$tmp/sources/case-upper" lower_tree="$tmp/sources/case-lower"
  gzip -dc "$base_archive" >"$plain"
  mkdir -p "$upper_tree/image2-mcp-0.3.1" "$lower_tree/image2-mcp-0.3.1"
  printf 'upper case path\n' >"$upper_tree/image2-mcp-0.3.1/CasePath.txt"
  printf 'lower case path\n' >"$lower_tree/image2-mcp-0.3.1/casepath.txt"
  tar -rf "$plain" -C "$upper_tree" image2-mcp-0.3.1/CasePath.txt
  tar -rf "$plain" -C "$lower_tree" image2-mcp-0.3.1/casepath.txt
  gzip -c "$plain" >"$archive"
  printf '%s\n' "$archive"
}

run_bootstrap() {
  local home="$1" archive="$2" output="$3"
  printf '%s\n' 'fixture-key-redacted' |
    HOME="$home" PATH="$fakebin:$PATH" \
    BOOTSTRAP_FIXTURE_RELEASE_JSON="$release_json" \
    BOOTSTRAP_FIXTURE_SOURCE_ARCHIVE="$archive" \
    "$helper" >"$output" 2>&1
}

run_bootstrap_without_git() {
  local home="$1" archive="$2" output="$3" source_marker="${4:-}"
  printf '%s\n' 'fixture-key-redacted' |
    HOME="$home" PATH="$fakebin:$PATH" \
    BOOTSTRAP_FIXTURE_BLOCK_GIT=1 \
    BOOTSTRAP_FIXTURE_SOURCE_DOWNLOAD_MARKER="$source_marker" \
    BOOTSTRAP_FIXTURE_RELEASE_JSON="$release_json" \
    BOOTSTRAP_FIXTURE_SOURCE_ARCHIVE="$archive" \
    "$helper" >"$output" 2>&1
}

run_bootstrap_with_git_toplevel() {
  local home="$1" archive="$2" output="$3" git_toplevel="$4" source_marker="$5"
  printf '%s\n' 'fixture-key-redacted' |
    HOME="$home" PATH="$fakebin:$PATH" \
    BOOTSTRAP_FIXTURE_GIT_TOPLEVEL="$git_toplevel" \
    BOOTSTRAP_FIXTURE_SOURCE_DOWNLOAD_MARKER="$source_marker" \
    BOOTSTRAP_FIXTURE_RELEASE_JSON="$release_json" \
    BOOTSTRAP_FIXTURE_SOURCE_ARCHIVE="$archive" \
    "$helper" >"$output" 2>&1
}

run_bootstrap_with_cleanup_failure() {
  local home="$1" archive="$2" output="$3"
  printf '%s\n' 'fixture-key-redacted' |
    HOME="$home" PATH="$fakebin:$PATH" \
    BOOTSTRAP_FIXTURE_FAIL_TXN_CLEANUP=1 \
    BOOTSTRAP_FIXTURE_RELEASE_JSON="$release_json" \
    BOOTSTRAP_FIXTURE_SOURCE_ARCHIVE="$archive" \
    "$helper" >"$output" 2>&1
}

run_bootstrap_expect_failure() {
  local home="$1" archive="$2" output="$3"
  if run_bootstrap "$home" "$archive" "$output"; then
    fail 'bootstrap unexpectedly succeeded'
  fi
  assert_not_contains "$output" 'fixture-key-redacted'
}

find_previous_backup() {
  local parent="$1"
  find "$parent" -mindepth 2 -maxdepth 2 -type d -name previous \
    -path '*/image2-mcp.backup.*/previous' -print
}

make_git_target() {
  local git_target="$1"
  mkdir -p "$git_target/scripts"
  cp "$root/install.sh" "$git_target/install.sh"
  cp "$root/install.ps1" "$git_target/install.ps1"
  cp "$root/go.mod" "$git_target/go.mod"
  printf 'ownership sentinel\n' >"$git_target/customer.txt"
  git -C "$git_target" init -q
  git -C "$git_target" config user.email fixture@example.invalid
  git -C "$git_target" config user.name fixture
  git -C "$git_target" remote add origin https://github.com/Schyler0427/image2-mcp.git
  git -C "$git_target" add .
  git -C "$git_target" commit -qm ownership-fixture
}

assert_git_ownership_refusal() {
  local name="$1" home="$2" archive="$3" output="$4"
  local git_target="$home/.local/share/image2-mcp" source_marker="$home/.fixture-source-download"
  local sentinel_before
  sentinel_before="$(cksum "$git_target/customer.txt")"
  if run_bootstrap_without_git "$home" "$archive" "$output" "$source_marker"; then
    fail "$name Git target unexpectedly succeeded"
  fi
  assert_contains "$output" 'existing Git target'
  [[ ! -e "$source_marker" ]] || fail "$name downloaded the source before refusing"
  [[ "$(cksum "$git_target/customer.txt")" == "$sentinel_before" ]] || fail "$name changed the target"
  assert_not_contains "$output" 'OPENAI_IMAGE_API_KEY:'
}

v1_archive="$(make_source_archive v1 version-one)"
v2_archive="$(make_source_archive v2 version-two collision)"
fail_archive="$(make_source_archive fail version-failing fail)"
symlink_archive="$(make_source_archive symlink version-symlink symlink)"
invalid_archive="$(make_source_archive invalid version-invalid invalid)"
missing_runner_archive="$(make_source_archive missing-runner version-missing-runner missing-runner)"
canonical_duplicate_archive="$(make_canonical_duplicate_archive "$v1_archive")"
repeated_slash_archive="$(make_repeated_slash_archive "$v1_archive")"
case_ambiguous_archive="$(make_case_ambiguous_archive "$v1_archive")"

# The public pages are the fast path. A successful page gate must not spend
# time on the API, and metadata requests must be single-attempt and bounded.
page_first_home="$tmp/page-first-home"
page_first_log="$tmp/page-first.log"
page_first_network="$tmp/page-first-network.log"
if ! printf '%s\n' 'fixture-key-redacted' |
  HOME="$page_first_home" PATH="$fakebin:$PATH" \
  BOOTSTRAP_FIXTURE_NETWORK_LOG="$page_first_network" \
  BOOTSTRAP_FIXTURE_RELEASE_JSON="$release_json" \
  BOOTSTRAP_FIXTURE_RELEASE_PAGE="$release_page" \
  BOOTSTRAP_FIXTURE_RELEASE_ASSETS_PAGE="$release_assets_page" \
  BOOTSTRAP_FIXTURE_SOURCE_ARCHIVE="$v1_archive" \
  "$helper" >"$page_first_log" 2>&1; then
  fail 'page-first bootstrap failed'
fi
assert_contains "$page_first_log" 'Checking public Release...'
assert_contains "$page_first_log" 'Downloading source package...'
assert_contains "$page_first_log" 'Preparing installation...'
assert_contains "$page_first_log" 'Installing platform binary...'
assert_contains "$page_first_log" 'Verifying local installation...'
assert_not_contains "$page_first_network" 'api.github.com'
[[ "$(grep -c '/releases/tag/v0.3.1' "$page_first_network")" -eq 1 ]] || fail 'Release page was retried'
[[ "$(grep -c '/releases/expanded_assets/v0.3.1' "$page_first_network")" -eq 1 ]] || fail 'assets page was retried'
grep -Fq -- '--connect-timeout 5 --max-time 15' "$page_first_network" || fail 'metadata timeout is not bounded'
grep -Fq -- '--connect-timeout 10 --max-time 60 https://github.com/Schyler0427/image2-mcp/archive/refs/tags/v0.3.1.tar.gz' \
  "$page_first_network" || fail 'source timeout is not bounded'

# If the public page is unavailable, the helper makes one short API fallback.
api_fallback_home="$tmp/api-fallback-home"
api_fallback_log="$tmp/api-fallback.log"
api_fallback_network="$tmp/api-fallback-network.log"
if ! printf '%s\n' 'fixture-key-redacted' |
  HOME="$api_fallback_home" PATH="$fakebin:$PATH" \
  BOOTSTRAP_FIXTURE_RELEASE_PAGE_FAIL=1 \
  BOOTSTRAP_FIXTURE_NETWORK_LOG="$api_fallback_network" \
  BOOTSTRAP_FIXTURE_RELEASE_JSON="$release_json" \
  BOOTSTRAP_FIXTURE_RELEASE_PAGE="$release_page" \
  BOOTSTRAP_FIXTURE_RELEASE_ASSETS_PAGE="$release_assets_page" \
  BOOTSTRAP_FIXTURE_SOURCE_ARCHIVE="$v1_archive" \
  "$helper" >"$api_fallback_log" 2>&1; then
  fail 'page failure did not recover through the API'
fi
assert_contains "$api_fallback_log" 'Verification: OK'
[[ "$(grep -c '/releases/tag/v0.3.1' "$api_fallback_network")" -eq 1 ]] || fail 'failed Release page was retried'
[[ "$(grep -c 'api.github.com' "$api_fallback_network")" -eq 1 ]] || fail 'API fallback was not called exactly once'
if grep -Fq '/releases/expanded_assets/v0.3.1' "$api_fallback_network"; then
  fail 'assets page was called after Release page failure'
fi

# Release validation has a POSIX-tool fallback when Python and jq are absent.
json_tools="$tmp/json-tools"
mkdir -p "$json_tools" "$tmp/json-txn"
ln -s "$(command -v awk)" "$json_tools/awk"
ln -s "$(command -v grep)" "$json_tools/grep"
ln -s "$(command -v tr)" "$json_tools/tr"
shell_bin="$(command -v bash)"
PATH="$json_tools" "$shell_bin" -c 'source "$1"; txn="$2"; validate_release_json "$3"' \
  bash "$helper" "$tmp/json-txn" "$release_json" || fail 'JSON validation fallback failed without Python or jq'
draft_release_json="$tmp/release-draft.json"
sed 's/"draft": false/"draft": true/' "$release_json" >"$draft_release_json"
if PATH="$json_tools" "$shell_bin" -c 'source "$1"; txn="$2"; validate_release_json "$3"' \
  bash "$helper" "$tmp/json-txn" "$draft_release_json" >/dev/null 2>&1; then
  fail 'JSON validation fallback accepted a draft Release'
fi

# A blocked or rate-limited API can fall back to the public Release pages
# without weakening the exact tag, publication, or six-asset checks.
invalid_release_json="$tmp/release-invalid.json"
printf '{}\n' >"$invalid_release_json"
mkdir -p "$tmp/page-txn"
PATH="$fakebin:$PATH" \
  BOOTSTRAP_FIXTURE_RELEASE_API_FAIL=1 \
  BOOTSTRAP_FIXTURE_RELEASE_JSON="$invalid_release_json" \
  BOOTSTRAP_FIXTURE_RELEASE_PAGE="$release_page" \
  BOOTSTRAP_FIXTURE_RELEASE_ASSETS_PAGE="$release_assets_page" \
  "$shell_bin" -c 'source "$1"; txn="$2"; validate_release_gate "$3"' \
  bash "$helper" "$tmp/page-txn" "$invalid_release_json" ||
  fail 'public Release page fallback failed'

# The main bootstrap must also fall back when the API download itself returns
# an HTTP failure; validating an already-downloaded invalid JSON is not enough.
api_failure_home="$tmp/api-failure-home"
if ! printf '%s\n' 'fixture-key-redacted' |
  HOME="$api_failure_home" PATH="$fakebin:$PATH" \
  BOOTSTRAP_FIXTURE_RELEASE_API_FAIL=1 \
  BOOTSTRAP_FIXTURE_RELEASE_JSON="$release_json" \
  BOOTSTRAP_FIXTURE_RELEASE_PAGE="$release_page" \
  BOOTSTRAP_FIXTURE_RELEASE_ASSETS_PAGE="$release_assets_page" \
  BOOTSTRAP_FIXTURE_SOURCE_ARCHIVE="$v1_archive" \
  "$helper" >"$tmp/api-failure.log" 2>&1; then
  fail 'API download failure did not recover through the public Release pages'
fi
assert_contains "$tmp/api-failure.log" 'Verification: OK'
assert_not_contains "$tmp/api-failure.log" 'fixture-key-redacted'
[[ -f "$api_failure_home/.local/share/image2-mcp/dist/image2-mcp" ]] ||
  fail 'API download fallback did not complete installation'

# Case-ambiguous archives are rejected before first-install target mutation.
case_ambiguous_home="$tmp/case-ambiguous-home"
run_bootstrap_expect_failure "$case_ambiguous_home" "$case_ambiguous_archive" "$tmp/source-case-ambiguous.log"
assert_contains "$tmp/source-case-ambiguous.log" 'case-insensitive duplicate canonical path'
[[ ! -e "$case_ambiguous_home/.local/share/image2-mcp" ]] || fail 'case-ambiguous archive created a target'

# Required source files are validated before the helper reads the API Key.
missing_runner_home="$tmp/missing-runner-home"
run_bootstrap_expect_failure "$missing_runner_home" "$missing_runner_archive" "$tmp/missing-runner.log"
assert_contains "$tmp/missing-runner.log" 'missing scripts/run-image2-mcp.sh'
assert_not_contains "$tmp/missing-runner.log" 'OPENAI_IMAGE_API_KEY:'
[[ ! -e "$missing_runner_home/.local/share/image2-mcp" ]] || fail 'missing-runner archive created a target'

# Handled signals terminate with their conventional status instead of resuming.
signal_home="$tmp/signal-home"
mkdir -p "$signal_home"
: >"$signal_home/.fixture-signal-int-on-source"
if run_bootstrap "$signal_home" "$v1_archive" "$tmp/signal-int.log"; then
  signal_status=0
else
  signal_status=$?
fi
[[ "$signal_status" -eq 130 ]] || fail "SIGINT exited with $signal_status instead of 130"
[[ ! -e "$signal_home/.local/share/image2-mcp" ]] || fail 'SIGINT continued into target activation'
assert_not_contains "$tmp/signal-int.log" 'fixture-key-redacted'

# First install and clean repeat use only fixed HOME-derived targets.
clean_home="$tmp/clean-home"
mkdir -p "$clean_home/.codex"
printf 'original config\n' >"$clean_home/.codex/config.toml"
run_bootstrap "$clean_home" "$v1_archive" "$tmp/first.log" || fail 'first install failed'
clean_target="$clean_home/.local/share/image2-mcp"
[[ "$(cat "$clean_target/version.txt")" == 'version-one' ]] || fail 'first install source is wrong'
[[ "$(cat "$clean_target/.image2-mcp-managed")" == 'Schyler0427/image2-mcp' ]] || fail 'managed marker is wrong'
assert_contains "$tmp/first.log" 'Verification: OK'
assert_contains "$tmp/first.log" 'OPENAI_IMAGE_API_KEY:'
assert_not_contains "$tmp/first.log" 'fixture-key-redacted'

run_bootstrap "$clean_home" "$v2_archive" "$tmp/clean-repeat.log" || fail 'clean repeat failed'
[[ "$(cat "$clean_target/version.txt")" == 'version-two' ]] || fail 'clean repeat did not activate new source'
assert_not_contains "$tmp/clean-repeat.log" 'OPENAI_IMAGE_API_KEY:'
assert_contains "$tmp/clean-repeat.log" 'Existing API Key configuration found; reusing it.'
assert_contains "$clean_target/.env.local" 'OPENAI_IMAGE_API_KEY=stored'
clean_backup="$(find_previous_backup "$clean_home/.local/share" | sed -n '1p')"
[[ -n "$clean_backup" && -d "$clean_backup" ]] || fail 'clean repeat did not retain complete backup'
[[ "$(cat "$clean_backup/version.txt")" == 'version-one' ]] || fail 'clean repeat backup is not the old target'
assert_contains "$tmp/clean-repeat.log" 'Previous installation retained at:'
assert_contains "$tmp/clean-repeat.log" 'Previous local and customer content is not active in the refreshed target.'

# A completed repeat with failed transaction cleanup reports every retained path.
cleanup_home="$tmp/cleanup-failure-home"
run_bootstrap "$cleanup_home" "$v1_archive" "$tmp/cleanup-first.log" || fail 'cleanup failure setup failed'
if run_bootstrap_with_cleanup_failure "$cleanup_home" "$v2_archive" "$tmp/cleanup-failure.log"; then
  fail 'transaction cleanup failure unexpectedly succeeded'
fi
cleanup_backup="$(find_previous_backup "$cleanup_home/.local/share" | sed -n '1p')"
[[ -n "$cleanup_backup" ]] || fail 'transaction cleanup failure discarded previous installation'
assert_contains "$tmp/cleanup-failure.log" 'recovery cleanup failed'
assert_contains "$tmp/cleanup-failure.log" 'Transaction evidence retained at:'
assert_contains "$tmp/cleanup-failure.log" "Previous installation retained at: $cleanup_backup"
assert_not_contains "$tmp/cleanup-failure.log" 'fixture-key-redacted'

# Exact-remote Git repeat preserves dirty/local/ignored/untracked state in the reported backup.
git_home="$tmp/git-home"
git_target="$git_home/.local/share/image2-mcp"
mkdir -p "$git_target/scripts" "$git_home/.codex"
cp "$root/install.sh" "$git_target/install.sh"
cp "$root/install.ps1" "$git_target/install.ps1"
cp "$root/go.mod" "$git_target/go.mod"
printf 'tracked base\n' >"$git_target/tracked.txt"
printf 'collision/ignored.txt\n' >"$git_target/.gitignore"
git -C "$git_target" init -q
git -C "$git_target" config user.email fixture@example.invalid
git -C "$git_target" config user.name fixture
git -C "$git_target" remote add origin https://github.com/Schyler0427/image2-mcp.git
git -C "$git_target" add .
git -C "$git_target" commit -qm base
printf 'local commit\n' >"$git_target/local-commit.txt"
git -C "$git_target" add local-commit.txt
git -C "$git_target" commit -qm local
old_git_head="$(git -C "$git_target" rev-parse HEAD)"
printf 'dirty tracked\n' >>"$git_target/tracked.txt"
mkdir -p "$git_target/collision" "$git_target/ordinary" "$git_target/empty-dir"
printf 'ignored customer content\n' >"$git_target/collision/ignored.txt"
printf 'ordinary customer content\n' >"$git_target/ordinary/customer.txt"
printf 'prefix customer file\n' >"$git_target/customer-prefix"
ln -s ordinary/customer.txt "$git_target/customer-link"
run_bootstrap_without_git "$git_home" "$v2_archive" "$tmp/git-repeat.log" || fail 'Git repeat failed without Git'
git_backup="$(find_previous_backup "$git_home/.local/share" | sed -n '1p')"
[[ -n "$git_backup" && -d "$git_backup/.git" ]] || fail 'Git repeat did not retain Git backup'
[[ "$(git -C "$git_backup" rev-parse HEAD)" == "$old_git_head" ]] || fail 'local commit was not retained'
assert_contains "$git_backup/tracked.txt" 'dirty tracked'
assert_contains "$git_backup/collision/ignored.txt" 'ignored customer content'
assert_contains "$git_backup/ordinary/customer.txt" 'ordinary customer content'
[[ -d "$git_backup/empty-dir" ]] || fail 'empty customer directory was not retained'
[[ -L "$git_backup/customer-link" && "$(readlink "$git_backup/customer-link")" == 'ordinary/customer.txt' ]] || fail 'customer symlink was not retained'
[[ -f "$git_backup/customer-prefix" ]] || fail 'prefix-colliding customer file was not retained'
assert_contains "$git_target/collision/ignored.txt" 'new tracked content'
[[ -f "$git_target/customer-prefix/child.txt" ]] || fail 'new prefix path was not activated'
assert_contains "$tmp/git-repeat.log" 'Previous local and customer content is not active in the refreshed target.'
assert_not_contains "$tmp/git-repeat.log" 'fixture-key-redacted'

# The no-Git parser refuses configuration that can redirect Git ownership before
# downloading source, reading a key, or moving the target.
bare_home="$tmp/git-bare-home"
make_git_target "$bare_home/.local/share/image2-mcp"
cat >>"$bare_home/.local/share/image2-mcp/.git/config" <<'CONFIG'
[core]
	bare = true
CONFIG
assert_git_ownership_refusal 'core.bare=true' "$bare_home" "$v2_archive" "$tmp/git-bare.log"

duplicate_bare_home="$tmp/git-duplicate-bare-home"
make_git_target "$duplicate_bare_home/.local/share/image2-mcp"
cat >>"$duplicate_bare_home/.local/share/image2-mcp/.git/config" <<'CONFIG'
[core]
	bare = false
	bare = false
CONFIG
assert_git_ownership_refusal 'duplicate core.bare' "$duplicate_bare_home" "$v2_archive" "$tmp/git-duplicate-bare.log"

worktree_home="$tmp/git-worktree-home"
make_git_target "$worktree_home/.local/share/image2-mcp"
cat >>"$worktree_home/.local/share/image2-mcp/.git/config" <<'CONFIG'
[core]
	worktree = ../elsewhere
CONFIG
assert_git_ownership_refusal 'core.worktree' "$worktree_home" "$v2_archive" "$tmp/git-worktree.log"

include_home="$tmp/git-include-home"
make_git_target "$include_home/.local/share/image2-mcp"
cat >>"$include_home/.local/share/image2-mcp/.git/config" <<'CONFIG'
[include]
	path = ../untrusted.gitconfig
CONFIG
assert_git_ownership_refusal 'include section' "$include_home" "$v2_archive" "$tmp/git-include.log"

include_if_home="$tmp/git-include-if-home"
make_git_target "$include_if_home/.local/share/image2-mcp"
cat >>"$include_if_home/.local/share/image2-mcp/.git/config" <<'CONFIG'
[includeIf "gitdir:../elsewhere/"]
	path = ../untrusted.gitconfig
CONFIG
assert_git_ownership_refusal 'includeIf section' "$include_if_home" "$v2_archive" "$tmp/git-include-if.log"

config_worktree_home="$tmp/git-config-worktree-home"
make_git_target "$config_worktree_home/.local/share/image2-mcp"
printf '[core]\n\tworktree = ../elsewhere\n' >"$config_worktree_home/.local/share/image2-mcp/.git/config.worktree"
assert_git_ownership_refusal 'config.worktree' "$config_worktree_home" "$v2_archive" "$tmp/git-config-worktree.log"

worktree_config_home="$tmp/git-worktree-config-home"
make_git_target "$worktree_config_home/.local/share/image2-mcp"
cat >>"$worktree_config_home/.local/share/image2-mcp/.git/config" <<'CONFIG'
[extensions]
	worktreeConfig = true
CONFIG
assert_git_ownership_refusal 'extensions.worktreeConfig' "$worktree_config_home" "$v2_archive" "$tmp/git-worktree-config.log"

include_trailing_home="$tmp/git-include-trailing-home"
make_git_target "$include_trailing_home/.local/share/image2-mcp"
cat >>"$include_trailing_home/.local/share/image2-mcp/.git/config" <<'CONFIG'
[include] # trailing
	path = ../untrusted.gitconfig
CONFIG
assert_git_ownership_refusal 'include section with trailing comment' "$include_trailing_home" "$v2_archive" "$tmp/git-include-trailing.log"

# A usable Git executable must prove that its normalized top-level is exactly
# the managed target; it must not fall back to config-only proof on mismatch.
git_toplevel_home="$tmp/git-toplevel-home"
git_toplevel_target="$git_toplevel_home/.local/share/image2-mcp"
make_git_target "$git_toplevel_target"
git_toplevel_sentinel="$(cksum "$git_toplevel_target/customer.txt")"
git_toplevel_source_marker="$git_toplevel_home/.fixture-source-download"
if run_bootstrap_with_git_toplevel "$git_toplevel_home" "$v2_archive" "$tmp/git-toplevel.log" \
    "$tmp/not-the-managed-target" "$git_toplevel_source_marker"; then
  fail 'mismatched Git top-level unexpectedly succeeded'
fi
assert_contains "$tmp/git-toplevel.log" 'existing Git target'
[[ ! -e "$git_toplevel_source_marker" ]] || fail 'mismatched Git top-level downloaded source before refusing'
[[ "$(cksum "$git_toplevel_target/customer.txt")" == "$git_toplevel_sentinel" ]] || fail 'mismatched Git top-level changed the target'
assert_not_contains "$tmp/git-toplevel.log" 'OPENAI_IMAGE_API_KEY:'

# A dangling .git entry must not fall through to an otherwise-valid archive
# marker. This initially fails because the installer accepts the marker.
dangling_git_home="$tmp/dangling-git-home"
dangling_git_target="$dangling_git_home/.local/share/image2-mcp"
mkdir -p "$dangling_git_target/scripts"
cp "$root/install.sh" "$dangling_git_target/install.sh"
cp "$root/install.ps1" "$dangling_git_target/install.ps1"
cp "$root/go.mod" "$dangling_git_target/go.mod"
printf 'Schyler0427/image2-mcp' >"$dangling_git_target/.image2-mcp-managed"
printf 'dangling Git sentinel\n' >"$dangling_git_target/customer.txt"
ln -s "$dangling_git_home/missing-git-directory" "$dangling_git_target/.git"
dangling_git_sentinel="$(cksum "$dangling_git_target/customer.txt")"
dangling_git_source_marker="$dangling_git_home/.fixture-source-download"
if run_bootstrap_without_git "$dangling_git_home" "$v2_archive" "$tmp/dangling-git.log" "$dangling_git_source_marker"; then
  fail 'dangling Git metadata unexpectedly fell through to archive-marker acceptance'
fi
[[ ! -e "$dangling_git_source_marker" ]] || fail 'dangling Git metadata downloaded source before refusing'
[[ "$(cksum "$dangling_git_target/customer.txt")" == "$dangling_git_sentinel" ]] || fail 'dangling Git metadata changed the target'
assert_not_contains "$tmp/dangling-git.log" 'OPENAI_IMAGE_API_KEY:'

# Ambiguous marker and target symlink are conservative, byte-preserving refusals.
ambiguous_home="$tmp/ambiguous-home"
ambiguous_target="$ambiguous_home/.local/share/image2-mcp"
mkdir -p "$ambiguous_target"
printf 'wrong/repository' >"$ambiguous_target/.image2-mcp-managed"
printf 'sentinel\n' >"$ambiguous_target/customer.txt"
tar -cf "$tmp/ambiguous-before.tar" -C "$ambiguous_home/.local/share" image2-mcp
run_bootstrap_expect_failure "$ambiguous_home" "$v2_archive" "$tmp/ambiguous.log"
tar -cf "$tmp/ambiguous-after.tar" -C "$ambiguous_home/.local/share" image2-mcp
cmp -s "$tmp/ambiguous-before.tar" "$tmp/ambiguous-after.tar" || fail 'ambiguous target changed'

symlink_home="$tmp/target-symlink-home"
mkdir -p "$symlink_home/.local/share" "$symlink_home/external-target"
printf 'external sentinel\n' >"$symlink_home/external-target/customer.txt"
ln -s "$symlink_home/external-target" "$symlink_home/.local/share/image2-mcp"
run_bootstrap_expect_failure "$symlink_home" "$v2_archive" "$tmp/target-symlink.log"
[[ -L "$symlink_home/.local/share/image2-mcp" ]] || fail 'target symlink was replaced'
assert_contains "$symlink_home/external-target/customer.txt" 'external sentinel'

# Unsafe/invalid staged sources fail before target mutation.
source_home="$tmp/source-failure-home"
run_bootstrap "$source_home" "$v1_archive" "$tmp/source-first.log" || fail 'source failure setup failed'
source_target="$source_home/.local/share/image2-mcp"
printf 'rollback sentinel\n' >"$source_target/customer.txt"
run_bootstrap_expect_failure "$source_home" "$symlink_archive" "$tmp/source-symlink.log"
assert_contains "$source_target/customer.txt" 'rollback sentinel'
[[ "$(cat "$source_target/version.txt")" == 'version-one' ]] || fail 'symlink archive changed target'
run_bootstrap_expect_failure "$source_home" "$invalid_archive" "$tmp/source-invalid.log"
assert_contains "$source_target/customer.txt" 'rollback sentinel'
run_bootstrap_expect_failure "$source_home" "$canonical_duplicate_archive" "$tmp/source-canonical-duplicate.log"
assert_contains "$tmp/source-canonical-duplicate.log" 'duplicate canonical path'
assert_contains "$source_target/customer.txt" 'rollback sentinel'
run_bootstrap_expect_failure "$source_home" "$repeated_slash_archive" "$tmp/source-repeated-slash.log"
assert_contains "$tmp/source-repeated-slash.log" 'noncanonical path'
assert_contains "$source_target/customer.txt" 'rollback sentinel'

# A signal delivered immediately after the old-target rename still restores it.
signal_race_home="$tmp/signal-race-home"
mkdir -p "$signal_race_home/.codex"
printf 'signal original config\n' >"$signal_race_home/.codex/config.toml"
run_bootstrap "$signal_race_home" "$v1_archive" "$tmp/signal-race-first.log" || fail 'signal race setup failed'
signal_race_target="$signal_race_home/.local/share/image2-mcp"
printf 'signal customer content\n' >"$signal_race_target/customer.txt"
printf 'signal prior config\n' >"$signal_race_home/.codex/config.toml"
signal_config_before="$(cksum "$signal_race_home/.codex/config.toml")"
: >"$signal_race_home/.fixture-signal-after-old-move"
if run_bootstrap "$signal_race_home" "$v2_archive" "$tmp/signal-race.log"; then
  signal_race_status=0
else
  signal_race_status=$?
fi
[[ "$signal_race_status" -eq 143 ]] || fail "rename-race TERM exited with $signal_race_status instead of 143"
[[ "$(cat "$signal_race_target/version.txt")" == 'version-one' ]] || fail 'rename-race TERM did not restore old target'
assert_contains "$signal_race_target/customer.txt" 'signal customer content'
[[ "$(cksum "$signal_race_home/.codex/config.toml")" == "$signal_config_before" ]] || fail 'rename-race TERM did not restore config'
assert_not_contains "$tmp/signal-race.log" 'fixture-key-redacted'

# Installer failure restores the full target and the exact prior Codex config.
rollback_home="$tmp/rollback-home"
mkdir -p "$rollback_home/.codex"
printf 'preinstall config\n' >"$rollback_home/.codex/config.toml"
run_bootstrap "$rollback_home" "$v1_archive" "$tmp/rollback-first.log" || fail 'rollback setup failed'
rollback_target="$rollback_home/.local/share/image2-mcp"
printf 'customer rollback content\n' >"$rollback_target/customer.txt"
printf 'prior config\n' >"$rollback_home/.codex/config.toml"
config_before="$(cksum "$rollback_home/.codex/config.toml")"
run_bootstrap_expect_failure "$rollback_home" "$fail_archive" "$tmp/installer-failure.log"
[[ "$(cat "$rollback_target/version.txt")" == 'version-one' ]] || fail 'installer failure did not restore old source'
assert_contains "$rollback_target/customer.txt" 'customer rollback content'
[[ "$(cksum "$rollback_home/.codex/config.toml")" == "$config_before" ]] || fail 'installer failure did not restore Codex config'
[[ -z "$(find_previous_backup "$rollback_home/.local/share")" ]] || fail 'failed repeat left a retained backup'
[[ -z "$(find "$rollback_home/.local/share" -maxdepth 1 -type d -name '.image2-mcp-bootstrap.*' -print)" ]] || fail 'failed repeat left transaction state'
assert_not_contains "$tmp/installer-failure.log" 'fixture-key-redacted'

# Signals arriving during EXIT rollback cannot interrupt target/config restoration.
rollback_signal_home="$tmp/rollback-signal-home"
mkdir -p "$rollback_signal_home/.codex"
printf 'rollback signal original config\n' >"$rollback_signal_home/.codex/config.toml"
run_bootstrap "$rollback_signal_home" "$v1_archive" "$tmp/rollback-signal-first.log" || fail 'rollback signal setup failed'
rollback_signal_target="$rollback_signal_home/.local/share/image2-mcp"
printf 'rollback signal customer content\n' >"$rollback_signal_target/customer.txt"
printf 'rollback signal prior config\n' >"$rollback_signal_home/.codex/config.toml"
rollback_signal_config_before="$(cksum "$rollback_signal_home/.codex/config.toml")"
: >"$rollback_signal_home/.fixture-signal-during-rollback"
if run_bootstrap "$rollback_signal_home" "$fail_archive" "$tmp/rollback-signal.log"; then
  rollback_signal_status=0
else
  rollback_signal_status=$?
fi
[[ "$rollback_signal_status" -eq 1 ]] || fail "rollback signal changed original exit status to $rollback_signal_status"
[[ "$(cat "$rollback_signal_target/version.txt")" == 'version-one' ]] || fail 'rollback signal did not restore old target'
assert_contains "$rollback_signal_target/customer.txt" 'rollback signal customer content'
[[ "$(cksum "$rollback_signal_home/.codex/config.toml")" == "$rollback_signal_config_before" ]] || fail 'rollback signal did not restore config'
[[ -z "$(find_previous_backup "$rollback_signal_home/.local/share")" ]] || fail 'rollback signal left a retained backup'
[[ -z "$(find "$rollback_signal_home/.local/share" -maxdepth 1 -type d -name '.image2-mcp-bootstrap.*' -print)" ]] || fail 'rollback signal left transaction state'
assert_not_contains "$tmp/rollback-signal.log" 'fixture-key-redacted'

# A failed initial old-target rename leaves no empty sibling backup directory.
old_move_failure_home="$tmp/old-move-failure-home"
mkdir -p "$old_move_failure_home/.codex"
printf 'old move original config\n' >"$old_move_failure_home/.codex/config.toml"
run_bootstrap "$old_move_failure_home" "$v1_archive" "$tmp/old-move-first.log" || fail 'old move failure setup failed'
old_move_failure_target="$old_move_failure_home/.local/share/image2-mcp"
printf 'old move customer content\n' >"$old_move_failure_target/customer.txt"
printf 'old move prior config\n' >"$old_move_failure_home/.codex/config.toml"
old_move_config_before="$(cksum "$old_move_failure_home/.codex/config.toml")"
: >"$old_move_failure_home/.fixture-fail-old-target-move"
if run_bootstrap "$old_move_failure_home" "$v2_archive" "$tmp/old-move-failure.log"; then
  old_move_failure_status=0
else
  old_move_failure_status=$?
fi
[[ "$old_move_failure_status" -eq 75 ]] || fail "failed old-target move exited with $old_move_failure_status instead of 75"
[[ "$(cat "$old_move_failure_target/version.txt")" == 'version-one' ]] || fail 'failed old-target move changed target'
assert_contains "$old_move_failure_target/customer.txt" 'old move customer content'
[[ "$(cksum "$old_move_failure_home/.codex/config.toml")" == "$old_move_config_before" ]] || fail 'failed old-target move changed config'
old_move_backup_dirs="$(find "$old_move_failure_home/.local/share" -maxdepth 1 -type d -name 'image2-mcp.backup.*' -print)"
[[ -z "$old_move_backup_dirs" ]] || fail 'failed old-target move left an empty backup directory'
assert_not_contains "$tmp/old-move-failure.log" 'fixture-key-redacted'

# A failed target restore retains both the previous target and transaction evidence.
target_recovery_home="$tmp/target-recovery-home"
mkdir -p "$target_recovery_home/.codex"
printf 'target recovery original config\n' >"$target_recovery_home/.codex/config.toml"
run_bootstrap "$target_recovery_home" "$v1_archive" "$tmp/target-recovery-first.log" || fail 'target recovery setup failed'
target_recovery_target="$target_recovery_home/.local/share/image2-mcp"
printf 'target recovery customer content\n' >"$target_recovery_target/customer.txt"
printf 'target recovery prior config\n' >"$target_recovery_home/.codex/config.toml"
target_recovery_config_before="$(cksum "$target_recovery_home/.codex/config.toml")"
: >"$target_recovery_home/.fixture-fail-target-restore"
run_bootstrap_expect_failure "$target_recovery_home" "$fail_archive" "$tmp/target-recovery.log"
assert_contains "$tmp/target-recovery.log" 'recovery failed'
target_recovery_backup="$(find_previous_backup "$target_recovery_home/.local/share" | sed -n '1p')"
[[ -n "$target_recovery_backup" ]] || fail 'failed target restore discarded previous-target evidence'
assert_contains "$target_recovery_backup/customer.txt" 'target recovery customer content'
target_recovery_txn="$(find "$target_recovery_home/.local/share" -maxdepth 1 -type d -name '.image2-mcp-bootstrap.*' -print | sed -n '1p')"
[[ -n "$target_recovery_txn" && -d "$target_recovery_txn/failed-target" ]] || fail 'failed target restore discarded transaction evidence'
[[ "$(cksum "$target_recovery_home/.codex/config.toml")" == "$target_recovery_config_before" ]] || fail 'target-restore failure did not restore config'
assert_not_contains "$tmp/target-recovery.log" 'fixture-key-redacted'

# A failed config restore retains its snapshot and the displaced failed target.
config_recovery_home="$tmp/config-recovery-home"
mkdir -p "$config_recovery_home/.codex"
printf 'config recovery original config\n' >"$config_recovery_home/.codex/config.toml"
run_bootstrap "$config_recovery_home" "$v1_archive" "$tmp/config-recovery-first.log" || fail 'config recovery setup failed'
config_recovery_target="$config_recovery_home/.local/share/image2-mcp"
printf 'config recovery customer content\n' >"$config_recovery_target/customer.txt"
printf 'config recovery prior config\n' >"$config_recovery_home/.codex/config.toml"
: >"$config_recovery_home/.fixture-fail-config-restore"
run_bootstrap_expect_failure "$config_recovery_home" "$fail_archive" "$tmp/config-recovery.log"
assert_contains "$tmp/config-recovery.log" 'recovery failed'
[[ "$(cat "$config_recovery_target/version.txt")" == 'version-one' ]] || fail 'config-restore failure did not restore old target'
assert_contains "$config_recovery_target/customer.txt" 'config recovery customer content'
config_recovery_txn="$(find "$config_recovery_home/.local/share" -maxdepth 1 -type d -name '.image2-mcp-bootstrap.*' -print | sed -n '1p')"
[[ -n "$config_recovery_txn" && -f "$config_recovery_txn/config.toml.before" ]] || fail 'failed config restore discarded config snapshot'
assert_contains "$config_recovery_txn/config.toml.before" 'config recovery prior config'
[[ -d "$config_recovery_txn/failed-target" ]] || fail 'failed config restore discarded failed-target evidence'
assert_not_contains "$tmp/config-recovery.log" 'fixture-key-redacted'

printf 'PASS: Bash Agent bootstrap helper\n'
