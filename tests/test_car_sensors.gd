extends GutTest

const CAR_SCRIPT: GDScript = preload("res://scripts/car.gd")

func test_get_raycast_distances_empty_array_returns_empty() -> void:
	var sensors: CarSensors = CarSensors.new()
	var rays: Array[RayCast2D] = []
	var distances: Array[float] = sensors.get_raycast_distances(rays)
	assert_eq(distances.size(), 0, "Empty ray array should return an empty result without erroring")
	sensors.free()

func test_get_raycast_distances_non_colliding_ray_reads_clear() -> void:
	var sensors: CarSensors = CarSensors.new()
	var ray := RayCast2D.new()
	ray.target_position = Vector2(0.0, -600.0)
	var rays: Array[RayCast2D] = [ray]

	var distances: Array[float] = sensors.get_raycast_distances(rays)

	assert_eq(distances.size(), 1)
	assert_eq(distances[0], 1.0, "A ray with no collision data should read fully clear")
	sensors.free()
	ray.free()

func test_get_raycast_distances_colliding_ray_reads_clamped_distance() -> void:
	var sensors: CarSensors = add_child_autofree(CarSensors.new()) as CarSensors
	var ray: RayCast2D = add_child_autofree(RayCast2D.new()) as RayCast2D
	ray.target_position = Vector2(0.0, -600.0)
	ray.global_position = Vector2.ZERO

	var wall := StaticBody2D.new()
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(200.0, 20.0)
	shape.shape = rect
	wall.add_child(shape)
	wall.position = Vector2(0.0, -300.0)
	add_child_autofree(wall)

	await wait_physics_frames(2)
	ray.force_raycast_update()

	var rays: Array[RayCast2D] = [ray]
	var distances: Array[float] = sensors.get_raycast_distances(rays)

	assert_true(ray.is_colliding(), "Sanity check: the ray should have actually hit the wall")
	assert_almost_eq(distances[0], 0.483, 0.05, "Wall at ~half the ray length should read ~0.48")

func test_get_grass_distances_empty_array_returns_empty() -> void:
	var sensors: CarSensors = CarSensors.new()
	var car: CharacterBody2D = CAR_SCRIPT.new() as CharacterBody2D
	var image: Image = _make_track_image(Color(0.2, 0.2, 0.2, 1.0))

	var distances: Array[float] = sensors.get_grass_distances(car, [], null, image, Vector2i(100, 100), 5.0)

	assert_eq(distances.size(), 0, "Empty ray array should return an empty result without erroring")
	sensors.free()
	car.free()

func test_get_grass_distances_all_tarmac_reads_clear() -> void:
	var sensors: CarSensors = CarSensors.new()
	var car: CharacterBody2D = CAR_SCRIPT.new() as CharacterBody2D
	var sprite: Sprite2D = Sprite2D.new()
	var image: Image = _make_track_image(Color(0.2, 0.2, 0.2, 1.0))
	var ray: RayCast2D = RayCast2D.new()
	ray.target_position = Vector2(0.0, -50.0)

	var distances: Array[float] = sensors.get_grass_distances(car, [ray], sprite, image, Vector2i(100, 100), 5.0)

	assert_eq(distances[0], 1.0, "A ray sampled entirely over tarmac should read fully clear")
	sensors.free()
	car.free()
	sprite.free()
	ray.free()

func test_get_grass_distances_finds_grass_partway_along_ray() -> void:
	var sensors: CarSensors = CarSensors.new()
	var car: CharacterBody2D = CAR_SCRIPT.new() as CharacterBody2D
	var sprite: Sprite2D = Sprite2D.new()
	var image: Image = _make_track_image(Color(0.2, 0.2, 0.2, 1.0))
	# Pixel rows 0..24 are grass, 25..99 stay the tarmac fill from above.
	for x in range(100):
		for y in range(25):
			image.set_pixel(x, y, Color(0.65, 0.8, 0.35, 1.0))
	var ray: RayCast2D = RayCast2D.new()
	ray.target_position = Vector2(0.0, -50.0)

	var distances: Array[float] = sensors.get_grass_distances(car, [ray], sprite, image, Vector2i(100, 100), 5.0)

	# Sample origin (0,0) maps to pixel (50,50); marching straight up in 5px steps
	# first lands in the grass band (pixel row < 25) at traveled=30 -> 30/50 = 0.6.
	assert_almost_eq(distances[0], 0.6, 0.001, "Should read the normalized distance to the grass band")
	sensors.free()
	car.free()
	sprite.free()
	ray.free()

func test_get_grass_distances_treats_out_of_bounds_as_grass() -> void:
	var sensors: CarSensors = CarSensors.new()
	var car: CharacterBody2D = CAR_SCRIPT.new() as CharacterBody2D
	var sprite: Sprite2D = Sprite2D.new()
	var image: Image = _make_track_image(Color(0.2, 0.2, 0.2, 1.0))
	var ray: RayCast2D = RayCast2D.new()
	ray.global_position = Vector2(1000.0, 1000.0)
	ray.target_position = Vector2(0.0, -50.0)

	var distances: Array[float] = sensors.get_grass_distances(car, [ray], sprite, image, Vector2i(100, 100), 5.0)

	assert_lt(distances[0], 1.0, "A ray starting outside the texture bounds should not read fully clear")
	sensors.free()
	car.free()
	sprite.free()
	ray.free()

func test_get_grass_distances_missing_track_reads_clear() -> void:
	var sensors: CarSensors = CarSensors.new()
	var car: CharacterBody2D = CAR_SCRIPT.new() as CharacterBody2D
	var ray: RayCast2D = RayCast2D.new()
	ray.target_position = Vector2(0.0, -50.0)

	# track_sprite/track_image not yet cached (e.g. Track sprite lookup still retrying)
	# must read as fully clear rather than crashing on a null Image.
	var distances: Array[float] = sensors.get_grass_distances(car, [ray], null, null, Vector2i.ZERO, 5.0)

	assert_eq(distances, [1.0], "Missing track data should read fully clear, not crash")
	sensors.free()
	car.free()
	ray.free()

func _make_track_image(base_color: Color) -> Image:
	var image: Image = Image.create(100, 100, false, Image.FORMAT_RGBA8)
	image.fill(base_color)
	return image

func test_get_ego_state_returns_five_car_relative_floats() -> void:
	var sensors: CarSensors = CarSensors.new()
	var car: CharacterBody2D = CAR_SCRIPT.new() as CharacterBody2D
	car.rotation = 0.0  # forward_dir = (0,-1), right_dir = (1,0)
	car.velocity = Vector2(20.0, -100.0)  # lateral component is velocity.x here
	car.current_speed = 200.0  # max_speed defaults to 400.0
	car.angular_velocity = 1.0

	var state: Array[float] = sensors.get_ego_state(car, 0.3, -0.7)

	assert_eq(state.size(), 5)
	assert_almost_eq(state[0], 0.5, 0.001, "forward velocity = current_speed / max_speed")
	assert_almost_eq(state[1], 0.05, 0.001, "lateral velocity = velocity.dot(right_dir) / max_speed")
	# max yaw rate = max_speed * tan(deg_to_rad(32)) / wheel_base ~= 2.0829
	assert_almost_eq(state[2], 0.4801, 0.005, "angular velocity normalized by the max turn-rate bound")
	assert_eq(state[3], 0.3, "last_steer passes through unchanged (already in [-1, 1])")
	assert_eq(state[4], -0.7, "last_throttle_brake passes through unchanged (already in [-1, 1])")
	sensors.free()
	car.free()

func test_get_ego_state_clamps_out_of_range_last_action() -> void:
	var sensors: CarSensors = CarSensors.new()
	var car: CharacterBody2D = CAR_SCRIPT.new() as CharacterBody2D

	var state: Array[float] = sensors.get_ego_state(car, 5.0, -5.0)

	assert_eq(state[3], 1.0, "last_steer should clamp to 1.0")
	assert_eq(state[4], -1.0, "last_throttle_brake should clamp to -1.0")
	sensors.free()
	car.free()

func test_get_surface_scalar_tarmac_reads_one() -> void:
	var sensors: CarSensors = CarSensors.new()
	var car: CharacterBody2D = CAR_SCRIPT.new() as CharacterBody2D
	car.is_on_grass = false

	assert_eq(sensors.get_surface_scalar(car), 1.0, "Tarmac should read as full grip (1.0)")
	sensors.free()
	car.free()

func test_get_surface_scalar_grass_reads_speed_multiplier() -> void:
	var sensors: CarSensors = CarSensors.new()
	var car: CharacterBody2D = CAR_SCRIPT.new() as CharacterBody2D
	car.is_on_grass = true
	car.grass_speed_multiplier = 0.55

	assert_eq(sensors.get_surface_scalar(car), 0.55, "Should track the car's own grass_speed_multiplier field, not a hardcoded constant")
	sensors.free()
	car.free()

func _make_opponent(pos: Vector2, rot: float, vel: Vector2) -> CharacterBody2D:
	var body := CharacterBody2D.new()
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(80.0, 80.0)
	shape.shape = rect
	body.add_child(shape)
	body.position = pos
	body.rotation = rot
	body.velocity = vel
	add_child_autofree(body)
	return body

func _make_wall(pos: Vector2) -> StaticBody2D:
	var wall := StaticBody2D.new()
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(200.0, 20.0)
	shape.shape = rect
	wall.add_child(shape)
	wall.position = pos
	add_child_autofree(wall)
	return wall

func test_get_opponent_observations_no_opponents_returns_all_zero() -> void:
	var sensors: CarSensors = add_child_autofree(CarSensors.new()) as CarSensors
	var car: CharacterBody2D = CAR_SCRIPT.new() as CharacterBody2D
	var ray: RayCast2D = add_child_autofree(RayCast2D.new()) as RayCast2D
	ray.target_position = Vector2(0.0, -600.0)
	ray.global_position = Vector2.ZERO

	await wait_physics_frames(2)
	ray.force_raycast_update()

	var all_cars: Array[CharacterBody2D] = [car]
	var obs: Array[float] = sensors.get_opponent_observations(car, [ray], all_cars, 2, 600.0)

	assert_eq(obs.size(), 14, "7 floats per slot, k=2")
	for value in obs:
		assert_eq(value, 0.0, "No opponents in range should read all-zero, presence included")
	car.free()

func test_get_opponent_observations_wall_hit_is_not_counted_as_opponent() -> void:
	var sensors: CarSensors = add_child_autofree(CarSensors.new()) as CarSensors
	var car: CharacterBody2D = CAR_SCRIPT.new() as CharacterBody2D
	var ray: RayCast2D = add_child_autofree(RayCast2D.new()) as RayCast2D
	ray.target_position = Vector2(0.0, -600.0)
	ray.global_position = Vector2.ZERO
	_make_wall(Vector2(0.0, -300.0))

	await wait_physics_frames(2)
	ray.force_raycast_update()

	assert_true(ray.is_colliding(), "Sanity check: the ray should have hit the wall")
	var all_cars: Array[CharacterBody2D] = [car]
	var obs: Array[float] = sensors.get_opponent_observations(car, [ray], all_cars, 1, 600.0)

	assert_eq(obs, [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0], "A wall collider must never populate an opponent slot")
	car.free()

func test_get_opponent_observations_one_opponent_matches_hand_computed_frame() -> void:
	var sensors: CarSensors = add_child_autofree(CarSensors.new()) as CarSensors
	var car: CharacterBody2D = CAR_SCRIPT.new() as CharacterBody2D
	car.rotation = 0.0
	car.velocity = Vector2(5.0, -50.0)
	var ray: RayCast2D = add_child_autofree(RayCast2D.new()) as RayCast2D
	ray.target_position = Vector2(0.0, -600.0)
	ray.global_position = Vector2.ZERO
	var opponent: CharacterBody2D = _make_opponent(Vector2(0.0, -300.0), 0.3, Vector2(10.0, -20.0))

	await wait_physics_frames(2)
	ray.force_raycast_update()

	assert_true(ray.is_colliding(), "Sanity check: the ray should have hit the opponent")
	var all_cars: Array[CharacterBody2D] = [car, opponent]
	var obs: Array[float] = sensors.get_opponent_observations(car, [ray], all_cars, 2, 600.0)

	assert_eq(obs.size(), 14)
	assert_eq(obs[0], 1.0, "Slot 0 presence should be 1")
	assert_almost_eq(obs[1], 0.0, 0.001, "relative x")
	assert_almost_eq(obs[2], -0.5, 0.001, "relative y: -300 / 600")
	assert_almost_eq(obs[3], cos(0.3), 0.001, "relative heading cos")
	assert_almost_eq(obs[4], sin(0.3), 0.001, "relative heading sin")
	assert_almost_eq(obs[5], 0.0125, 0.001, "relative velocity x: (10-5) / 400")
	assert_almost_eq(obs[6], 0.075, 0.001, "relative velocity y: (-20 - -50) / 400")
	for i in range(7, 14):
		assert_eq(obs[i], 0.0, "Unused slot 1 should stay all-zero")
	car.free()

func test_get_opponent_observations_sorts_nearest_first() -> void:
	var sensors: CarSensors = add_child_autofree(CarSensors.new()) as CarSensors
	var car: CharacterBody2D = CAR_SCRIPT.new() as CharacterBody2D
	var ray_forward: RayCast2D = add_child_autofree(RayCast2D.new()) as RayCast2D
	ray_forward.target_position = Vector2(0.0, -600.0)
	ray_forward.global_position = Vector2.ZERO
	var ray_right: RayCast2D = add_child_autofree(RayCast2D.new()) as RayCast2D
	ray_right.target_position = Vector2(600.0, 0.0)
	ray_right.global_position = Vector2.ZERO

	var near_opponent: CharacterBody2D = _make_opponent(Vector2(0.0, -200.0), 0.0, Vector2.ZERO)
	var far_opponent: CharacterBody2D = _make_opponent(Vector2(400.0, 0.0), 0.0, Vector2.ZERO)

	await wait_physics_frames(2)
	ray_forward.force_raycast_update()
	ray_right.force_raycast_update()

	var all_cars: Array[CharacterBody2D] = [car, near_opponent, far_opponent]
	var obs: Array[float] = sensors.get_opponent_observations(car, [ray_forward, ray_right], all_cars, 2, 600.0)

	assert_eq(obs[0], 1.0, "Slot 0 (nearest) should be present")
	assert_almost_eq(obs[2], -1.0 / 3.0, 0.001, "Slot 0 should be the near opponent (200px straight ahead)")
	assert_eq(obs[7], 1.0, "Slot 1 (farthest) should be present")
	assert_almost_eq(obs[8], 2.0 / 3.0, 0.001, "Slot 1 should be the far opponent (400px to the right)")
	car.free()

func test_get_opponent_observations_excludes_farthest_beyond_k() -> void:
	var sensors: CarSensors = add_child_autofree(CarSensors.new()) as CarSensors
	var car: CharacterBody2D = CAR_SCRIPT.new() as CharacterBody2D
	var ray_forward: RayCast2D = add_child_autofree(RayCast2D.new()) as RayCast2D
	ray_forward.target_position = Vector2(0.0, -600.0)
	ray_forward.global_position = Vector2.ZERO
	var ray_right: RayCast2D = add_child_autofree(RayCast2D.new()) as RayCast2D
	ray_right.target_position = Vector2(600.0, 0.0)
	ray_right.global_position = Vector2.ZERO
	var ray_left: RayCast2D = add_child_autofree(RayCast2D.new()) as RayCast2D
	ray_left.target_position = Vector2(-600.0, 0.0)
	ray_left.global_position = Vector2.ZERO

	var nearest: CharacterBody2D = _make_opponent(Vector2(0.0, -100.0), 0.0, Vector2.ZERO)  # dist 100
	var middle: CharacterBody2D = _make_opponent(Vector2(200.0, 0.0), 0.0, Vector2.ZERO)  # dist 200
	var farthest: CharacterBody2D = _make_opponent(Vector2(-300.0, 0.0), 0.0, Vector2.ZERO)  # dist 300, excluded at k=1

	await wait_physics_frames(2)
	ray_forward.force_raycast_update()
	ray_right.force_raycast_update()
	ray_left.force_raycast_update()

	var all_cars: Array[CharacterBody2D] = [car, nearest, middle, farthest]
	var obs: Array[float] = sensors.get_opponent_observations(car, [ray_forward, ray_right, ray_left], all_cars, 1, 600.0)

	assert_eq(obs.size(), 7, "k=1 -> exactly one slot")
	assert_eq(obs[0], 1.0)
	assert_almost_eq(obs[2], -1.0 / 6.0, 0.001, "Only the nearest opponent (100px straight ahead) should appear")
	assert_ne(obs[1], farthest.position.x / 600.0, "The excluded farthest opponent's position must not appear")
	assert_ne(obs[1], middle.position.x / 600.0, "The excluded middle opponent's position must not appear")
	car.free()
