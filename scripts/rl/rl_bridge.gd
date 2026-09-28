extends Node

## WebSocket bridge between Godot physics and a Python RL client.
##
## Training mode (inference_mode = false): step-locked -- physics pauses after
## each step and waits for the next "action" message before advancing.
##
## Inference mode (inference_mode = true): non-blocking -- always uses the most
## recently received action; simulation runs at full speed.
##
## One connection drives every car under `cars_path`: actions, observations, rewards
## and done flags are length-N arrays, one slot per car. A car that finishes is
## respawned immediately; its slot's "obs" is the post-respawn observation and the
## terminal one is in info.terminal_observation[i].
##
## Observation extraction is delegated to CarSensors, reward to RewardCalculator, and
## episode state to CheckpointManager.
##
## In inference mode, Space triggers a random-gate reset of all cars.

@export var port: int = 9000
@export var inference_mode: bool = false
@export var cars_path: NodePath = NodePath("../Cars")
@export var checkpoint_manager_path: NodePath = NodePath("../CheckpointManager")

# Maximum random offset for random-gate spawns. Keep small enough to stay on tarmac.
@export var spawn_lateral_jitter: float = 100.0  # perpendicular to travel direction, in px
@export var spawn_longitudinal_jitter: float = 60.0  # along travel direction, in px
@export var spawn_rotation_jitter_degrees: float = 20.0
# Optional jitter for the fixed start-line spawn in inference (inference.sh --start-jitter).
@export var start_jitter_enabled: bool = false
@export var start_position_jitter: float = 15.0  # px, each axis
@export var start_rotation_jitter_degrees: float = 3.0
# Starting-grid layout for a random-gate reset: cars alternate left/right and each is
# staggered further back than the previous one.
@export var grid_row_lateral_spacing: float = 150.0
@export var grid_row_longitudinal_spacing: float = 110.0

# Number of nearest opponents in the observation, and the range (px) used to normalize
# their position. Matches the reach of the perception rays in car_rl.tscn.
const OPPONENT_COUNT: int = 3
const OPPONENT_MAX_RANGE: float = 600.0
const OBS_SIZE: int = 5 + 41 + 7 * OPPONENT_COUNT  # ego-state + track + opponents
# Seconds without an action (training mode) before all cars are reset, to recover from a
# dead client. Must exceed the client's startup time and PPO's training pause between
# rollouts. Override with RL_ACTION_TIMEOUT.
var ACTION_TIMEOUT: float = 60.0
# Step size (px) for marching each ray over the track texture in get_grass_distances().
const GRASS_SENSOR_STEP: float = 20.0
const REWARD_PRINT_INTERVAL_MSEC: int = 5000
# Training only: each action is held for this many physics ticks (~10 decisions/s at
# 60Hz). Reward over the held ticks is averaged, not summed.
const ACTION_REPEAT_TICKS: int = 6

var _verbose: bool = false
var _episode_reward: Array[float] = []  # per car
var _last_reward_print_time: int = 0

var _tcp_server: TCPServer = TCPServer.new()
var _ws: WebSocketPeer = WebSocketPeer.new()
var _connected: bool = false

var _cars: Array[CharacterBody2D] = []
var _checkpoint_manager: CheckpointManager = null
var _sensors: CarSensors = null
var _rays: Array[Array] = []  # per car, each entry an Array[RayCast2D]
# Last commanded action per car, fed back into the ego-state observation.
var _last_steer: Array[float] = []
var _last_throttle_brake: Array[float] = []
# Action-repeat state, see ACTION_REPEAT_TICKS.
var _repeat_ticks_remaining: int = 0
var _repeat_reward: Array[float] = []  # per car, reward accumulated across the held ticks

var _waiting_for_action: bool = true
var _reset_requested: bool = false
var _reset_random_spawn: bool = false
var _wait_elapsed: float = 0.0
# No steps are simulated or sent until the client's first "reset".
var _has_reset: bool = false

var _spawn_positions: Array[Vector2] = []  # per car, editor-authored fixed start
var _spawn_rotations: Array[float] = []

func _ready() -> void:
	# Environment overrides set by train.sh / inference.sh.
	if OS.get_environment("RL_INFERENCE_MODE") == "1":
		inference_mode = true
	_verbose = OS.get_environment("RL_VERBOSE") == "1"
	if OS.get_environment("RL_START_JITTER") == "1":
		start_jitter_enabled = true
	if OS.get_environment("RL_PORT") != "":
		port = int(OS.get_environment("RL_PORT"))
	if OS.get_environment("RL_ACTION_TIMEOUT") != "":
		ACTION_TIMEOUT = float(OS.get_environment("RL_ACTION_TIMEOUT"))

	randomize()

	var cars_container: Node = get_node(cars_path)
	for child in cars_container.get_children():
		if child is CharacterBody2D:
			_cars.append(child as CharacterBody2D)
	if _cars.is_empty():
		push_error("RLBridge: no CharacterBody2D children found under cars_path (%s)" % cars_path)
		return

	_checkpoint_manager = get_node(checkpoint_manager_path) as CheckpointManager
	_sensors = CarSensors.new()  # stateless - one instance serves every car

	for car in _cars:
		_checkpoint_manager.register_car(car)
		_rays.append(_collect_rays(car))
		_spawn_positions.append(car.position)
		_spawn_rotations.append(car.rotation)
		_episode_reward.append(0.0)
		_last_steer.append(0.0)
		_last_throttle_brake.append(0.0)
		_repeat_reward.append(0.0)

	var err: Error = _tcp_server.listen(port)
	if err != OK:
		push_error("RLBridge: failed to start server on port %d (error %d)" % [port, err])
		return
	if _verbose:
		print("RLBridge: listening on ws://localhost:%d with %d car(s)" % [port, _cars.size()])

## Space (inference mode only) requests a random-gate reset, same as a client "reset"
## message with random_spawn.
func _unhandled_input(event: InputEvent) -> void:
	if not inference_mode:
		return
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_SPACE:
		if _verbose:
			print("RLBridge: manual random respawn (space bar)")
		_reset_requested = true
		_reset_random_spawn = true

func _collect_rays(car: CharacterBody2D) -> Array[RayCast2D]:
	var rays: Array[RayCast2D] = []
	for child in car.get_children():
		if child is RayCast2D:
			rays.append(child as RayCast2D)
	rays.sort_custom(func(a: RayCast2D, b: RayCast2D) -> bool:
		return int(a.name.trim_prefix("Ray")) < int(b.name.trim_prefix("Ray")))
	return rays

func _physics_process(delta: float) -> void:
	if not _connected:
		if _tcp_server.is_connection_available():
			var tcp: StreamPeerTCP = _tcp_server.take_connection()
			_ws = WebSocketPeer.new()
			_ws.accept_stream(tcp)
			_connected = true
			_waiting_for_action = true
			_wait_elapsed = 0.0
		return

	_ws.poll()
	var state: WebSocketPeer.State = _ws.get_ready_state()
	if state == WebSocketPeer.STATE_CLOSED:
		_connected = false
		_waiting_for_action = false
		_wait_elapsed = 0.0
		_has_reset = false
		if _verbose:
			print("RLBridge: client disconnected, waiting for reconnect")
		return
	if state != WebSocketPeer.STATE_OPEN:
		return

	_process_incoming_packets()

	if _reset_requested:
		_reset_requested = false
		_wait_elapsed = 0.0
		_do_reset()
		return

	if not _has_reset:
		return

	if not inference_mode and _waiting_for_action:
		_wait_elapsed += delta
		if _wait_elapsed >= ACTION_TIMEOUT:
			push_warning("RLBridge: no action received within %.1fs; ending episode" % ACTION_TIMEOUT)
			_wait_elapsed = 0.0
			_do_reset()
		return

	_wait_elapsed = 0.0
	_run_step(delta)

func _process_incoming_packets() -> void:
	while _ws.get_available_packet_count() > 0:
		var raw: PackedByteArray = _ws.get_packet()
		var text: String = raw.get_string_from_utf8()
		var parsed: Variant = JSON.parse_string(text)
		if parsed == null or not (parsed is Dictionary):
			push_warning("RLBridge: ignoring malformed message: %s" % text)
			continue

		var msg: Dictionary = parsed as Dictionary
		var msg_type: String = msg.get("type", "") as String
		if msg_type == "reset":
			_reset_requested = true
			_reset_random_spawn = msg.get("random_spawn", false) as bool
		elif msg_type == "action":
			_apply_actions(msg.get("actions", []) as Array)
			_waiting_for_action = false
		else:
			push_warning("RLBridge: ignoring unknown message type: %s" % msg_type)

func _apply_actions(actions: Array) -> void:
	if actions.size() != _cars.size():
		push_warning("RLBridge: expected %d car actions, got %d" % [_cars.size(), actions.size()])
	for i in range(_cars.size()):
		if i >= actions.size():
			continue
		var action: Dictionary = actions[i] as Dictionary
		var throttle_brake: float = action.get("throttle_brake", 0.0) as float
		var steer: float = action.get("steer", 0.0) as float
		var throttle: float = maxf(throttle_brake, 0.0)
		var brake: float = maxf(-throttle_brake, 0.0)
		_cars[i].set_rl_action(throttle, brake, steer)
		_last_steer[i] = clampf(steer, -1.0, 1.0)
		_last_throttle_brake[i] = clampf(throttle_brake, -1.0, 1.0)

	if not inference_mode:
		_repeat_ticks_remaining = ACTION_REPEAT_TICKS
		for i in range(_repeat_reward.size()):
			_repeat_reward[i] = 0.0

func _run_step(delta: float) -> void:
	var ranks: Array[int] = _compute_ranks()

	var obs: Array = []
	var rewards: Array[float] = []
	var terminated: Array[bool] = []
	var truncated: Array[bool] = []
	var speeds: Array[float] = []
	var on_grass_flags: Array[bool] = []
	var stuck_flags: Array[bool] = []
	var terminal_obs: Array = []
	var any_done: bool = false

	for i in range(_cars.size()):
		var car: CharacterBody2D = _cars[i]
		var checkpoint_reward: float = _checkpoint_manager.consume_checkpoint_reward(car)
		var speed: float = car.current_speed
		var on_grass: bool = car.is_on_grass
		var had_collision: bool = car.had_collision_this_frame

		var reward: float = RewardCalculator.compute(speed, car.max_speed, on_grass, had_collision, checkpoint_reward, ranks[i], _cars.size())
		_episode_reward[i] += reward

		var stuck: bool = _checkpoint_manager.is_stuck(car, speed, delta)
		var grass_overtime: bool = _checkpoint_manager.update_grass_timer(car, on_grass, delta)
		# The step limit only bounds training episodes; inference runs without it.
		var timeout: bool = false if inference_mode else _checkpoint_manager.tick_step(car)
		var car_terminated: bool = stuck or grass_overtime
		var car_truncated: bool = timeout
		any_done = any_done or car_terminated or car_truncated

		rewards.append(reward)
		terminated.append(car_terminated)
		truncated.append(car_truncated)
		speeds.append(speed)
		on_grass_flags.append(on_grass)
		stuck_flags.append(stuck)

		if car_terminated or car_truncated:
			terminal_obs.append(_build_car_obs_array(car, i))
			_respawn_car(i, timeout)
			obs.append(_build_car_obs_array(car, i))
		else:
			terminal_obs.append(null)
			obs.append(_build_car_obs_array(car, i))

	if not inference_mode:
		for i in range(rewards.size()):
			_repeat_reward[i] += rewards[i]
		_repeat_ticks_remaining -= 1
		if _repeat_ticks_remaining > 0 and not any_done:
			return  # hold the action - simulate another tick before replying
		var ticks_held: int = ACTION_REPEAT_TICKS - _repeat_ticks_remaining
		for i in range(rewards.size()):
			rewards[i] = _repeat_reward[i] / float(ticks_held)

	if _verbose:
		_print_verbose_rewards(ranks)

	_send_json({
		"type": "step",
		"obs": obs,
		"reward": rewards,
		"terminated": terminated,
		"truncated": truncated,
		"info": {
			"speed": speeds,
			"on_grass": on_grass_flags,
			"stuck": stuck_flags,
			"rank": ranks,
			"terminal_observation": terminal_obs,
		},
	})

	if any_done or not inference_mode:
		_waiting_for_action = true

func _print_verbose_rewards(ranks: Array[int]) -> void:
	var now: int = Time.get_ticks_msec()
	if now - _last_reward_print_time < REWARD_PRINT_INTERVAL_MSEC:
		return
	_last_reward_print_time = now
	for i in range(_cars.size()):
		print("RLBridge: car %d agg reward (over %.1f sec) = %.2f | rank %d/%d" % [
			i, REWARD_PRINT_INTERVAL_MSEC / 1000.0, _episode_reward[i], ranks[i], _cars.size(),
		])

## Race position per car (1 = leading), by CheckpointManager.progress_score().
func _compute_ranks() -> Array[int]:
	var scores: Array[float] = []
	for car in _cars:
		scores.append(_checkpoint_manager.progress_score(car))

	var order: Array[int] = []
	for i in range(_cars.size()):
		order.append(i)
	order.sort_custom(func(a: int, b: int) -> bool:
		return scores[a] > scores[b])

	var ranks: Array[int] = []
	ranks.resize(_cars.size())
	for placement in range(order.size()):
		ranks[order[placement]] = placement + 1
	return ranks

func _do_reset() -> void:
	_waiting_for_action = true
	_has_reset = true
	for i in range(_episode_reward.size()):
		_episode_reward[i] = 0.0

	# Training spawns all cars in a grid at a random gate. Inference uses the fixed start
	# positions unless random_spawn was requested.
	if not inference_mode or _reset_random_spawn:
		var gate_index: int = randi() % _checkpoint_manager.gate_count()
		for i in range(_cars.size()):
			_place_car_at_gate(i, gate_index, true)
			_checkpoint_manager.reset_at_gate(_cars[i], gate_index)
	else:
		for i in range(_cars.size()):
			var car: CharacterBody2D = _cars[i]
			car.position = _spawn_positions[i]
			car.rotation = _spawn_rotations[i]
			if start_jitter_enabled:
				car.position += Vector2(
					randf_range(-start_position_jitter, start_position_jitter),
					randf_range(-start_position_jitter, start_position_jitter))
				car.rotation += deg_to_rad(randf_range(-start_rotation_jitter_degrees, start_rotation_jitter_degrees))
			car.velocity = Vector2.ZERO
			car.current_speed = 0.0
			car.angular_velocity = 0.0
			car.set_rl_action(0.0, 0.0, 0.0)
			_last_steer[i] = 0.0
			_last_throttle_brake[i] = 0.0
			_checkpoint_manager.reset(car)

	_send_json({"type": "obs", "obs": _build_all_obs(), "info": {}})

## Respawns one finished car while the others keep racing. Training uses a random gate;
## inference uses the gate nearest the car. `was_timeout` is true when the step limit
## caused the respawn, which refills the car's step budget.
func _respawn_car(car_index: int, was_timeout: bool = false) -> void:
	var gate_index: int = _nearest_gate_index(car_index) if inference_mode else randi() % _checkpoint_manager.gate_count()
	_place_car_at_gate(car_index, gate_index, false)
	_checkpoint_manager.respawn_at_gate(_cars[car_index], gate_index, was_timeout)

func _nearest_gate_index(car_index: int) -> int:
	var car_pos: Vector2 = _cars[car_index].position
	var best_index: int = 0
	var best_dist: float = INF
	for i in range(_checkpoint_manager.gate_count()):
		var dist: float = car_pos.distance_squared_to(_checkpoint_manager.gate_position(i))
		if dist < best_dist:
			best_dist = dist
			best_index = i
	return best_index

func _place_car_at_gate(car_index: int, gate_index: int, apply_grid_offset: bool) -> void:
	var car: CharacterBody2D = _cars[car_index]
	var direction: Vector2 = _checkpoint_manager.gate_direction(gate_index)
	var lateral_dir: Vector2 = direction.rotated(PI * 0.5)

	var grid_lateral: float = 0.0
	var grid_longitudinal: float = 0.0
	if apply_grid_offset:
		grid_lateral = (-1.0 if car_index % 2 == 0 else 1.0) * grid_row_lateral_spacing * 0.5
		grid_longitudinal = -car_index * grid_row_longitudinal_spacing

	var lateral: Vector2 = lateral_dir * (grid_lateral + randf_range(-spawn_lateral_jitter, spawn_lateral_jitter))
	var longitudinal: Vector2 = direction * (grid_longitudinal + randf_range(-spawn_longitudinal_jitter, spawn_longitudinal_jitter))
	var rotation_jitter: float = deg_to_rad(randf_range(-spawn_rotation_jitter_degrees, spawn_rotation_jitter_degrees))

	car.position = _checkpoint_manager.gate_position(gate_index) + lateral + longitudinal
	car.rotation = Vector2(0.0, -1.0).angle_to(direction) + rotation_jitter
	car.velocity = Vector2.ZERO
	car.current_speed = 0.0
	car.angular_velocity = 0.0
	car.set_rl_action(0.0, 0.0, 0.0)
	_last_steer[car_index] = 0.0
	_last_throttle_brake[car_index] = 0.0

# Observation layout (OBS_SIZE floats, 67 with OPPONENT_COUNT=3), car-relative
# throughout. rl/env.py's _make_spaces() must match.
#   Ego-state (5), all in [-1, 1]:
#     [0]  forward velocity   current_speed / max_speed
#     [1]  lateral velocity   velocity.dot(right_dir) / max_speed
#     [2]  angular velocity   yaw rate / max possible yaw rate
#     [3]  last steer         last commanded steer, as sent by the client
#     [4]  last throttle/brake  last commanded throttle_brake, as sent by the client
#   Track perception (41):
#     [5-24]   wall-raycast distances in [0, 1] (Ray-180 .. Ray135, ascending angle), 0 = obstacle, 1 = clear
#     [25-44]  grass-raycast distances in [0, 1], same ray order, 0 = grass immediately, 1 = clear tarmac
#     [45]     surface scalar in [0, 1]: 1.0 on tarmac, grass_speed_multiplier on grass
#   Opponent perception (7 per opponent, OPPONENT_COUNT nearest, zero-filled if absent):
#     [+0]  presence flag in [0, 1]
#     [+1,+2]  relative position (x, y), car-frame, / OPPONENT_MAX_RANGE, clamped [-1, 1]
#     [+3,+4]  relative heading  cos/sin(opponent.rotation - car.rotation)
#     [+5,+6]  relative velocity (x, y), car-frame, / max_speed, clamped [-1, 1]
func _build_all_obs() -> Array:
	var result: Array = []
	for i in range(_cars.size()):
		result.append(_build_car_obs_array(_cars[i], i))
	return result

func _build_car_obs_array(car: CharacterBody2D, car_index: int) -> Array[float]:
	var rays: Array[RayCast2D] = _rays[car_index]

	var result: Array[float] = _sensors.get_ego_state(car, _last_steer[car_index], _last_throttle_brake[car_index])
	result.append_array(_sensors.get_raycast_distances(rays))
	result.append_array(_sensors.get_grass_distances(car, rays, car.track_sprite, car.track_image, car.track_image_size, GRASS_SENSOR_STEP))
	result.append(_sensors.get_surface_scalar(car))
	result.append_array(_sensors.get_opponent_observations(car, rays, _cars, OPPONENT_COUNT, OPPONENT_MAX_RANGE))
	assert(result.size() == OBS_SIZE, "RLBridge: observation size drifted from OBS_SIZE")
	return result

func _send_json(data: Dictionary) -> void:
	if not _connected or _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	_ws.send_text(JSON.stringify(data))
