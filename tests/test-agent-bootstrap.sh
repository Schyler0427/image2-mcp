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
  "tag_name": "v0.2.1",
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

cat >"$fakebin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
url=''
out=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  https://api.github.com/repos/Schyler0427/image2-mcp/releases/tags/v0.2.1)
    cp "$BOOTSTRAP_FIXTURE_RELEASE_JSON" "$out"
    ;;
  https://github.com/Schyler0427/image2-mcp/archive/refs/tags/v0.2.1.tar.gz)
    cp "$BOOTSTRAP_FIXTURE_SOURCE_ARCHIVE" "$out"
    ;;
  *)
    exit 22
    ;;
esac
CURL
chmod +x "$fakebin/curl"

make_source_archive() {
  local name="$1" version="$2" mode="${3:-ok}" tree archive
  tree="$tmp/sources/$name/image2-mcp-0.2.1"
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
IFS= read -r fixture_key || exit 65
[[ "$fixture_key" =~ [^[:space:]] ]] || exit 66
printf 'OPENAI_IMAGE_BASE_URL=https://api.schyler.top\nOPENAI_IMAGE_API_KEY=stored\n' >.env.local
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
  esac
  tar -czf "$archive" -C "$tmp/sources/$name" image2-mcp-0.2.1
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

v1_archive="$(make_source_archive v1 version-one)"
v2_archive="$(make_source_archive v2 version-two collision)"
fail_archive="$(make_source_archive fail version-failing fail)"
symlink_archive="$(make_source_archive symlink version-symlink symlink)"
invalid_archive="$(make_source_archive invalid version-invalid invalid)"

# First install and clean repeat use only fixed HOME-derived targets.
clean_home="$tmp/clean-home"
mkdir -p "$clean_home/.codex"
printf 'original config\n' >"$clean_home/.codex/config.toml"
run_bootstrap "$clean_home" "$v1_archive" "$tmp/first.log" || fail 'first install failed'
clean_target="$clean_home/.local/share/image2-mcp"
[[ "$(cat "$clean_target/version.txt")" == 'version-one' ]] || fail 'first install source is wrong'
[[ "$(cat "$clean_target/.image2-mcp-managed")" == 'Schyler0427/image2-mcp' ]] || fail 'managed marker is wrong'
assert_contains "$tmp/first.log" 'Verification: OK'
assert_not_contains "$tmp/first.log" 'fixture-key-redacted'

run_bootstrap "$clean_home" "$v2_archive" "$tmp/clean-repeat.log" || fail 'clean repeat failed'
[[ "$(cat "$clean_target/version.txt")" == 'version-two' ]] || fail 'clean repeat did not activate new source'
clean_backup="$(find_previous_backup "$clean_home/.local/share" | sed -n '1p')"
[[ -n "$clean_backup" && -d "$clean_backup" ]] || fail 'clean repeat did not retain complete backup'
[[ "$(cat "$clean_backup/version.txt")" == 'version-one' ]] || fail 'clean repeat backup is not the old target'
assert_contains "$tmp/clean-repeat.log" 'Previous installation retained at:'
assert_contains "$tmp/clean-repeat.log" 'Previous local and customer content is not active in the refreshed target.'

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
run_bootstrap "$git_home" "$v2_archive" "$tmp/git-repeat.log" || fail 'Git repeat failed'
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

printf 'PASS: Bash Agent bootstrap helper\n'
