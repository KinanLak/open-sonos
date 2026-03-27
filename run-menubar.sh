#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="OpenSonos"
DERIVED_DATA_PATH="$ROOT_DIR/.derivedData"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/Debug/$APP_NAME.app"

cd "$ROOT_DIR"

if [[ ! -f "$ROOT_DIR/Project.swift" ]]; then
  echo "Project.swift introuvable dans $ROOT_DIR" >&2
  exit 1
fi

"$ROOT_DIR/stop-menubar.sh" >/dev/null 2>&1 || true

TUIST_SKIP_UPDATE_CHECK=1 tuist generate --no-open
TUIST_SKIP_UPDATE_CHECK=1 tuist xcodebuild build -scheme "$APP_NAME" -configuration Debug -derivedDataPath "$DERIVED_DATA_PATH"

open "$APP_PATH"
