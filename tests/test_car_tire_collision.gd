extends GutTest

const CAR_SCRIPT: GDScript = preload("res://scripts/car.gd")

func test_build_tire_impulse_pushes_tire_away_from_car() -> void:
	var car: CharacterBody2D = CAR_SCRIPT.new() as CharacterBody2D
	car.velocity = Vector2(220.0, 0.0)
	car.current_speed = 220.0

	var impulse: Vector2 = car.call("_build_tire_impulse", Vector2.LEFT, car.velocity) as Vector2

	assert_gt(impulse.x, 0.0, "Impulse should push the tire away from the car")
	assert_eq(impulse.y, 0.0, "Impulse should stay aligned to the collision normal")
	_free_car(car)

func test_build_tire_impulse_uses_minimum_nudge_for_slow_contacts() -> void:
	var car: CharacterBody2D = CAR_SCRIPT.new() as CharacterBody2D
	car.velocity = Vector2(10.0, 0.0)
	car.current_speed = 10.0
	car.tire_collision_impulse_multiplier = 0.5
	car.tire_collision_min_impulse = 80.0

	var impulse: Vector2 = car.call("_build_tire_impulse", Vector2.LEFT, car.velocity) as Vector2

	assert_eq(impulse.length(), 80.0, "Slow impacts should still move the tire stack")
	_free_car(car)

func test_build_tire_impulse_skips_stationary_overlap() -> void:
	var car: CharacterBody2D = CAR_SCRIPT.new() as CharacterBody2D

	var impulse: Vector2 = car.call("_build_tire_impulse", Vector2.LEFT, car.velocity) as Vector2

	assert_eq(impulse, Vector2.ZERO, "Stationary overlaps should not inject tire impulses")
	_free_car(car)

func _free_car(car: CharacterBody2D) -> void:
	if car == null:
		return
	car.free()
