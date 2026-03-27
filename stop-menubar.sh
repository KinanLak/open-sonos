#!/usr/bin/env bash
set -euo pipefail

APP_NAME="OpenSonos"

osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
pkill -x "$APP_NAME" >/dev/null 2>&1 || true
