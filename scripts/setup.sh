#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly_key_only_base_url='https://api.schyler.top'
readonly_key_only_repo='Schyler0427/image2-mcp'
base_url="${OPENAI_IMAGE_BASE_URL:-$readonly_key_only_base_url}"
configure_codex=0
interactive=0
run_tests=1
run_smoke=0
prefer_prebuilt=0
force_config=0
key_only=0
key_only_api_key=''
key_input_echo_disabled=0
key_input_file=''
key_only_behavior_flags=()
help_requested=0

usage() {
  cat <<'EOF'
Usage: ./install.sh [options]

Install and optionally configure the Image2 MCP server for Codex.

Options:
  --key-only             Prompt once for an API key and install the fixed Codex configuration.
  --interactive          Prompt for base URL and API key, then write .env.local.
  --configure-codex      Append an image2 MCP server block to ~/.codex/config.toml.
  --force-config         Replace existing [mcp_servers.image2] config block.
  --base-url URL         Set OPENAI_IMAGE_BASE_URL in the Codex MCP config.
  --prebuilt             Download a GitHub Release binary even when Go is installed.
  --skip-tests           Build without running go test ./...
  --smoke                Run a real image-generation smoke test after build.
  -h, --help             Show this help.

Environment:
  OPENAI_IMAGE_API_KEY   Required by Codex at runtime, and required for --smoke.
  OPENAI_IMAGE_BASE_URL  Optional default base URL; defaults to https://api.schyler.top.
  IMAGE2_MCP_REPO        Optional GitHub repo slug, for example owner/image2-mcp.
EOF
}

github_repo_slug() {
  if [[ -n "${IMAGE2_MCP_REPO:-}" ]]; then
    printf '%s\n' "${IMAGE2_MCP_REPO}"
    return 0
  fi
  if ! git remote get-url origin >/dev/null 2>&1; then
    return 1
  fi
  local remote
  remote="$(git remote get-url origin)"
  case "$remote" in
    git@github.com:*.git)
      remote="${remote#git@github.com:}"
      remote="${remote%.git}"
      ;;
    https://github.com/*.git)
      remote="${remote#https://github.com/}"
      remote="${remote%.git}"
      ;;
    https://github.com/*)
      remote="${remote#https://github.com/}"
      ;;
    *)
      return 1
      ;;
  esac
  printf '%s\n' "$remote"
}

platform_name() {
  case "${1:-$(uname -s)}" in
    Darwin) printf 'darwin' ;;
    Linux) printf 'linux' ;;
    *) return 1 ;;
  esac
}

arch_name() {
  case "${1:-$(uname -m)}" in
    arm64|aarch64) printf 'arm64' ;;
    x86_64|amd64) printf 'amd64' ;;
    *) return 1 ;;
  esac
}

download_prebuilt() {
  local repo os arch asset url tmp extract binary
  repo="$(github_repo_slug)" || {
    echo "error: cannot infer GitHub repo. Set IMAGE2_MCP_REPO=owner/image2-mcp or install Go." >&2
    return 1
  }
  os="$(platform_name)" || {
    echo "error: unsupported OS for prebuilt download: $(uname -s)" >&2
    return 1
  }
  arch="$(arch_name)" || {
    echo "error: unsupported architecture for prebuilt download: $(uname -m)" >&2
    return 1
  }
  asset="image2-mcp_${os}_${arch}.tar.gz"
  if [[ "$key_only" -eq 1 ]]; then
    url="https://github.com/${repo}/releases/download/v0.2.1/${asset}"
  else
    url="https://github.com/${repo}/releases/latest/download/${asset}"
  fi
  mkdir -p "${repo_dir}/dist"
  tmp="$(mktemp -d "${repo_dir}/dist/.image2-mcp.XXXXXX")"
  extract="${tmp}/extract"
  binary="${extract}/image2-mcp"
  echo "==> Downloading prebuilt binary: ${url}"
  if command -v curl >/dev/null 2>&1; then
    if ! curl -fL "$url" -o "${tmp}/${asset}"; then
      rm -rf "$tmp"
      return 1
    fi
  elif command -v wget >/dev/null 2>&1; then
    if ! wget -O "${tmp}/${asset}" "$url"; then
      rm -rf "$tmp"
      return 1
    fi
  else
    echo "error: curl or wget is required to download prebuilt binary" >&2
    rm -rf "$tmp"
    return 1
  fi
  mkdir -p "$extract"
  if ! tar -xzf "${tmp}/${asset}" -C "$extract"; then
    rm -rf "$tmp"
    return 1
  fi
  if [[ ! -f "$binary" ]]; then
    echo "error: prebuilt archive does not contain image2-mcp" >&2
    rm -rf "$tmp"
    return 1
  fi
  chmod +x "$binary"
  mv -f "$binary" "${repo_dir}/dist/image2-mcp"
  rm -rf "$tmp"
}

restore_terminal_echo() {
  if [[ "${key_input_echo_disabled:-0}" -eq 1 ]]; then
    stty echo 2>/dev/null || true
    key_input_echo_disabled=0
  fi
}

cleanup_key_input() {
  restore_terminal_echo
  if [[ -n "${key_input_file:-}" ]]; then
    rm -f -- "$key_input_file"
    key_input_file=''
  fi
}

raw_line_contains_nul() {
  LC_ALL=C od -An -tx1 "$1" | awk '
    {
      for (field = 1; field <= NF; field++) {
        if ($field == "00") found = 1
      }
    }
    END { exit found ? 0 : 1 }
  '
}

read_key_once() {
  local value
  key_input_file="$(mktemp "${TMPDIR:-/tmp}/image2-mcp-key.XXXXXX")"
  chmod 600 "$key_input_file"
  trap cleanup_key_input EXIT HUP INT TERM
  printf 'OPENAI_IMAGE_API_KEY: ' >&2
  if [[ -t 0 ]]; then
    stty -echo
    key_input_echo_disabled=1
  fi
  if ! head -n 1 >"$key_input_file"; then
    cleanup_key_input
    trap - EXIT HUP INT TERM
    printf '\nerror: API Key input was not received\n' >&2
    return 1
  fi
  restore_terminal_echo
  printf '\n' >&2
  if raw_line_contains_nul "$key_input_file"; then
    cleanup_key_input
    trap - EXIT HUP INT TERM
    echo 'error: API Key must be one line and cannot contain NUL' >&2
    return 1
  fi
  if ! IFS= read -r value <"$key_input_file"; then
    cleanup_key_input
    trap - EXIT HUP INT TERM
    echo 'error: API Key input was not received' >&2
    return 1
  fi
  cleanup_key_input
  trap - EXIT HUP INT TERM
  [[ "$value" == *$'\r'* ]] && { echo 'error: API Key must be one line' >&2; return 1; }
  [[ "$value" =~ [^[:space:]] ]] || { echo 'error: API Key cannot be blank' >&2; return 1; }
  key_only_api_key="$value"
}

write_key_only_env() {
  local target="${repo_dir}/.env.local" tmp
  tmp="$(mktemp "${target}.tmp.XXXXXX")"
  chmod 600 "$tmp"
  {
    printf 'OPENAI_IMAGE_BASE_URL=%q\n' "$readonly_key_only_base_url"
    printf 'OPENAI_IMAGE_API_KEY=%q\n' "$key_only_api_key"
  } >"$tmp"
  mv -f "$tmp" "$target"
  chmod 600 "$target"
}

remove_image2_config_namespace() {
  local input="$1" output="$2"
  awk '
    function image2_header(line) {
      return line ~ /^[[:space:]]*\[mcp_servers[[:space:]]*\.[[:space:]]*image2([[:space:]]*\.[[:space:]]*[^]]+)?\][[:space:]]*(#.*)?$/
    }
    function table_header(line) {
      return line ~ /^[[:space:]]*\[[^][]+\][[:space:]]*(#.*)?$/
    }
    function array_table_header(line) {
      return line ~ /^[[:space:]]*\[\[[^][]+\]\][[:space:]]*(#.*)?$/
    }
    {
      if (table_header($0) || array_table_header($0)) skip = image2_header($0)
      if (!skip) print
    }
  ' "$input" >"$output"
}

validate_image2_config_headers() {
  local input="$1"
  awk '
    function image2_header(line) {
      return line ~ /^[[:space:]]*\[mcp_servers[[:space:]]*\.[[:space:]]*image2([[:space:]]*\.[[:space:]]*[^]]+)?\][[:space:]]*(#.*)?$/
    }
    function table_header(line) {
      return line ~ /^[[:space:]]*\[[^][]+\][[:space:]]*(#.*)?$/
    }
    function array_table_header(line) {
      return line ~ /^[[:space:]]*\[\[[^][]+\]\][[:space:]]*(#.*)?$/
    }
    function skip_spaces(text, pos) {
      while (pos <= length(text) && substr(text, pos, 1) ~ /[[:space:]]/) pos++
      return pos
    }
    function hex_value(char) {
      if (char >= "0" && char <= "9") return char + 0
      if (char >= "a" && char <= "f") return index("abcdef", char) + 9
      if (char >= "A" && char <= "F") return index("ABCDEF", char) + 9
      return -1
    }
    function decode_hex(text, digits, pos, value, digit_index, digit) {
      if (length(text) != digits) return -1
      value = 0
      for (digit_index = 1; digit_index <= digits; digit_index++) {
        digit = hex_value(substr(text, digit_index, 1))
        if (digit < 0) return -1
        value = value * 16 + digit
      }
      return value
    }
    function parse_key_segment(text, start, pos, char, value, escape, digits, code) {
      parsed_ok = 0
      pos = skip_spaces(text, start)
      char = substr(text, pos, 1)
      value = ""
      if (char == "\"") {
        pos++
        while (pos <= length(text)) {
          char = substr(text, pos, 1)
          if (char == "\"") {
            parsed_value = value
            parsed_pos = pos + 1
            parsed_ok = 1
            return
          }
          if (char != "\\") {
            value = value char
            pos++
            continue
          }
          pos++
          escape = substr(text, pos, 1)
          if (escape == "u" || escape == "U") {
            digits = escape == "u" ? 4 : 8
            code = decode_hex(substr(text, pos + 1, digits), digits)
            if (code < 0) return
            value = value (code <= 127 ? sprintf("%c", code) : "?")
            pos += digits + 1
            continue
          }
          if (escape == "b") value = value sprintf("%c", 8)
          else if (escape == "t") value = value sprintf("%c", 9)
          else if (escape == "n") value = value sprintf("%c", 10)
          else if (escape == "f") value = value sprintf("%c", 12)
          else if (escape == "r") value = value sprintf("%c", 13)
          else if (escape == "\"" || escape == "\\" || escape == "/") value = value escape
          else return
          pos++
        }
        return
      }
      if (char == sprintf("%c", 39)) {
        pos++
        while (pos <= length(text) && substr(text, pos, 1) != sprintf("%c", 39)) {
          value = value substr(text, pos, 1)
          pos++
        }
        if (substr(text, pos, 1) != sprintf("%c", 39)) return
        parsed_value = value
        parsed_pos = pos + 1
        parsed_ok = 1
        return
      }
      while (pos <= length(text) && substr(text, pos, 1) ~ /[A-Za-z0-9_-]/) {
        value = value substr(text, pos, 1)
        pos++
      }
      if (value == "") return
      parsed_value = value
      parsed_pos = pos
      parsed_ok = 1
    }
    function image2_namespace_header(line) {
      key_text = line
      sub(/^[[:space:]]*\[\[?/, "", key_text)
      if (line ~ /^[[:space:]]*\[\[/) sub(/\]\][[:space:]]*(#.*)?$/, "", key_text)
      else sub(/\][[:space:]]*(#.*)?$/, "", key_text)
      parse_key_segment(key_text, 1)
      if (!parsed_ok) return 0
      first_key = parsed_value
      next_pos = skip_spaces(key_text, parsed_pos)
      if (substr(key_text, next_pos, 1) != ".") return 0
      parse_key_segment(key_text, next_pos + 1)
      return parsed_ok && first_key == "mcp_servers" && parsed_value == "image2"
    }
    function set_current_table(line, key_text, next_pos) {
      current_table_count = 0
      current_table_first = ""
      key_text = line
      sub(/^[[:space:]]*\[\[?/, "", key_text)
      if (line ~ /^[[:space:]]*\[\[/) sub(/\]\][[:space:]]*(#.*)?$/, "", key_text)
      else sub(/\][[:space:]]*(#.*)?$/, "", key_text)
      parse_key_segment(key_text, 1)
      if (!parsed_ok) return
      current_table_first = parsed_value
      current_table_count = 1
      next_pos = skip_spaces(key_text, parsed_pos)
      if (substr(key_text, next_pos, 1) != ".") return
      parse_key_segment(key_text, next_pos + 1)
      if (parsed_ok) current_table_count = 2
    }
    function assignment_key_segments(line, char_index, char, quote, escaped, lhs, next_pos) {
      parsed_ok = 0
      assignment_key_count = 0
      assignment_first_key = ""
      assignment_second_key = ""
      quote = ""
      escaped = 0
      for (char_index = 1; char_index <= length(line); char_index++) {
        char = substr(line, char_index, 1)
        if (quote == "\"") {
          if (escaped) {
            escaped = 0
          } else if (char == "\\") {
            escaped = 1
          } else if (char == quote) {
            quote = ""
          }
          continue
        }
        if (quote == sprintf("%c", 39)) {
          if (char == quote) quote = ""
          continue
        }
        if (char == "\"" || char == sprintf("%c", 39)) {
          quote = char
          continue
        }
        if (char == "=") {
          lhs = substr(line, 1, char_index - 1)
          parse_key_segment(lhs, 1)
          if (!parsed_ok) return
          assignment_first_key = parsed_value
          assignment_key_count = 1
          next_pos = skip_spaces(lhs, parsed_pos)
          if (substr(lhs, next_pos, 1) != ".") return
          parse_key_segment(lhs, next_pos + 1)
          if (parsed_ok) {
            assignment_second_key = parsed_value
            assignment_key_count = 2
          }
          return
        }
      }
    }
    (table_header($0) || array_table_header($0)) {
      set_current_table($0)
      if (image2_namespace_header($0) && !image2_header($0)) exit 1
      next
    }
    {
      assignment_key_segments($0)
      if (assignment_key_count == 0) next
      if (current_table_count == 0 && assignment_first_key == "mcp_servers" && (assignment_key_count == 1 || assignment_second_key == "image2")) exit 2
      if (current_table_count == 1 && current_table_first == "mcp_servers" && assignment_first_key == "image2") exit 2
    }
  ' "$input"
}

validate_codex_config_file() {
  local config_file="$1" status
  [[ -f "$config_file" ]] || return 0
  if validate_image2_config_headers "$config_file"; then
    return 0
  else
    status=$?
  fi
  case "$status" in
    0) return 0 ;;
    1) echo "error: unsupported Image2 TOML table header in ${config_file}" >&2 ;;
    2) echo 'error: unsupported conflicting Image2 TOML assignment' >&2 ;;
    *) echo "error: unable to validate Codex config: ${config_file}" >&2 ;;
  esac
  return 1
}

validate_codex_config_before_install() {
  validate_codex_config_file "${HOME}/.codex/config.toml"
}

toml_basic_string() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

replace_image2_config() {
  local config_file="$1" tmp runner root_count
  validate_codex_config_file "$config_file" || {
    return 1
  }
  tmp="$(mktemp "${config_file}.tmp.XXXXXX")"
  if ! remove_image2_config_namespace "$config_file" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  runner="$(toml_basic_string "${repo_dir}/scripts/run-image2-mcp.sh")"
  {
    printf '\n[mcp_servers.image2]\n'
    printf 'command = "%s"\n' "$runner"
  } >>"$tmp"
  root_count="$(grep -c '^\[mcp_servers\.image2\]$' "$tmp" || true)"
  if [[ "$root_count" -ne 1 ]] || grep -q 'OPENAI_IMAGE_API_KEY' "$tmp"; then
    echo "error: generated Codex config verification failed" >&2
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$config_file"
}

configure_codex_install() {
  local config_dir config_file
  config_dir="${HOME}/.codex"
  config_file="${config_dir}/config.toml"
  mkdir -p "$config_dir"
  touch "$config_file"

  if grep -q '^\[mcp_servers\.image2\]' "$config_file" && [[ "$force_config" -eq 0 ]]; then
    echo "==> Codex MCP config already contains [mcp_servers.image2]; leaving it unchanged: $config_file"
    return 0
  fi
  if grep -q '^\[mcp_servers\.image2' "$config_file"; then
    echo "==> Replacing existing image2 MCP config in $config_file"
  else
    echo "==> Adding image2 MCP config to $config_file"
  fi
  replace_image2_config "$config_file"
}

verify_key_only_install() {
  local binary="${repo_dir}/dist/image2-mcp"
  local runner="${repo_dir}/scripts/run-image2-mcp.sh"
  local config="${HOME}/.codex/config.toml"
  [[ -s "$binary" && -x "$binary" ]] || { echo 'error: binary verification failed' >&2; return 1; }
  [[ -x "$runner" ]] || { echo 'error: runner verification failed' >&2; return 1; }
  "$runner" </dev/null >/dev/null 2>"${repo_dir}/.verify-image2-mcp.log" || {
    rm -f "${repo_dir}/.verify-image2-mcp.log"
    echo 'error: runner startup verification failed' >&2
    return 1
  }
  rm -f "${repo_dir}/.verify-image2-mcp.log"
  [[ "$OPENAI_IMAGE_BASE_URL" == "$readonly_key_only_base_url" && -n "$OPENAI_IMAGE_API_KEY" ]] || {
    echo 'error: environment verification failed' >&2
    return 1
  }
  [[ "$(grep -c '^\[mcp_servers\.image2\]$' "$config" || true)" -eq 1 ]] || {
    echo 'error: Codex config verification failed' >&2
    return 1
  }
  ! grep -q 'OPENAI_IMAGE_API_KEY' "$config" || {
    echo 'error: Codex config contains forbidden key setting' >&2
    return 1
  }
  echo 'Verification: OK'
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --key-only)
        key_only=1
        shift
        ;;
      --configure-codex)
        key_only_behavior_flags+=("$1")
        configure_codex=1
        shift
        ;;
      --force-config)
        key_only_behavior_flags+=("$1")
        force_config=1
        configure_codex=1
        shift
        ;;
      --interactive)
        key_only_behavior_flags+=("$1")
        interactive=1
        shift
        ;;
      --base-url)
        if [[ $# -lt 2 ]]; then
          echo "error: --base-url requires a value" >&2
          return 2
        fi
        key_only_behavior_flags+=("$1")
        base_url="$2"
        shift 2
        ;;
      --prebuilt)
        key_only_behavior_flags+=("$1")
        prefer_prebuilt=1
        shift
        ;;
      --skip-tests)
        key_only_behavior_flags+=("$1")
        run_tests=0
        shift
        ;;
      --smoke)
        key_only_behavior_flags+=("$1")
        run_smoke=1
        shift
        ;;
      -h|--help)
        usage
        help_requested=1
        return 0
        ;;
      *)
        echo "error: unknown option: $1" >&2
        usage >&2
        return 2
        ;;
    esac
  done
  if [[ "$key_only" -eq 1 && "${#key_only_behavior_flags[@]}" -gt 0 ]]; then
    echo "error: --key-only cannot be combined with ${key_only_behavior_flags[*]}" >&2
    return 2
  fi
}

apply_mode_defaults() {
  if [[ "$key_only" -eq 1 ]]; then
    base_url="$readonly_key_only_base_url"
    configure_codex=1
    force_config=1
    prefer_prebuilt=1
    run_tests=0
    run_smoke=0
    export IMAGE2_MCP_REPO="$readonly_key_only_repo"
  fi
}

write_interactive_env() {
  local input_base_url current_key save_current_key input_api_key
  echo "==> Interactive configuration"
  read -r -p "OPENAI_IMAGE_BASE_URL [${base_url}]: " input_base_url
  if [[ -n "${input_base_url}" ]]; then
    base_url="${input_base_url}"
  fi

  current_key="${OPENAI_IMAGE_API_KEY:-}"
  if [[ -n "$current_key" ]]; then
    read -r -p "OPENAI_IMAGE_API_KEY is already set in this shell. Save it to .env.local? [y/N]: " save_current_key
    if [[ "$save_current_key" =~ ^[Yy]$ ]]; then
      input_api_key="$current_key"
    else
      input_api_key=''
    fi
  else
    printf 'OPENAI_IMAGE_API_KEY: '
    if [[ -t 0 ]]; then
      stty -echo
      read -r input_api_key
      stty echo
    else
      read -r input_api_key
    fi
    printf '\n'
  fi

  {
    printf 'OPENAI_IMAGE_BASE_URL=%q\n' "$base_url"
    if [[ -n "${input_api_key:-}" ]]; then
      printf 'OPENAI_IMAGE_API_KEY=%q\n' "$input_api_key"
    fi
  } > "${repo_dir}/.env.local"
  chmod 600 "${repo_dir}/.env.local"
  echo "==> Wrote local environment file: ${repo_dir}/.env.local"
}

load_legacy_environment() {
  if [[ -f "${repo_dir}/.env.local" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "${repo_dir}/.env.local"
    set +a
  fi
  if [[ -f "${repo_dir}/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "${repo_dir}/.env"
    set +a
  fi
  if [[ -n "${OPENAI_IMAGE_BASE_URL:-}" ]]; then
    base_url="${OPENAI_IMAGE_BASE_URL}"
  fi
}

run_install() {
  local go_available
  cd "$repo_dir"
  if [[ "$configure_codex" -eq 1 ]]; then
    validate_codex_config_before_install
  fi
  mkdir -p dist

  if [[ "$key_only" -eq 1 ]]; then
    read_key_once
    write_key_only_env
    export OPENAI_IMAGE_BASE_URL="$readonly_key_only_base_url"
    export OPENAI_IMAGE_API_KEY="$key_only_api_key"
  else
    if [[ "$interactive" -eq 1 ]]; then
      write_interactive_env
    fi
    load_legacy_environment
  fi

  go_available=0
  if command -v go >/dev/null 2>&1; then
    go_available=1
  fi

  if [[ "$prefer_prebuilt" -eq 1 || "$go_available" -eq 0 ]]; then
    if [[ "$run_tests" -eq 1 && "$go_available" -eq 0 ]]; then
      echo "==> Go is not installed; skipping source tests and using prebuilt binary"
    fi
    download_prebuilt
  else
    if [[ "$run_tests" -eq 1 ]]; then
      echo '==> Running tests'
      go test ./...
    fi
    echo '==> Building dist/image2-mcp'
    go build -o ./dist/image2-mcp ./cmd/image2-mcp
  fi

  if [[ "$run_smoke" -eq 1 ]]; then
    if [[ "$go_available" -eq 0 ]]; then
      echo 'error: --smoke currently requires Go because it runs go test' >&2
      return 1
    fi
    if [[ -z "${OPENAI_IMAGE_API_KEY:-}" ]]; then
      echo 'error: --smoke requires OPENAI_IMAGE_API_KEY' >&2
      return 1
    fi
    echo '==> Running real image-generation smoke test'
    RUN_IMAGE2_SMOKE=1 OPENAI_IMAGE_BASE_URL="$base_url" go test ./internal/image2 -run TestRealGenerateImage2Smoke -count=1 -v
  fi

  if [[ "$configure_codex" -eq 1 ]]; then
    configure_codex_install
  fi
  if [[ "$key_only" -eq 1 ]]; then
    verify_key_only_install
  fi

  echo
  echo 'Image2 MCP is ready.'
  echo "Binary: ${repo_dir}/dist/image2-mcp"
  echo "Runner: ${repo_dir}/scripts/run-image2-mcp.sh"
  echo "Base URL: ${base_url}"
  if [[ "$key_only" -eq 0 && ! -f "${repo_dir}/.env.local" && -z "${OPENAI_IMAGE_API_KEY:-}" ]]; then
    echo 'Note: set OPENAI_IMAGE_API_KEY or run ./install.sh --interactive before Codex uses the MCP server.'
  fi
}

main() {
  parse_args "$@" || return $?
  if [[ "$help_requested" -eq 1 ]]; then
    return 0
  fi
  apply_mode_defaults
  run_install
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
