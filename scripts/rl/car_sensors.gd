class_name CarSensors
extends Node

## Stateless observation extraction for the RL layer. Reads only the car and rays
## passed in, so it works without a scene tree.

func get_raycast_distances(rays: Array[RayCast2D]) -> Array[float]:
	var distances: Array[float] = []
	for ray in rays:
		if ray == null or not ray.is_colliding():
			distances.append(1.0)
			continue

		# Measured in global space so per-ray scale (used to vary reach) is included.
		var ray_length: float = ray.global_position.distance_to(ray.to_global(ray.target_position))
		if ray_length <= 0.0:
			distances.append(0.0)
			continue

		var distance: float = ray.global_position.distance_to(ray.get_collision_point())
		distances.append(clamp(distance / ray_length, 0.0, 1.0))
	return distances

## Samples the track texture along each ray to find the nearest grass (grass has no
## collider). 0 = grass immediately, 1 = clear. Uses the car's grass thresholds so
## this agrees with the car's own surface detection.
func get_grass_distances(car: CharacterBody2D, rays: Array[RayCast2D], track_sprite: Sprite2D, track_image: Image, track_image_size: Vector2i, sample_step: float) -> Array[float]:
	if track_sprite == null or track_image == null or track_image_size == Vector2i.ZERO:
		return _all_clear(rays)

	var distances: Array[float] = []
	var step: float = maxf(sample_step, 0.001)
	for ray in rays:
		if ray == null:
			distances.append(1.0)
			continue

		var global_target: Vector2 = ray.to_global(ray.target_position)
		var max_distance: float = ray.global_position.distance_to(global_target)
		if max_distance <= 0.0:
			distances.append(0.0)
			continue

		var direction: Vector2 = (global_target - ray.global_position).normalized()
		var found: float = max_distance
		var traveled: float = 0.0
		while traveled < max_distance:
			traveled = minf(traveled + step, max_distance)
			var sample_pos: Vector2 = ray.global_position + direction * traveled
			var pixel: Vector2i = TrackSurface.world_to_pixel(sample_pos, track_sprite, track_image_size)
			var is_grass: bool
			if pixel.x < 0 or pixel.x >= track_image_size.x or pixel.y < 0 or pixel.y >= track_image_size.y:
				is_grass = true
			else:
				is_grass = TrackSurface.is_grass_color(track_image.get_pixelv(pixel), car.grass_green_component_threshold, car.grass_green_dominance_threshold, car.tarmac_max_saturation, car.tarmac_max_brightness)
			if is_grass:
				found = traveled
				break
		distances.append(clampf(found / max_distance, 0.0, 1.0))
	return distances

func _all_clear(rays: Array[RayCast2D]) -> Array[float]:
	var distances: Array[float] = []
	for _ray in rays:
		distances.append(1.0)
	return distances

## Ego-state (5 floats, car-relative): forward velocity, lateral velocity, yaw rate,
## last commanded steer, last commanded throttle/brake.
func get_ego_state(car: CharacterBody2D, last_steer: float, last_throttle_brake: float) -> Array[float]:
	var max_speed: float = maxf(car.max_speed, 0.001)
	var forward_dir: Vector2 = Vector2(0, -1).rotated(car.rotation)
	var right_dir: Vector2 = forward_dir.rotated(PI * 0.5)
	var lateral_speed: float = car.velocity.dot(right_dir)

	# Maximum yaw rate from Ackermann steering, used to normalize angular velocity.
	var max_curvature: float = tan(deg_to_rad(car.max_steering_angle_degrees)) / maxf(car.wheel_base, 0.001)
	var max_angular_velocity: float = maxf(car.max_speed * max_curvature, 0.001)

	return [
		clampf(car.current_speed / max_speed, -1.0, 1.0),
		clampf(lateral_speed / max_speed, -1.0, 1.0),
		clampf(car.angular_velocity / max_angular_velocity, -1.0, 1.0),
		clampf(last_steer, -1.0, 1.0),
		clampf(last_throttle_brake, -1.0, 1.0),
	]

## Surface grip: 1.0 on tarmac, car.grass_speed_multiplier on grass.
func get_surface_scalar(car: CharacterBody2D) -> float:
	return car.grass_speed_multiplier if car.is_on_grass else 1.0

## Opponent perception (7*k floats): the k nearest cars hit by `rays`, in the car's
## local frame, sorted nearest first. Per slot: presence flag, relative position (2),
## relative heading (2), relative velocity (2). Unused slots are all zero.
func get_opponent_observations(car: CharacterBody2D, rays: Array[RayCast2D], all_cars: Array[CharacterBody2D], k: int, max_range: float) -> Array[float]:
	var seen: Dictionary = {}
	var opponents: Array[CharacterBody2D] = []
	for ray in rays:
		if ray == null or not ray.is_colliding():
			continue
		var collider: Object = ray.get_collider()
		# Type check must precede has(): Array[CharacterBody2D].has() errors on other types.
		if collider == null or collider == car or not (collider is CharacterBody2D) or not all_cars.has(collider):
			continue
		var id: int = collider.get_instance_id()
		if seen.has(id):
			continue
		seen[id] = true
		opponents.append(collider as CharacterBody2D)

	opponents.sort_custom(func(a: CharacterBody2D, b: CharacterBody2D) -> bool:
		return car.position.distance_squared_to(a.position) < car.position.distance_squared_to(b.position))

	var max_speed: float = maxf(car.max_speed, 0.001)
	var safe_range: float = maxf(max_range, 0.001)
	var result: Array[float] = []
	for i in range(k):
		if i >= opponents.size():
			result.append_array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
			continue

		var opponent: CharacterBody2D = opponents[i]
		var rel_pos: Vector2 = (opponent.position - car.position).rotated(-car.rotation) / safe_range
		var rel_heading: float = opponent.rotation - car.rotation
		var rel_vel: Vector2 = (opponent.velocity - car.velocity).rotated(-car.rotation) / max_speed

		result.append_array([
			1.0,
			clampf(rel_pos.x, -1.0, 1.0),
			clampf(rel_pos.y, -1.0, 1.0),
			cos(rel_heading),
			sin(rel_heading),
			clampf(rel_vel.x, -1.0, 1.0),
			clampf(rel_vel.y, -1.0, 1.0),
		])
	return result
