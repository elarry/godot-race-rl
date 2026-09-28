extends GutTest

const CAR_SCRIPT: GDScript = preload("res://scripts/car.gd")
const TIRE_SCRIPT: GDScript = preload("res://scripts/tire_barrier.gd")

func test_set_rl_action_clamps_out_of_range_values() -> void:
	var car: CharacterBody2D = CAR_SCRIPT.new() as CharacterBody2D
	car.set_rl_action(5.0, -3.0, 10.0)
	assert_eq(car._rl_throttle, 1.0, "Throttle should clamp to 1.0")
	assert_eq(car._rl_brake, 0.0, "Brake should clamp to 0.0")
	assert_eq(car._rl_steer, 1.0, "Steer should clamp to 1.0")

	car.set_rl_action(-5.0, 5.0, -10.0)
	assert_eq(car._rl_throttle, 0.0, "Throttle should clamp to 0.0")
	assert_eq(car._rl_brake, 1.0, "Brake should clamp to 1.0")
	assert_eq(car._rl_steer, -1.0, "Steer should clamp to -1.0")
	car.free()

func test_rl_mode_false_ignores_set_rl_action() -> void:
	var car: CharacterBody2D = _car_in_tree()
	assert_false(car.rl_mode, "rl_mode should default to false")
	car.set_rl_action(1.0, 0.0, 0.0)
	car._physics_process(0.1)
	assert_eq(car.current_speed, 0.0, "With rl_mode false and no keyboard input, set_rl_action should have no effect")

func test_rl_mode_true_drives_speed_from_set_rl_action() -> void:
	var car: CharacterBody2D = _car_in_tree()
	car.rl_mode = true
	car.set_rl_action(1.0, 0.0, 0.0)
	car._physics_process(0.1)
	assert_gt(car.current_speed, 0.0, "With rl_mode true, RL throttle should accelerate the car")

func test_rl_mode_true_sets_angular_velocity_while_turning() -> void:
	var car: CharacterBody2D = _car_in_tree()
	car.rl_mode = true
	car.current_speed = 200.0  # above min_ackermann_speed so steering takes effect
	car.set_rl_action(0.0, 0.0, 1.0)
	car._physics_process(0.1)

	var steering_angle: float = deg_to_rad(car.max_steering_angle_degrees)
	var expected_angular_velocity: float = car.current_speed * tan(steering_angle) / car.wheel_base
	assert_almost_eq(car.angular_velocity, expected_angular_velocity, 0.01, "angular_velocity should match current_speed * curvature")

func test_angular_velocity_zero_when_going_straight() -> void:
	var car: CharacterBody2D = _car_in_tree()
	car.rl_mode = true
	car.set_rl_action(1.0, 0.0, 0.0)
	car._physics_process(0.1)
	assert_eq(car.angular_velocity, 0.0, "angular_velocity should stay 0.0 with no steering input")

func test_had_collision_this_frame_resets_each_frame() -> void:
	var car: CharacterBody2D = _car_in_tree()
	car.had_collision_this_frame = true
	car._physics_process(0.016)
	assert_false(car.had_collision_this_frame, "Flag should reset to false at the top of every physics frame")

func test_had_collision_this_frame_true_on_wall_collision() -> void:
	var car: CharacterBody2D = CAR_SCRIPT.new() as CharacterBody2D
	car.call("_handle_wall_collision", Vector2.UP, 1.0, Vector2.UP)
	assert_true(car.had_collision_this_frame, "Wall collision handler should flag had_collision_this_frame")
	car.free()

func test_had_collision_this_frame_true_on_car_collision() -> void:
	var car: CharacterBody2D = CAR_SCRIPT.new() as CharacterBody2D
	var other_car: CharacterBody2D = CAR_SCRIPT.new() as CharacterBody2D
	other_car.global_position = Vector2(50.0, 0.0)
	car.call("_handle_car_collision", other_car, KinematicCollision2D.new(), car.velocity)
	assert_true(car.had_collision_this_frame, "Car-vs-car collision handler should flag had_collision_this_frame")
	car.free()
	other_car.free()

func test_had_collision_this_frame_false_on_tire_collision() -> void:
	var car: CharacterBody2D = CAR_SCRIPT.new() as CharacterBody2D
	var tire: RigidBody2D = TIRE_SCRIPT.new() as RigidBody2D
	tire.global_position = Vector2(50.0, 0.0)
	car.call("_handle_tire_collision", tire, KinematicCollision2D.new(), car.velocity)
	assert_false(car.had_collision_this_frame, "Tire barrier collision handler should not flag had_collision_this_frame")
	car.free()
	tire.free()

func _car_in_tree() -> CharacterBody2D:
	var car: CharacterBody2D = CAR_SCRIPT.new() as CharacterBody2D
	# Pre-bind a dummy track sprite so _ready() skips the deferred Track lookup.
	car.track_sprite = add_child_autofree(Sprite2D.new()) as Sprite2D
	add_child_autofree(car)
	return car
