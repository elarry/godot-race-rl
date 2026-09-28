#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT_BIN="${GODOT_PATH:-/Applications/Games/Godot.app/Contents/MacOS/Godot}"

exec "${GODOT_BIN}" \
  --headless \
  --path "${ROOT_DIR}" \
  --script res://addons/gut/gut_cmdln.gd \
  -- \
  -gdir=res://tests \
  -gexit \
  "$@"
