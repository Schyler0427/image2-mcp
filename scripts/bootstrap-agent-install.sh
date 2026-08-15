#!/usr/bin/env bash
set -euo pipefail

readonly_repo_url='https://github.com/Schyler0427/image2-mcp.git'
readonly_repo_slug='Schyler0427/image2-mcp'
readonly_release_api='https://api.github.com/repos/Schyler0427/image2-mcp/releases/tags/v0.2.1'
readonly_source_url='https://github.com/Schyler0427/image2-mcp/archive/refs/tags/v0.2.1.tar.gz'
readonly_source_root='image2-mcp-0.2.1'
readonly_base_url='https://api.schyler.top'

txn=''
target=''
backup_root=''
old_move_started=0
new_move_started=0
transaction_complete=0
config_file=''
config_existed=0
config_snapshot=''

fail() {
  printf 'error: %s\n' "$*" >&2
  return 1
}

terminate_from_signal() {
  local exit_status="$1"
  trap - HUP INT TERM
  exit "$exit_status"
}

platform_name() {
  case "$(uname -s)" in
    Darwin) printf 'darwin\n' ;;
    Linux) printf 'linux\n' ;;
    *) return 1 ;;
  esac
}

arch_name() {
  case "$(uname -m)" in
    arm64|aarch64) printf 'arm64\n' ;;
    x86_64|amd64) printf 'amd64\n' ;;
    *) return 1 ;;
  esac
}

download_file() {
  local url="$1" output="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fL -sS "$url" -o "$output"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$output" "$url"
  else
    fail 'curl or wget is required'
  fi
}

validate_release_json() {
  local json_file="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$json_file" <<'PY'
import json
import sys

expected = {
    "image2-mcp_darwin_arm64.tar.gz",
    "image2-mcp_darwin_amd64.tar.gz",
    "image2-mcp_linux_arm64.tar.gz",
    "image2-mcp_linux_amd64.tar.gz",
    "image2-mcp_windows_arm64.zip",
    "image2-mcp_windows_amd64.zip",
}
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    release = json.load(handle)
assets = {item.get("name") for item in release.get("assets", []) if isinstance(item, dict)}
if release.get("tag_name") != "v0.2.1" or release.get("draft") is not False or release.get("prerelease") is not False:
    raise SystemExit(1)
if not expected.issubset(assets):
    raise SystemExit(1)
PY
    return
  fi
  if command -v jq >/dev/null 2>&1; then
    jq -e '
      .tag_name == "v0.2.1" and
      .draft == false and
      .prerelease == false and
      ([.assets[].name] | contains([
        "image2-mcp_darwin_arm64.tar.gz",
        "image2-mcp_darwin_amd64.tar.gz",
        "image2-mcp_linux_arm64.tar.gz",
        "image2-mcp_linux_amd64.tar.gz",
        "image2-mcp_windows_arm64.zip",
        "image2-mcp_windows_amd64.zip"
      ]))
    ' "$json_file" >/dev/null
    return
  fi
  local compact asset json_text
  compact="$txn/release.json.compact"
  json_text="$(tr -d '[:space:]' <"$json_file")" || fail 'public Release JSON could not be read'
  printf '%s' "$json_text" >"$compact"
  [[ -n "$json_text" ]] || fail 'public Release JSON is empty'
  [[ "${json_text#\{}" != "$json_text" && "${json_text%\}}" != "$json_text" ]] ||
    fail 'public Release JSON is not an object'
  grep -Fq '"tag_name":"v0.2.1"' "$compact" || fail 'public Release tag is not v0.2.1'
  grep -Fq '"draft":false' "$compact" || fail 'public v0.2.1 Release is a draft'
  grep -Fq '"prerelease":false' "$compact" || fail 'public v0.2.1 Release is a prerelease'
  for asset in \
    'image2-mcp_darwin_arm64.tar.gz' \
    'image2-mcp_darwin_amd64.tar.gz' \
    'image2-mcp_linux_arm64.tar.gz' \
    'image2-mcp_linux_amd64.tar.gz' \
    'image2-mcp_windows_arm64.zip' \
    'image2-mcp_windows_amd64.zip'; do
    grep -Fq "\"name\":\"$asset\"" "$compact" ||
      fail "public v0.2.1 Release is missing required asset: $asset"
  done
}

validate_existing_target() {
  local expected_marker remote
  [[ ! -L "$target" ]] || fail 'managed target must not be a symlink'
  [[ -d "$target" ]] || fail 'managed target is not a directory'
  for required in install.sh install.ps1 go.mod scripts; do
    [[ -e "$target/$required" ]] || fail 'existing target is missing expected repository files'
  done

  if [[ -e "$target/.git" || -L "$target/.git" ]]; then
    [[ -d "$target/.git" && ! -L "$target/.git" ]] || fail 'existing Git metadata is not a regular directory'
    [[ -f "$target/.git/config" && ! -L "$target/.git/config" ]] || fail 'existing Git target has no readable config'
    [[ ! -e "$target/.git/config.worktree" && ! -L "$target/.git/config.worktree" ]] ||
      fail 'existing Git target has unsupported ownership configuration'
    local in_origin=0 remote_count=0 line trimmed value section section_lower key key_lower
    local bare_count=0 bare_value='' git_bin git_toplevel target_toplevel git_toplevel_normalized
    while IFS= read -r line || [[ -n "$line" ]]; do
      trimmed="${line#"${line%%[![:space:]]*}"}"
      case "$trimmed" in
        \[*)
          [[ "$trimmed" == *']' ]] || fail 'existing Git target has unsupported ownership configuration'
          section="${trimmed#\[}"
          section="${section%\]}"
          section_lower="$(LC_ALL=C printf '%s' "$section" | tr '[:upper:]' '[:lower:]')"
          case "$section_lower" in
            include*) fail 'existing Git target has unsupported ownership configuration' ;;
          esac
          if [[ "$trimmed" == '[remote "origin"]' ]]; then
            in_origin=1
          else
            in_origin=0
          fi
          ;;
      esac
      [[ "$trimmed" != \#* && "$trimmed" != \;* && -n "$trimmed" ]] || continue
      key="${trimmed%%[[:space:]=]*}"
      key_lower="$(LC_ALL=C printf '%s' "$key" | tr '[:upper:]' '[:lower:]')"
      if [[ "$section_lower" == 'core' ]]; then
        case "$key_lower" in
          worktree) fail 'existing Git target has unsupported ownership configuration' ;;
          bare)
            bare_count=$((bare_count + 1))
            value="${trimmed#*=}"
            value="${value#"${value%%[![:space:]]*}"}"
            bare_value="$(LC_ALL=C printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
            ;;
        esac
      elif [[ "$section_lower" == 'extensions' && "$key_lower" == 'worktreeconfig' ]]; then
        fail 'existing Git target has unsupported ownership configuration'
      fi
      if [[ "$in_origin" -eq 1 && "$key_lower" == 'url' && "$trimmed" == *=* ]]; then
        value="${trimmed#*=}"
        value="${value#"${value%%[![:space:]]*}"}"
        remote="$value"
        remote_count=$((remote_count + 1))
      fi
    done <"$target/.git/config"
    [[ "$bare_count" -le 1 && ( "$bare_count" -eq 0 || "$bare_value" == 'false' ) ]] ||
      fail 'existing Git target has unsupported ownership configuration'
    [[ "$remote_count" -eq 1 ]] || fail 'existing Git target has no unique origin remote'
    [[ "$remote" == "$readonly_repo_url" ]] || fail 'existing Git target origin does not match the fixed repository'
    git_bin="$(command -v git 2>/dev/null || true)"
    if [[ -n "$git_bin" && -x "$git_bin" ]] && "$git_bin" --version >/dev/null 2>&1; then
      if ! git_toplevel="$("$git_bin" -C "$target" rev-parse --show-toplevel 2>/dev/null)"; then
        fail 'existing Git target ownership cannot be proven'
      fi
      target_toplevel="$(cd "$target" && pwd -P)" || fail 'existing Git target ownership cannot be proven'
      git_toplevel_normalized="$(cd "$git_toplevel" 2>/dev/null && pwd -P)" ||
        fail 'existing Git target ownership cannot be proven'
      [[ "$git_toplevel_normalized" == "$target_toplevel" ]] ||
        fail 'existing Git target ownership cannot be proven'
    fi
    return
  fi

  [[ -f "$target/.image2-mcp-managed" && ! -L "$target/.image2-mcp-managed" ]] || fail 'existing archive target has no valid managed marker'
  expected_marker="$txn/expected-marker"
  printf '%s' "$readonly_repo_slug" >"$expected_marker"
  cmp -s "$expected_marker" "$target/.image2-mcp-managed" || fail 'existing archive target marker does not match the fixed repository'
}

validate_archive() {
  local archive="$1" entries="$txn/archive-entries" seen="$txn/archive-seen"
  local directories="$txn/archive-directories" entry canonical canonical_key type parent prior
  : >"$seen"
  : >"$directories"
  tar -tzf "$archive" >"$entries" || fail 'source archive cannot be listed'
  [[ -s "$entries" ]] || fail 'source archive is empty'
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || fail 'source archive contains an empty path'
    if LC_ALL=C printf '%s' "$entry" | grep -q '[[:cntrl:]]'; then
      fail 'source archive contains a control character in a path'
    fi
    case "$entry" in
      *'//'*) fail 'source archive contains a noncanonical path' ;;
      */) canonical="${entry%/}" ;;
      *) canonical="$entry" ;;
    esac
    [[ -n "$canonical" ]] || fail 'source archive contains a noncanonical path'
    canonical_key="$(LC_ALL=C printf '%s' "$canonical" | tr '[:upper:]' '[:lower:]')"
    case "$canonical" in
      "$readonly_source_root"|"$readonly_source_root"/*) ;;
      *) fail 'source archive contains a path outside the expected root' ;;
    esac
    case "/$canonical/" in
      */../*|*/./*) fail 'source archive contains a traversal path' ;;
    esac
    if grep -Fqx -- "$canonical_key" "$seen"; then
      fail 'source archive contains a case-insensitive duplicate canonical path'
    fi
    type="$(tar -tvzf "$archive" "$entry" 2>/dev/null | sed -n '1s/^\(.\).*$/\1/p')"
    case "$type" in
      -|d) ;;
      *) fail 'source archive contains a link or unsupported path type' ;;
    esac
    if [[ "$type" == '-' ]]; then
      while IFS= read -r prior; do
        case "$prior" in
          "$canonical_key"/*) fail 'source archive contains a file/directory prefix collision' ;;
        esac
      done <"$seen"
    else
      printf '%s\n' "$canonical_key" >>"$directories"
    fi
    printf '%s\n' "$canonical_key" >>"$seen"
    parent="$canonical_key"
    while [[ "$parent" == */* ]]; do
      parent="${parent%/*}"
      if grep -Fqx -- "$parent" "$seen"; then
        grep -Fqx -- "$parent" "$directories" || fail 'source archive contains a file/directory prefix collision'
      fi
    done
  done <"$entries"
}

validate_staged_source() {
  local stage="$1" path
  [[ -d "$stage" && ! -L "$stage" ]] || fail 'staged source root is invalid'
  [[ -f "$stage/install.sh" && ! -L "$stage/install.sh" ]] || fail 'staged source is missing install.sh'
  [[ -f "$stage/install.ps1" && ! -L "$stage/install.ps1" ]] || fail 'staged source is missing install.ps1'
  [[ -f "$stage/go.mod" && ! -L "$stage/go.mod" ]] || fail 'staged source is missing go.mod'
  [[ -d "$stage/scripts" && ! -L "$stage/scripts" ]] || fail 'staged source is missing scripts/'
  [[ -f "$stage/scripts/run-image2-mcp.sh" && ! -L "$stage/scripts/run-image2-mcp.sh" ]] || fail 'staged source is missing scripts/run-image2-mcp.sh'
  [[ -z "$(find "$stage" -type l -print -quit)" ]] || fail 'staged source contains a symlink'
  while IFS= read -r -d '' path; do
    path="${path#"$stage"/}"
    if LC_ALL=C printf '%s' "$path" | grep -q '[[:cntrl:]]'; then
      fail 'staged source contains a control character in a path'
    fi
  done < <(find "$stage" -mindepth 1 -print0)
}

snapshot_codex_config() {
  config_file="$HOME/.codex/config.toml"
  [[ ! -L "$config_file" ]] || fail 'Codex config must not be a symlink'
  config_snapshot="$txn/config.toml.before"
  if [[ -f "$config_file" ]]; then
    cp -p "$config_file" "$config_snapshot"
    config_existed=1
  elif [[ -e "$config_file" ]]; then
    fail 'Codex config path is not a regular file'
  fi
}

restore_codex_config() {
  if [[ "$config_existed" -eq 1 ]]; then
    mkdir -p "$(dirname "$config_file")"
    cp -p "$config_snapshot" "$config_file"
  else
    rm -f "$config_file"
  fi
}

finish_transaction() {
  local exit_status=$? recovery_failed=0
  trap '' HUP INT TERM
  trap - EXIT
  if [[ "$transaction_complete" -ne 1 ]]; then
    if [[ "$new_move_started" -eq 1 && ( -e "$target" || -L "$target" ) ]]; then
      if [[ -z "$txn" || ! -d "$txn" || -e "$txn/failed-target" || -L "$txn/failed-target" ]]; then
        recovery_failed=1
      elif ! mv "$target" "$txn/failed-target" 2>/dev/null; then
        recovery_failed=1
      fi
    fi
    if [[ "$old_move_started" -eq 1 && ( -e "$backup_root/previous" || -L "$backup_root/previous" ) ]]; then
      if [[ -e "$target" || -L "$target" ]]; then
        recovery_failed=1
      elif ! mv "$backup_root/previous" "$target" 2>/dev/null; then
        recovery_failed=1
      fi
    elif [[ "$old_move_started" -eq 1 && ! -e "$target" && ! -L "$target" ]]; then
      recovery_failed=1
    fi
    if [[ -n "$config_file" ]]; then
      if ! restore_codex_config 2>/dev/null; then
        recovery_failed=1
      fi
    fi
    if [[ "$old_move_started" -eq 1 && -n "$backup_root" &&
          ( -e "$backup_root" || -L "$backup_root" ) &&
          ! -e "$backup_root/previous" && ! -L "$backup_root/previous" ]]; then
      if ! rmdir "$backup_root" 2>/dev/null; then
        recovery_failed=1
      fi
    fi
  fi
  if [[ "$recovery_failed" -ne 0 ]]; then
    printf 'error: recovery failed; automatic rollback is incomplete\n' >&2
    if [[ -n "$txn" && -d "$txn" ]]; then
      printf 'Transaction evidence retained at: %s\n' "$txn" >&2
    fi
    if [[ -n "$backup_root" && ( -e "$backup_root/previous" || -L "$backup_root/previous" ) ]]; then
      printf 'Previous installation retained at: %s\n' "$backup_root/previous" >&2
    elif [[ -n "$backup_root" && ( -e "$backup_root" || -L "$backup_root" ) ]]; then
      printf 'Backup evidence retained at: %s\n' "$backup_root" >&2
    fi
    if [[ "$exit_status" -eq 0 ]]; then
      return 1
    fi
    return "$exit_status"
  fi
  if [[ -n "$txn" && -d "$txn" ]] && ! rm -rf "$txn"; then
    printf 'error: recovery cleanup failed\n' >&2
    printf 'Transaction evidence retained at: %s\n' "$txn" >&2
    if [[ -n "$backup_root" && ( -e "$backup_root/previous" || -L "$backup_root/previous" ) ]]; then
      printf 'Previous installation retained at: %s\n' "$backup_root/previous" >&2
    elif [[ -n "$backup_root" && ( -e "$backup_root" || -L "$backup_root" ) ]]; then
      printf 'Backup evidence retained at: %s\n' "$backup_root" >&2
    fi
    if [[ "$exit_status" -eq 0 ]]; then
      return 1
    fi
  fi
  return "$exit_status"
}

run_key_only_installer() {
  if ! (cd "$target" && IMAGE2_MCP_REPO="$readonly_repo_slug" ./install.sh --key-only); then
    fail 'key-only installer failed; the previous target will be restored'
  fi
}

main() {
  local os arch parent release_json archive extract stage repeat=0
  [[ -n "${HOME:-}" ]] || fail 'HOME is required'
  os="$(platform_name)" || fail 'unsupported operating system'
  arch="$(arch_name)" || fail 'unsupported architecture'
  : "$os" "$arch"

  parent="$HOME/.local/share"
  target="$parent/image2-mcp"
  mkdir -p "$parent"
  txn="$(mktemp -d "$parent/.image2-mcp-bootstrap.XXXXXX")"
  trap finish_transaction EXIT
  trap 'terminate_from_signal 129' HUP
  trap 'terminate_from_signal 130' INT
  trap 'terminate_from_signal 143' TERM

  release_json="$txn/release.json"
  download_file "$readonly_release_api" "$release_json"
  validate_release_json "$release_json" || fail 'public v0.2.1 Release gate failed'

  if [[ -e "$target" || -L "$target" ]]; then
    validate_existing_target
    repeat=1
  fi

  archive="$txn/source.tar.gz"
  download_file "$readonly_source_url" "$archive"
  validate_archive "$archive"
  extract="$txn/extract"
  mkdir -p "$extract"
  tar -xzf "$archive" -C "$extract" || fail 'source archive extraction failed'
  stage="$extract/$readonly_source_root"
  validate_staged_source "$stage"
  printf '%s' "$readonly_repo_slug" >"$stage/.image2-mcp-managed"
  snapshot_codex_config

  if [[ "$repeat" -eq 1 ]]; then
    backup_root="$(mktemp -d "$parent/image2-mcp.backup.XXXXXX")"
    old_move_started=1
    mv "$target" "$backup_root/previous"
  fi
  new_move_started=1
  mv "$stage" "$target"
  run_key_only_installer

  transaction_complete=1
  rm -rf "$txn"
  txn=''
  trap - EXIT HUP INT TERM

  printf 'Verification: OK\n'
  printf 'Install directory: %s\n' "$target"
  printf 'Binary: %s\n' "$target/dist/image2-mcp"
  printf 'Runner: %s\n' "$target/scripts/run-image2-mcp.sh"
  printf 'Codex config: %s\n' "$HOME/.codex/config.toml"
  printf 'Base URL: %s\n' "$readonly_base_url"
  printf 'API Key configured (not displayed).\n'
  if [[ "$repeat" -eq 1 ]]; then
    printf 'Previous installation retained at: %s\n' "$backup_root/previous"
    printf 'Previous local and customer content is not active in the refreshed target.\n'
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
