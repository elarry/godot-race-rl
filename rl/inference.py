"""Race one or more trained PPO models against each other on the live Godot scene.

Run rl_training.tscn non-headless with inference_mode = true on RLBridge
(inference.sh sets RL_INFERENCE_MODE=1 for this) so physics runs at full
speed instead of the training step-lock.

Each car gets one model path; if fewer paths than cars are given, the list cycles, so
a single checkpoint drives every car.

A heat runs until every car has finished at least once. A finished car is respawned
immediately, but its steps, reward and rank are recorded at the moment it finished.

Usage:
    uv run python inference.py checkpoints/ppo_car_final
    uv run python inference.py checkpoints/ppo_car_final --episodes 20
    uv run python inference.py checkpoints/ppo_car_final --random-spawn
    uv run python inference.py checkpoints/ppo_car_a checkpoints/ppo_car_b
"""

import argparse
import re
from pathlib import Path

import numpy as np
from stable_baselines3 import PPO
from stable_baselines3.common.vec_env import VecFrameStack

from env import OBSERVATION_STACK, GodotMultiCarVecEnv

PROJECT_ROOT = Path(__file__).resolve().parent.parent
RL_SCENE_PATH = PROJECT_ROOT / "scenes/rl/rl_training.tscn"
BASE_CAR_SCENE_PATH = PROJECT_ROOT / "scenes/car.tscn"

_COLOR_RE = re.compile(r"car_([a-zA-Z]+)_\d+\.png")


def _default_car_color() -> str:
    """Cars in rl_training.tscn with no Sprite2D override inherit car.tscn's texture."""
    text = BASE_CAR_SCENE_PATH.read_text()
    match = _COLOR_RE.search(text)
    return match.group(1).capitalize() if match else "?"


def _load_car_colors(num_cars: int) -> list[str]:
    """Returns each car's sprite color from rl_training.tscn, in RLBridge's car order,
    so printed results can be matched to cars on screen.
    """
    text = RL_SCENE_PATH.read_text()

    texture_by_id = dict(re.findall(
        r'\[ext_resource type="Texture2D"[^\]]*path="([^"]+)"[^\]]*id="([^"]+)"\]', text
    ))
    texture_by_id = {res_id: path for path, res_id in texture_by_id.items()}

    default_color = _default_car_color()
    car_segments = re.split(r'(?=\[node name="Car\d+" parent="Cars")', text)[1:]

    colors = []
    for segment in car_segments:
        override = re.search(r'name="Sprite2D"[^\n]*\n\s*texture = ExtResource\("([^"]+)"\)', segment)
        if override:
            path = texture_by_id.get(override.group(1), "")
            match = _COLOR_RE.search(path)
            colors.append(match.group(1).capitalize() if match else default_color)
        else:
            colors.append(default_color)

    return [colors[i % len(colors)] for i in range(num_cars)] if colors else ["?"] * num_cars


def run_inference(
    model_paths: list[str],
    port: int = 9000,
    n_episodes: int | None = None,
    random_spawn: bool = False,
    verbose: bool = False,
) -> None:
    # Must match the frame stacking used in train.py.
    env = VecFrameStack(GodotMultiCarVecEnv(port=port), n_stack=OBSERVATION_STACK)

    car_model_paths = [model_paths[i % len(model_paths)] for i in range(env.num_envs)]
    models = [PPO.load(path) for path in car_model_paths]
    car_colors = _load_car_colors(env.num_envs)
    for i, path in enumerate(car_model_paths):
        print(f"{car_colors[i]} car {i+1}: {path}")
    print()

    episode = 0
    episode_rewards = np.zeros(env.num_envs, dtype=np.float32)
    steps = np.zeros(env.num_envs, dtype=np.int64)
    final_ranks = np.zeros(env.num_envs, dtype=np.int64)

    try:
        while n_episodes is None or episode < n_episodes:
            if random_spawn:
                env.set_options({"random_spawn": True})
            obs = env.reset()
            episode_rewards[:] = 0.0
            steps[:] = 0
            final_ranks[:] = 0
            active = np.ones(env.num_envs, dtype=bool)

            while active.any():
                actions = np.array(
                    [models[i].predict(obs[i], deterministic=True)[0] for i in range(env.num_envs)],
                    dtype=np.float32,
                )
                obs, rewards, dones, infos = env.step(actions)
                episode_rewards[active] += rewards[active]
                steps[active] += 1
                for i in range(env.num_envs):
                    if active[i] and dones[i]:
                        final_ranks[i] = infos[i]["rank"]
                active &= ~dones

            episode += 1
            if verbose:
                print(f"--- heat {episode} ---")
                for i in np.argsort(final_ranks):
                    print(f"  rank {final_ranks[i]} | car {i} ({car_model_paths[i]}) "
                          f"| steps: {steps[i]} | reward: {episode_rewards[i]:.2f}")
    except KeyboardInterrupt:
        if verbose:
            print("\nStopping.")
    finally:
        env.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Race one or more trained PPO models against Godot.")
    parser.add_argument("model_paths", type=str, nargs="+",
                        help="Path(s) to saved SB3 model(s) (.zip). One per car; if fewer "
                             "paths than cars are given, the list cycles.")
    parser.add_argument("--port", type=int, default=9000)
    parser.add_argument("--episodes", type=int, default=None,
                        help="Stop after N heats (default: run forever).")
    parser.add_argument("--random-spawn", action="store_true",
                        help="Spawn every car together at a random track gate each heat "
                             "instead of the fixed start line, to spot-check driving "
                             "quality from mid-track states.")
    # Handled by inference.sh; accepted here so the pass-through flag parses.
    parser.add_argument("--start-jitter", action="store_true",
                        help="Slightly jitter each car's fixed start-line position/rotation "
                             "every heat (see RLBridge start_*_jitter exports).")
    parser.add_argument("--verbose", action="store_true",
                        help="Print per-heat results.")
    args = parser.parse_args()

    run_inference(
        model_paths=args.model_paths,
        port=args.port,
        n_episodes=args.episodes,
        random_spawn=args.random_spawn,
        verbose=args.verbose,
    )
