#!/usr/bin/env bash
# Launch Godot (visible window) on rl_training.tscn with inference_mode = true,
# then race one or more trained models against it. Ctrl-C stops both.
# Usage: ./inference.sh checkpoints/ppo_car_final [inference.py flags]
#        ./inference.sh checkpoints/ppo_car_a checkpoints/ppo_car_b [inference.py flags]
set -euo pipefail

GODOT="${GODOT_PATH:-/Applications/Games/Godot.app/Contents/MacOS/Godot}"
RESOLUTION="${GODOT_RESOLUTION:-1600x900}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Read --port here to launch Godot; it is also passed on to inference.py.
PORT=9000
ARGS=("$@")
for ((i = 0; i < ${#ARGS[@]}; i++)); do
  case "${ARGS[$i]}" in
    --port=*) PORT="${ARGS[$i]#*=}" ;;
    --port) PORT="${ARGS[$((i + 1))]}" ;;
  esac
done

[[ " $* " == *" --verbose "* ]] && export RL_VERBOSE=1
[[ " $* " == *" --start-jitter "* ]] && export RL_START_JITTER=1

echo "Starting Godot: res://scenes/rl/rl_training.tscn (inference_mode = true, window ${RESOLUTION}, port ${PORT})"
RL_INFERENCE_MODE=1 RL_PORT="$PORT" "$GODOT" --path "$PROJECT_DIR" --resolution "$RESOLUTION" scenes/rl/rl_training.tscn &
GODOT_PID=$!

cleanup() {
  echo "Stopping Godot (pid $GODOT_PID)…"
  kill "$GODOT_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

cd "$SCRIPT_DIR"
uv run python inference.py "$@"
