#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="OpenSonos"
DERIVED_DATA_PATH="$ROOT_DIR/.derivedData"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/Debug/$APP_NAME.app"
LAST_GENERATE_LOG=""

cd "$ROOT_DIR"

if [[ ! -f "$ROOT_DIR/Project.swift" ]]; then
  echo "Project.swift introuvable dans $ROOT_DIR" >&2
  exit 1
fi

"$ROOT_DIR/stop-menubar.sh" >/dev/null 2>&1 || true

generate_project() {
  local attempt=1

  while [[ $attempt -le 2 ]]; do
    local log_file
    log_file="$(mktemp)"

    if TUIST_SKIP_UPDATE_CHECK=1 tuist generate --no-open 2>&1 | tee "$log_file"; then
      LAST_GENERATE_LOG="$log_file"
      return 0
    fi

    if grep -Fq "couldn't be removed" "$log_file" && grep -Fq "No such file or directory" "$log_file"; then
      echo "Tuist manifest cache cleanup failed; retrying generation..." >&2
      LAST_GENERATE_LOG="$log_file"
      attempt=$((attempt + 1))
      sleep 1
      continue
    fi

    LAST_GENERATE_LOG="$log_file"
    return 1
  done

  if [[ -n "$LAST_GENERATE_LOG" ]]; then
    cat "$LAST_GENERATE_LOG" >&2
  fi

  return 1
}

generate_project
TUIST_SKIP_UPDATE_CHECK=1 tuist xcodebuild build -scheme "$APP_NAME" -configuration Debug -derivedDataPath "$DERIVED_DATA_PATH"

open "$APP_PATH"
