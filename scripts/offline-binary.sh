#!/usr/bin/env bash

verify_offline_binary() {
  local binary="$1/dist/image2-mcp" log pid watchdog status=0
  [[ -d "$1/dist" && ! -L "$1/dist" && -f "$binary" &&
     ! -L "$binary" && -s "$binary" ]] || {
    echo 'error: offline package is missing a regular bundled binary' >&2
    return 1
  }
  chmod +x "$binary" || return 1
  log="$(mktemp "${TMPDIR:-/tmp}/image2-offline-version.XXXXXX")" || return 1
  (unset OPENAI_IMAGE_API_KEY OPENAI_IMAGE_BASE_URL OPENAI_IMAGE_MODEL GEMINI_IMAGE_API_KEY GEMINI_IMAGE_BASE_URL GEMINI_IMAGE_MODEL; exec "$binary" --version) </dev/null >"$log" 2>/dev/null &
  pid=$!
  (
    sleeper=''
    trap 'kill "$sleeper" 2>/dev/null || true; exit' TERM
    sleep 5 &
    sleeper=$!
    wait "$sleeper"
    kill "$pid" 2>/dev/null || true
    sleep 1 &
    sleeper=$!
    wait "$sleeper"
    kill -KILL "$pid" 2>/dev/null || true
  ) </dev/null >/dev/null 2>&1 &
  watchdog=$!
  wait "$pid" || status=$?
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
  if [[ "$status" -ne 0 || "$(cat "$log")" != "image2-mcp 0.4.4 offline-v1 $(platform_name) $(arch_name)" ]]; then
    rm -f "$log"
    echo 'error: offline binary version/platform check failed' >&2
    return 1
  fi
  rm -f "$log"
}
