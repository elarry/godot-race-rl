extends Node

## Debug: periodically prints each ray's normalized wall and grass distance
## (0 = hit, 1 = clear) to the console.

const PRINT_INTERVAL_MSEC: int = 5000

@export var car_path: NodePath = NodePath("..")
@export var grass_sample_step: float = 20.0  # matches RLBridge.GRASS_SENSOR_STEP

var _car: CharacterBody2D
var _sensors: CarSensors
var _rays: Array[RayCast2D] = []
var _last_print_time: int = 0
var _verbose: bool = false

func _ready() -> void:
	_verbose = OS.get_environment("RL_VERBOSE") == "1"
	_car = get_node(car_path) as CharacterBody2D
	_sensors = _car.get_node("CarSensors") as CarSensors
	for child in _car.get_children():
		if child is RayCast2D:
			_rays.append(child as RayCast2D)
	_rays.sort_custom(func(a: RayCast2D, b: RayCast2D) -> bool:
		return int(a.name.trim_prefix("Ray")) < int(b.name.trim_prefix("Ray")))

func _process(_delta: float) -> void:
	if not _verbose:
		return
	var now: int = Time.get_ticks_msec()
	if now - _last_print_time < PRINT_INTERVAL_MSEC:
		return
	_last_print_time = now

	var wall_distances: Array[float] = _sensors.get_raycast_distances(_rays)
	var grass_distances: Array[float] = _sensors.get_grass_distances(_car, _rays, _car.track_sprite, _car.track_image, _car.track_image_size, grass_sample_step)

	var wall_parts: PackedStringArray = []
	var grass_parts: PackedStringArray = []
	for i in range(_rays.size()):
		wall_parts.append("%.2f" % [wall_distances[i]])
		grass_parts.append("%.2f" % [grass_distances[i]])
	print("Rays 0--360:  (", ", ".join(wall_parts), ")")
	print("Grass 0--360: (", ", ".join(grass_parts), ")")
