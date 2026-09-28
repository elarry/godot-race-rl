class_name CheckpointManager
extends Node

## Tracks per-car checkpoint and lap progress plus the stuck/grass/timeout termination
## timers. Gates are the Area2D children, in track order, shared by all registered cars.

@export var reward_per_checkpoint: float = 5.0  # reward granted per gate passed in order
@export var lap_bonus: float = 50.0  # extra reward granted on top when a lap completes

const STUCK_SPEED_THRESHOLD: float = 30.0
const STUCK_TIME_THRESHOLD: float = 4.0
const GRASS_TIME_THRESHOLD: float = 12.0
const MAX_STEPS: int = 3600

## Per-car episode state.
class CarProgress:
	var next_index: int = 0
	var race_progress: int = 0  # gates driven in the current lap; kept across respawns
	var lap_count: int = 0
	var accumulated_reward: float = 0.0
	var stuck_timer: float = 0.0
	var grass_timer: float = 0.0
	var step_count: int = 0

var _gates: Array[Area2D] = []
# Spawn transform per gate, taken from its CollisionShape2D rather than the Area2D origin.
var _gate_positions: Array[Vector2] = []
var _gate_rotations: Array[float] = []
var _gate_directions: Array[Vector2] = []
# Node2D (car) -> CarProgress. Gates ignore bodies not in this dictionary.
var _progress: Dictionary = {}
var _verbose: bool = false

func _ready() -> void:
	_verbose = OS.get_environment("RL_VERBOSE") == "1"
	for i in range(get_child_count()):
		var gate := get_child(i) as Area2D
		if gate == null:
			continue
		_gates.append(gate)
		var shape: CollisionShape2D = _find_shape(gate)
		_gate_positions.append(shape.global_position if shape != null else gate.global_position)
		_gate_rotations.append(shape.global_rotation if shape != null else gate.global_rotation)
		gate.body_entered.connect(_on_gate_body_entered.bind(i))
	_compute_gate_directions()

func _find_shape(gate: Area2D) -> CollisionShape2D:
	for child in gate.get_children():
		if child is CollisionShape2D:
			return child
	return null

## Each gate's CollisionShape2D is a rectangle across the track, long on its local
## X-axis. Travel direction is perpendicular to that axis, so rotating a gate 180°
## in the editor flips its direction.
func _compute_gate_directions() -> void:
	_gate_directions.resize(_gate_positions.size())
	for i in range(_gate_positions.size()):
		_gate_directions[i] = Vector2.RIGHT.rotated(_gate_rotations[i] - PI * 0.5)

func gate_count() -> int:
	return _gates.size()

func gate_position(index: int) -> Vector2:
	return _gate_positions[index]

## Direction of travel through this gate, used to orient spawned cars.
func gate_direction(index: int) -> Vector2:
	return _gate_directions[index]

## Starts tracking `car`. Must be called before any other per-car method; gates ignore
## unregistered bodies. Calling it again resets the car's progress.
func register_car(car: Node2D) -> void:
	reset(car)

func _on_gate_body_entered(body: Node2D, index: int) -> void:
	var progress: CarProgress = _progress.get(body)
	if progress == null:
		return
	if index != progress.next_index:
		return

	progress.accumulated_reward += reward_per_checkpoint
	if _verbose:
		print("CheckpointManager: checkpoint %d reached, reward +%.2f" % [index, reward_per_checkpoint])
	progress.next_index = (progress.next_index + 1) % _gates.size()

	progress.race_progress += 1
	if progress.race_progress >= _gates.size():
		progress.race_progress = 0
		progress.lap_count += 1
		progress.accumulated_reward += lap_bonus
		if _verbose:
			print("CheckpointManager: lap %d complete, reward +%.2f" % [progress.lap_count, lap_bonus])

func lap_count(car: Node2D) -> int:
	return (_progress[car] as CarProgress).lap_count

## Total gates driven (laps * gate count + gates this lap), used to rank cars.
## Unaffected by respawns.
func progress_score(car: Node2D) -> float:
	var progress: CarProgress = _progress[car]
	return float(progress.lap_count * _gates.size() + progress.race_progress)

func consume_checkpoint_reward(car: Node2D) -> float:
	var progress: CarProgress = _progress[car]
	var reward: float = progress.accumulated_reward
	progress.accumulated_reward = 0.0
	return reward

func is_stuck(car: Node2D, speed: float, delta: float) -> bool:
	var progress: CarProgress = _progress[car]
	if absf(speed) < STUCK_SPEED_THRESHOLD:
		progress.stuck_timer += delta
	else:
		progress.stuck_timer = 0.0
	return progress.stuck_timer >= STUCK_TIME_THRESHOLD

func update_grass_timer(car: Node2D, on_grass: bool, delta: float) -> bool:
	var progress: CarProgress = _progress[car]
	if on_grass:
		progress.grass_timer += delta
	else:
		progress.grass_timer = 0.0
	return progress.grass_timer >= GRASS_TIME_THRESHOLD

func tick_step(car: Node2D) -> bool:
	var progress: CarProgress = _progress[car]
	progress.step_count += 1
	return progress.step_count >= MAX_STEPS

func reset(car: Node2D) -> void:
	_progress[car] = CarProgress.new()

## Like reset(), but for a car spawned at gate_index: its next gate is gate_index + 1.
func reset_at_gate(car: Node2D, gate_index: int) -> void:
	reset(car)
	(_progress[car] as CarProgress).next_index = (gate_index + 1) % _gates.size()

## Respawns `car` at gate_index after a termination. Clears timers and pending reward
## but keeps lap_count and race_progress, so a respawn neither grants nor erases progress.
## step_count is kept so repeated respawns still reach MAX_STEPS, unless
## `reset_step_budget` is set because the step limit itself caused the respawn.
func respawn_at_gate(car: Node2D, gate_index: int, reset_step_budget: bool = false) -> void:
	var progress: CarProgress = _progress[car] as CarProgress
	progress.next_index = (gate_index + 1) % _gates.size()
	progress.stuck_timer = 0.0
	progress.grass_timer = 0.0
	progress.accumulated_reward = 0.0
	if reset_step_budget:
		progress.step_count = 0
