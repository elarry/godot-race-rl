#!/usr/bin/env bash
# Launch Godot headlessly on rl_training.tscn, then start PPO training. Ctrl-C stops both.
# Usage: ./train.sh [train.py flags, e.g. --total-timesteps 20000 --checkpoint-freq 5000]
#        ./train.sh --num-envs=4  # 4 parallel Godot processes, ports 9000-9003
set -euo pipefail

GODOT="${GODOT_PATH:-/Applications/Games/Godot.app/Contents/MacOS/Godot}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Read --num-envs/--port here to launch Godot; they are also passed on to train.py.
NUM_ENVS=1
BASE_PORT=9000
ARGS=("$@")
for ((i = 0; i < ${#ARGS[@]}; i++)); do
  case "${ARGS[$i]}" in
    --num-envs=*) NUM_ENVS="${ARGS[$i]#*=}" ;;
    --num-envs) NUM_ENVS="${ARGS[$((i + 1))]}" ;;
    --port=*) BASE_PORT="${ARGS[$i]#*=}" ;;
    --port) BASE_PORT="${ARGS[$((i + 1))]}" ;;
  esac
done

[[ " $* " == *" --verbose "* ]] && export RL_VERBOSE=1

echo "Starting Godot headlessly ($NUM_ENVS process(es)): res://scenes/rl/rl_training.tscn"
GODOT_PIDS=()
for ((i = 0; i < NUM_ENVS; i++)); do
  RL_PORT=$((BASE_PORT + i)) "$GODOT" --headless --path "$PROJECT_DIR" scenes/rl/rl_training.tscn &
  GODOT_PIDS+=("$!")
done

cleanup() {
  echo "Stopping Godot (pid(s) ${GODOT_PIDS[*]})…"
  kill "${GODOT_PIDS[@]}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

cd "$SCRIPT_DIR"
uv run python train.py "$@"
