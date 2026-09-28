"""Train a PPO agent via self-play.

Every car under `Cars` in rl_training.tscn is driven by the policy being trained, and
their combined experience fills one PPO rollout buffer. The car count is set by the scene.

Usage:
    uv run python train.py
    uv run python train.py --total-timesteps 20000 --checkpoint-freq 5000
    uv run python train.py --run-id my_run  # checkpoints/my_run/, logs/my_run/
    uv run python train.py --run-id my_run --resume  # resumes from checkpoints/my_run/'s latest checkpoint
    uv run python train.py --run-id new_run --initialize-from old_run  # warm-starts new_run's weights from old_run, step count resets to 0
    uv run python train.py --num-envs 4  # 4 Godot processes on ports 9000-9003, see train.sh
"""

import argparse
import glob
import os
from datetime import datetime

from stable_baselines3 import PPO
from stable_baselines3.common.vec_env import VecFrameStack, VecMonitor

from env import OBSERVATION_STACK, GodotMultiCarVecEnv, GodotParallelVecEnv


def _latest_checkpoint(checkpoint_dir: str) -> str:
    checkpoints = glob.glob(os.path.join(checkpoint_dir, "*.zip"))
    if not checkpoints:
        raise FileNotFoundError(f"No checkpoints found in {checkpoint_dir}")
    return max(checkpoints, key=os.path.getmtime)


def train(
    port: int = 9000,
    num_envs: int = 1,
    total_timesteps: int = 5_000_000,
    checkpoint_freq: int = 1_000_000,
    log_dir: str = "./logs",
    resume: bool = False,
    initialize_from: str | None = None,
    run_id: str | None = None,
    verbose: bool = False,
) -> None:
    if resume and not run_id:
        raise ValueError("--run-id is required when using --resume")
    if resume and initialize_from:
        raise ValueError("--resume and --initialize-from are mutually exclusive")
    if initialize_from and initialize_from == run_id:
        raise ValueError("--run-id must differ from --initialize-from")
    run_id = run_id or datetime.now().strftime("%Y%m%d_%H%M")
    checkpoint_dir = os.path.join("./checkpoints", run_id)
    log_dir = os.path.join(log_dir, run_id)
    os.makedirs(log_dir, exist_ok=True)
    os.makedirs(checkpoint_dir, exist_ok=True)

    if num_envs == 1:
        env = VecMonitor(GodotMultiCarVecEnv(port=port))
    else:
        env = VecMonitor(GodotParallelVecEnv(ports=[port + i for i in range(num_envs)]))
    # The policy sees the last OBSERVATION_STACK frames concatenated per car.
    env = VecFrameStack(env, n_stack=OBSERVATION_STACK)
    if verbose:
        print(f"Training on {env.num_envs} car(s) via self-play across {num_envs} process(es)")

    if resume:
        checkpoint_path = _latest_checkpoint(checkpoint_dir)
        model = PPO.load(checkpoint_path, env=env, tensorboard_log=log_dir)
        model.verbose = 1  # always show SB3's rollout/time/train table, regardless of the saved checkpoint's setting
        if verbose:
            print(f"Resuming from {checkpoint_path}")
    elif initialize_from:
        checkpoint_path = _latest_checkpoint(os.path.join("./checkpoints", initialize_from))
        model = PPO.load(checkpoint_path, env=env, tensorboard_log=log_dir)
        model.verbose = 1
        model.num_timesteps = 0  # fresh run: step count and checkpoint numbering restart at 0
        if verbose:
            print(f"Initialized weights from {checkpoint_path} for new run {run_id}")
    else:
        model = PPO(
            "MlpPolicy",
            env,
            verbose=1,  # always show SB3's rollout/time/train table; --verbose only gates our own prints
            tensorboard_log=log_dir,
            n_steps=2048,
            batch_size=64,
            n_epochs=10,
            gamma=0.99,
            gae_lambda=0.95,
            clip_range=0.2,
            ent_coef=0.01,
            policy_kwargs={"net_arch": [256, 256]},
        )

    steps_done: int = model.num_timesteps
    while steps_done < total_timesteps:
        learn_steps = min(checkpoint_freq, total_timesteps - steps_done)
        model.learn(
            total_timesteps=learn_steps,
            reset_num_timesteps=False,
            tb_log_name="ppo",
        )
        steps_done += learn_steps
        save_path = f"{checkpoint_dir}/ppo_{steps_done:_}"
        model.save(save_path)
        if verbose:
            print(f"Checkpoint saved: {save_path}.zip")

    model.save(f"{checkpoint_dir}/ppo_final")
    if verbose:
        print(f"Training complete. Final model saved to {checkpoint_dir}/ppo_final.zip")
    env.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Train a PPO car-racing agent.")
    parser.add_argument("--port", type=int, default=9000)
    parser.add_argument("--num-envs", type=int, default=1,
                        help="Number of parallel Godot processes, listening on --port, "
                             "--port + 1, ... --port + num_envs - 1.")
    parser.add_argument("--total-timesteps", type=int, default=5_000_000)
    parser.add_argument("--checkpoint-freq", type=int, default=500_000)
    parser.add_argument("--log-dir", type=str, default="./logs")
    parser.add_argument("--resume", action="store_true",
                        help="Resume --run-id from its most recently saved checkpoint, "
                             "continuing to save checkpoints/logs in that run's directories. "
                             "Requires --run-id. Mutually exclusive with --initialize-from.")
    parser.add_argument("--initialize-from", type=str, default=None,
                        help="Run-id whose latest checkpoint to warm-start this run's weights "
                             "from. Unlike --resume, this is a new run: step count resets to 0 "
                             "and checkpoints/logs save under --run-id, not the source run.")
    parser.add_argument("--run-id", type=str, default=None,
                        help="Subdirectory name under checkpoints/ and logs/ for this run. "
                             "Required with --resume. For a new run (including "
                             "--initialize-from), defaults to the current timestamp "
                             "(yyyyMMdd_HHmm) if omitted.")
    parser.add_argument("--verbose", action="store_true",
                        help="Print training/checkpoint progress and enable SB3's own logging.")
    args = parser.parse_args()

    train(
        port=args.port,
        num_envs=args.num_envs,
        total_timesteps=args.total_timesteps,
        checkpoint_freq=args.checkpoint_freq,
        log_dir=args.log_dir,
        resume=args.resume,
        initialize_from=args.initialize_from,
        run_id=args.run_id,
        verbose=args.verbose,
    )
