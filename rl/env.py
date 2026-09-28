import json
import time
from concurrent.futures import ThreadPoolExecutor

import numpy as np
import gymnasium as gym
from gymnasium import spaces
import websocket
from stable_baselines3.common.vec_env.base_vec_env import VecEnv, VecEnvIndices, VecEnvObs, VecEnvStepReturn

OPPONENT_COUNT = 3  # must match RLBridge's OPPONENT_COUNT (scripts/rl/rl_bridge.gd)
OBS_SIZE = 5 + 41 + 7 * OPPONENT_COUNT  # ego-state + track + opponents = 67

# Frames stacked by SB3's VecFrameStack in train.py and inference.py.
OBSERVATION_STACK = 3

# Per-car observation and action spaces, shared by all env classes below.
#
# Observation (67 floats with OPPONENT_COUNT=3), car-relative throughout. Must match
# the layout above RLBridge._build_car_obs_array() in scripts/rl/rl_bridge.gd.
#
# Ego-state (5), all in [-1, 1]:
#     [0] forward velocity        current_speed / max_speed
#     [1] lateral velocity        velocity.dot(right_dir) / max_speed
#     [2] angular velocity        yaw rate / max possible yaw rate
#     [3] last steer              last commanded steer
#     [4] last throttle/brake     last commanded throttle_brake
# Track perception (41):
#     [5-24]  wall-raycast distances, in [0, 1] (0 = touching an obstacle, 1 = clear)
#     [25-44] grass-raycast distances, in [0, 1] (0 = grass immediately, 1 = clear tarmac)
#     [45]    surface scalar, in [0, 1] (1.0 tarmac, grass_speed_multiplier on grass)
# Opponent perception (7 per opponent x OPPONENT_COUNT nearest, zero-filled if absent):
#     [+0]     presence flag, in [0, 1]
#     [+1,+2]  relative position (x, y), car-frame / OPPONENT_MAX_RANGE, in [-1, 1]
#     [+3,+4]  relative heading, cos/sin(opponent.rotation - car.rotation), in [-1, 1]
#     [+5,+6]  relative velocity (x, y), car-frame / max_speed, in [-1, 1]
#
# Action (2 floats, [-1, 1]):
#     [0] throttle_brake   positive = throttle, negative = brake
#     [1] steer            negative = left, positive = right
def _make_spaces() -> tuple[spaces.Box, spaces.Box]:
    action_space = spaces.Box(
        low=np.array([-1.0, -1.0], dtype=np.float32),
        high=np.array([1.0, 1.0], dtype=np.float32),
        dtype=np.float32,
    )
    # Per-segment bounds: ego-state (5) in [-1, 1]; track perception (41: 20 wall rays +
    # 20 grass rays + 1 surface scalar) in [0, 1]; each opponent slot's presence flag in
    # [0, 1] followed by 6 relative floats in [-1, 1].
    opponent_slot_low = [0.0] + [-1.0] * 6
    opponent_slot_high = [1.0] * 7
    low = np.array(
        [-1.0] * 5 + [0.0] * 41 + opponent_slot_low * OPPONENT_COUNT, dtype=np.float32
    )
    high = np.array(
        [1.0] * 5 + [1.0] * 41 + opponent_slot_high * OPPONENT_COUNT, dtype=np.float32
    )
    observation_space = spaces.Box(low=low, high=high, dtype=np.float32)
    return observation_space, action_space


def _connect(host: str, port: int, wait: float = 60.0) -> websocket.WebSocket:
    deadline = time.monotonic() + wait
    while True:
        try:
            ws = websocket.WebSocket()
            ws.connect(f"ws://{host}:{port}", timeout=10)
            return ws
        except ConnectionRefusedError:
            if time.monotonic() >= deadline:
                raise
            print(f"[env] Waiting for Godot on port {port}…")
            time.sleep(1.0)


def _action_to_payload(action: np.ndarray) -> dict:
    return {"throttle_brake": float(action[0]), "steer": float(action[1])}


def _recv_typed(recv_fn, expected_type: str) -> dict:
    """Reads messages until one of expected_type arrives, discarding the rest.

    In inference mode Godot sends a "step" message every physics tick, so a slow client
    can have stale messages queued ahead of the reply it is waiting for.
    """
    while True:
        msg = recv_fn()
        if msg.get("type") == expected_type:
            return msg


class GodotCarEnv(gym.Env):
    """Gymnasium environment driving a single car through Godot's RLBridge.

    Sends and receives length-1 batches of RLBridge's N-car protocol and unwraps them.
    Useful for smoke tests; training uses GodotMultiCarVecEnv.

    RLBridge respawns a finished car immediately, so on a done step `obs` is already the
    post-respawn observation and the terminal one is in `info["terminal_observation"]`.
    """

    metadata = {"render_modes": []}

    def __init__(self, host: str = "localhost", port: int = 9000) -> None:
        super().__init__()
        self.host = host
        self.port = port
        self._ws: websocket.WebSocket | None = None
        self.observation_space, self.action_space = _make_spaces()

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _send(self, msg: dict) -> None:
        assert self._ws is not None
        self._ws.send(json.dumps(msg))

    def _recv(self) -> dict:
        assert self._ws is not None
        return json.loads(self._ws.recv())

    def _ensure_connected(self) -> None:
        if self._ws is None or not self._ws.connected:
            self._ws = _connect(self.host, self.port)

    # ------------------------------------------------------------------
    # Gym interface
    # ------------------------------------------------------------------

    def reset(
        self,
        *,
        seed: int | None = None,
        options: dict | None = None,
    ) -> tuple[np.ndarray, dict]:
        super().reset(seed=seed)
        self._ensure_connected()
        msg_out: dict = {"type": "reset"}
        if options and options.get("random_spawn"):
            msg_out["random_spawn"] = True
        self._send(msg_out)
        msg = _recv_typed(self._recv, "obs")
        return np.array(msg["obs"][0], dtype=np.float32), msg.get("info", {})

    def step(
        self, action: np.ndarray
    ) -> tuple[np.ndarray, float, bool, bool, dict]:
        self._send({"type": "action", "actions": [_action_to_payload(action)]})
        msg = _recv_typed(self._recv, "step")
        obs = np.array(msg["obs"][0], dtype=np.float32)
        reward = float(msg["reward"][0])
        terminated = bool(msg["terminated"][0])
        truncated = bool(msg["truncated"][0])
        info_in = msg.get("info", {})
        info: dict = {key: values[0] for key, values in info_in.items() if key != "terminal_observation"}
        if terminated or truncated:
            terminal_obs = info_in.get("terminal_observation", [None])[0]
            if terminal_obs is not None:
                info["terminal_observation"] = np.array(terminal_obs, dtype=np.float32)
        return obs, reward, terminated, truncated, info

    def close(self) -> None:
        if self._ws is not None:
            self._ws.close()
            self._ws = None


class GodotMultiCarVecEnv(VecEnv):
    """SB3 VecEnv over RLBridge's batched N-car wire protocol.

    One WebSocket round trip carries every car's action and observation. Each car is one
    sub-environment; all cars share a single physics simulation. num_envs is read from
    the first reset reply, so it follows the car count in rl_training.tscn.
    """

    def __init__(self, host: str = "localhost", port: int = 9000) -> None:
        self.host = host
        self.port = port
        self._ws: websocket.WebSocket = _connect(host, port)
        self._pending_actions: np.ndarray | None = None

        # Handshake to learn the car count; SB3 calls reset() again before stepping.
        self._send({"type": "reset"})
        num_envs = len(_recv_typed(self._recv, "obs")["obs"])

        observation_space, action_space = _make_spaces()
        self.render_mode = None  # queried by VecEnv.__init__ via get_attr before it's otherwise set
        super().__init__(num_envs, observation_space, action_space)

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _send(self, msg: dict) -> None:
        self._ws.send(json.dumps(msg))

    def _recv(self) -> dict:
        return json.loads(self._ws.recv())

    # ------------------------------------------------------------------
    # VecEnv interface
    # ------------------------------------------------------------------

    def reset(self) -> VecEnvObs:
        # random_spawn applies to the whole connection (all cars spawn at one gate),
        # so only the first car's options are read.
        random_spawn = bool(self._options[0].get("random_spawn")) if self._options else False
        msg_out: dict = {"type": "reset"}
        if random_spawn:
            msg_out["random_spawn"] = True
        self._send(msg_out)
        msg = _recv_typed(self._recv, "obs")
        self.reset_infos = [{} for _ in range(self.num_envs)]
        self._reset_options()
        return np.array(msg["obs"], dtype=np.float32)

    def step_async(self, actions: np.ndarray) -> None:
        self._pending_actions = actions

    def step_wait(self) -> VecEnvStepReturn:
        assert self._pending_actions is not None, "step_wait() called before step_async()"
        actions_payload = [_action_to_payload(action) for action in self._pending_actions]
        self._send({"type": "action", "actions": actions_payload})
        msg = _recv_typed(self._recv, "step")

        obs = np.array(msg["obs"], dtype=np.float32)
        rewards = np.array(msg["reward"], dtype=np.float32)
        terminated = np.array(msg["terminated"], dtype=bool)
        truncated = np.array(msg["truncated"], dtype=bool)
        dones = terminated | truncated

        info_in = msg["info"]
        infos: list[dict] = []
        for i in range(self.num_envs):
            info: dict = {key: info_in[key][i] for key in ("speed", "on_grass", "stuck", "rank")}
            # Lets PPO bootstrap the value function on truncation instead of treating it
            # as a true terminal state.
            info["TimeLimit.truncated"] = bool(truncated[i] and not terminated[i])
            if dones[i]:
                terminal_obs = info_in["terminal_observation"][i]
                if terminal_obs is not None:
                    info["terminal_observation"] = np.array(terminal_obs, dtype=np.float32)
            infos.append(info)

        return obs, rewards, dones, infos

    def close(self) -> None:
        self._ws.close()

    # There are no per-car Python sub-environments; these answer only what SB3 queries.
    def get_attr(self, attr_name: str, indices: VecEnvIndices = None) -> list:
        return [getattr(self, attr_name)] * self.num_envs

    def set_attr(self, attr_name: str, value, indices: VecEnvIndices = None) -> None:
        raise NotImplementedError("GodotMultiCarVecEnv has no per-car Python sub-environments to set attributes on")

    def env_method(self, method_name: str, *method_args, indices: VecEnvIndices = None, **method_kwargs) -> list:
        raise NotImplementedError("GodotMultiCarVecEnv has no per-car Python sub-environments to call methods on")

    def env_is_wrapped(self, wrapper_class, indices: VecEnvIndices = None) -> list[bool]:
        return [False] * self.num_envs


class GodotParallelVecEnv(VecEnv):
    """SB3 VecEnv over several Godot processes, one GodotMultiCarVecEnv per port.

    Godot physics is single-threaded per process, so multiple processes are needed to
    use more than one CPU core. num_envs is the total car count across all processes.
    Child round trips run on a thread pool so they overlap; results keep port order.
    set_options() is not forwarded to children.
    """

    def __init__(self, ports: list[int]) -> None:
        self._children: list[GodotMultiCarVecEnv] = [GodotMultiCarVecEnv(port=p) for p in ports]
        self._executor = ThreadPoolExecutor(max_workers=len(ports))

        num_envs = sum(child.num_envs for child in self._children)
        observation_space = self._children[0].observation_space
        action_space = self._children[0].action_space
        self.render_mode = None  # queried by VecEnv.__init__ via get_attr before it's otherwise set
        super().__init__(num_envs, observation_space, action_space)

    # ------------------------------------------------------------------
    # VecEnv interface
    # ------------------------------------------------------------------

    def reset(self) -> VecEnvObs:
        results = list(self._executor.map(lambda child: child.reset(), self._children))
        self.reset_infos = []
        for child in self._children:
            self.reset_infos.extend(child.reset_infos)
        return np.concatenate(results, axis=0)

    def step_async(self, actions: np.ndarray) -> None:
        offset = 0
        for child in self._children:
            child.step_async(actions[offset : offset + child.num_envs])
            offset += child.num_envs

    def step_wait(self) -> VecEnvStepReturn:
        results = list(self._executor.map(lambda child: child.step_wait(), self._children))

        obs = np.concatenate([r[0] for r in results], axis=0)
        rewards = np.concatenate([r[1] for r in results], axis=0)
        dones = np.concatenate([r[2] for r in results], axis=0)
        infos: list[dict] = []
        for r in results:
            infos.extend(r[3])

        return obs, rewards, dones, infos

    def close(self) -> None:
        for child in self._children:
            child.close()
        self._executor.shutdown()

    # There are no per-car Python sub-environments; these answer only what SB3 queries.
    def get_attr(self, attr_name: str, indices: VecEnvIndices = None) -> list:
        return [getattr(self, attr_name)] * self.num_envs

    def set_attr(self, attr_name: str, value, indices: VecEnvIndices = None) -> None:
        raise NotImplementedError("GodotParallelVecEnv has no per-env Python sub-environments to set attributes on")

    def env_method(self, method_name: str, *method_args, indices: VecEnvIndices = None, **method_kwargs) -> list:
        raise NotImplementedError("GodotParallelVecEnv has no per-env Python sub-environments to call methods on")

    def env_is_wrapped(self, wrapper_class, indices: VecEnvIndices = None) -> list[bool]:
        return [False] * self.num_envs


if __name__ == "__main__":
    # Smoke test: connect, reset, and take a few random steps.
    env = GodotMultiCarVecEnv()
    print(f"num_envs: {env.num_envs}")
    obs = env.reset()
    print(f"obs shape: {obs.shape}, dtype: {obs.dtype}")
    for _ in range(5):
        actions = np.array([env.action_space.sample() for _ in range(env.num_envs)], dtype=np.float32)
        obs, rewards, dones, infos = env.step(actions)
        print(f"rewards: {rewards}, dones: {dones}, ranks: {[i['rank'] for i in infos]}")
    env.close()
