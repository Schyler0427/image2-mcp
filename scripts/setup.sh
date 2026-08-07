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
  url="https://github.com/${repo}/releases/latest/download/${asset}"
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

read_key_once() {
  local value
  printf 'OPENAI_IMAGE_API_KEY: ' >&2
  if [[ -t 0 ]]; then
    trap restore_terminal_echo EXIT HUP INT TERM
    stty -echo
    key_input_echo_disabled=1
  fi
  IFS= read -r value || {
    restore_terminal_echo
    printf '\nerror: API Key input was not received\n' >&2
    return 1
  }
  restore_terminal_echo
  printf '\n' >&2
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
    {
      if (table_header($0)) skip = image2_header($0)
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
    (table_header($0) || array_table_header($0)) && $0 ~ /mcp_servers[[:space:]]*\.[[:space:]]*image2([[:space:]]*\.|[[:space:]]*\])/ && !image2_header($0) { exit 1 }
  ' "$input"
}

toml_basic_string() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

replace_image2_config() {
  local config_file="$1" tmp runner root_count
  validate_image2_config_headers "$config_file" || {
    echo "error: unsupported Image2 TOML table header in ${config_file}" >&2
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
