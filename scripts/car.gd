extends CharacterBody2D

# Car physics parameters aimed to achieve arcade feel
@export var max_speed = 500.0
@export var acceleration = 800.0
@export var friction = 400.0
@export var turn_speed = 2.0
@export var wheel_base = 120.0  # Distance between axles for Ackermann steering
@export var max_steering_angle_degrees = 32.0  # Maximum steering angle for front wheels
@export var forward_steering_multiplier = 0.18  # Slightly lower steering gain while moving forward
@export var reverse_steering_multiplier = 0.5  # Extra steering gain when reversing
@export var min_ackermann_speed = 10.0  # Minimum speed before steering has an effect
@export var drift_factor = 0.95  # How much the car drifts (lower = more drift)
@export var bounce_factor = 0.5  # Energy preserved when bouncing off walls
@export var car_collision_bounce_multiplier = 1  # Extra bounce energy when hitting another car
@export var car_collision_hit_response_multiplier = 2  # How much harder the impacted car gets launched
@export var tire_collision_impulse_multiplier = 0.75  # How strongly the car shoves tire stacks
@export var tire_collision_min_impulse = 70.0  # Minimum tire impulse for low-speed nudges
@export var tire_collision_car_bounce = 0.2  # Small rebound the car gets when nudging a tire stack
@export var tire_collision_speed_retention = 0.82  # Speed the car keeps after clipping a tire stack
@export var brake_multiplier = 4.0  # Multiplier for braking force when using reverse/forward to slow down
@export var drift_lateral_retention = 0.9  # How much sideways speed is kept during normal driving. Low value implies high grip
@export var drift_skid_lateral_retention = 0.90  # Sideways speed retention while skidding
@export var drift_skid_alignment_multiplier = 0.3  # Multiplier for alignment weight when skidding; lower = looser grip
@export var drift_turn_threshold = 0.5  # Minimum normalized turn input before enhanced skid activates
@export var skid_min_intensity = 0.2  # Minimum skid factor before leaving skid marks
@export var skid_min_lateral_speed = 16.0  # Minimum lateral speed before skid marks appear
@export var skid_min_speed = 50.0  # Minimum forward speed before skid marks appear
@export var skid_turn_hold_threshold = 0.2  # Seconds a turn input must be held before tarmac skids appear
@export var skid_mark_spacing = 2.5  # Distance between skid mark points
@export var skid_mark_width = 12.0
@export var skid_mark_max_points = 160
@export var skid_mark_lateral_offset = 18.0  # Wheel to wheel spacing
@export var skid_mark_longitudinal_offset = 16.0  # Offset toward the rear for where skid marks spawn
@export var skid_mark_color: Color = Color(0.0, 0.0, 0.0, 0.85)
@export var grass_mark_color: Color = Color(0.36, 0.22, 0.08, 0.92)
@export var grass_mark_width = 10.0
@export var grass_mark_spacing = 4.0
@export var grass_mark_min_speed = 5.0
@export var grass_green_component_threshold := 0.32
@export var grass_green_dominance_threshold := 0.05
@export var tarmac_max_saturation := 0.08
@export var tarmac_max_brightness := 0.65
@export var action_accelerate := "ui_up"
@export var action_brake := "ui_down"
@export var action_turn_left := "ui_left"
@export var action_turn_right := "ui_right"

# RL control: when rl_mode is set, input comes from set_rl_action() instead of the keyboard.
@export var rl_mode: bool = false
var _rl_throttle: float = 0.0
var _rl_brake: float = 0.0
var _rl_steer: float = 0.0
var had_collision_this_frame: bool = false

# Surface detection parameters
@export var grass_speed_multiplier = 0.4  # Max speed when on grass (40% of normal)
@export var grass_friction_multiplier = 2.0  # Increased friction on grass
@export var grass_acceleration_multiplier = 0.6  # Reduced acceleration on grass

var current_speed: float = 0.0
var angular_velocity: float = 0.0
var rotation_dir: float = 0.0
var is_on_grass: bool = false
var track_sprite: Sprite2D = null
var track_image: Image = null
var track_image_size: Vector2i = Vector2i.ZERO
var _track_lookup_retry_scheduled: bool = false
var _track_lookup_retry_count: int = 0
const TRACK_LOOKUP_MAX_RETRIES: int = 60  # ~1s of idle frames; give up rather than retry forever
var _track_sprite_warning_logged: bool = false
var _collision_partner_frames: Dictionary = {}
var skid_mark_root: Node2D = null
var _active_skid_left: Line2D = null
var _active_skid_right: Line2D = null
var _last_skid_point_left: Vector2 = Vector2.INF
var _last_skid_point_right: Vector2 = Vector2.INF
var _is_skidding: bool = false
var _active_grass_left: Line2D = null
var _active_grass_right: Line2D = null
var _last_grass_point_left: Vector2 = Vector2.INF
var _last_grass_point_right: Vector2 = Vector2.INF
var _turn_hold_time: float = 0.0

func set_rl_action(throttle: float, brake: float, steer: float) -> void:
	_rl_throttle = clamp(throttle, 0.0, 1.0)
	_rl_brake = clamp(brake, 0.0, 1.0)
	_rl_steer = clamp(steer, -1.0, 1.0)

func _ready() -> void:
	_schedule_track_sprite_lookup()
	skid_mark_root = _get_skid_mark_root()

func _schedule_track_sprite_lookup() -> void:
	if not is_inside_tree():
		return
	if _bind_track_sprite():
		return

	if not _track_sprite_warning_logged:
		_track_sprite_warning_logged = true
		push_warning("Track sprite not available yet; grass detection will initialize once it loads.")

	if _track_lookup_retry_scheduled:
		return
	if _track_lookup_retry_count >= TRACK_LOOKUP_MAX_RETRIES:
		return

	_track_lookup_retry_scheduled = true
	_track_lookup_retry_count += 1
	call_deferred("_retry_track_sprite_lookup")

func _retry_track_sprite_lookup() -> void:
	_track_lookup_retry_scheduled = false
	if not is_inside_tree():
		return
	if not _bind_track_sprite():
		_schedule_track_sprite_lookup()

func _bind_track_sprite() -> bool:
	if track_sprite != null:
		if is_instance_valid(track_sprite):
			return true
		track_sprite = null

	var root := get_tree().root
	if root == null:
		return false

	var sprite := find_track_sprite(root)
	if sprite == null:
		return false

	track_sprite = sprite
	_track_sprite_warning_logged = false
	_track_lookup_retry_count = 0
	track_sprite.tree_exited.connect(_on_track_sprite_exited)
	_cache_track_image()
	return true

func _on_track_sprite_exited() -> void:
	track_sprite = null
	_track_sprite_warning_logged = false
	_track_lookup_retry_count = 0
	track_image = null
	track_image_size = Vector2i.ZERO
	_schedule_track_sprite_lookup()

func find_track_sprite(node: Node) -> Sprite2D:
	# Look for a Sprite2D named "Track" in the scene tree
	if node is Sprite2D and node.name == "Track":
		return node
	for child in node.get_children():
		var result := find_track_sprite(child)
		if result:
			return result
	return null

func _cache_track_image() -> void:
	track_image = null
	track_image_size = Vector2i.ZERO

	if track_sprite == null or track_sprite.texture == null:
		return

	var image := _get_track_texture_image()
	if image == null:
		push_warning("Track texture image could not be retrieved; grass detection disabled.")
		return

	if image.is_compressed():
		var decompress_result := image.decompress()
		if decompress_result != OK:
			push_warning("Failed to decompress track texture; grass detection disabled.")
			return

	if image.get_width() == 0 or image.get_height() == 0:
		push_warning("Track texture image is empty; grass detection disabled.")
		return

	if image.get_format() != Image.FORMAT_RGBA8 and image.get_format() != Image.FORMAT_RGBAF:
		image.convert(Image.FORMAT_RGBA8)

	track_image = image
	track_image_size = image.get_size()

func _exit_tree() -> void:
	track_image = null
	track_image_size = Vector2i.ZERO

func _get_track_texture_image() -> Image:
	if track_sprite == null or track_sprite.texture == null:
		return null

	var texture := track_sprite.texture
	if texture is Texture2D:
		var texture_image := texture.get_image()
		if texture_image != null and texture_image.get_width() > 0:
			return texture_image.duplicate()

	var resource_path := texture.resource_path
	if resource_path == "":
		return null

	var file_image := Image.new()
	var load_result := file_image.load(resource_path)
	if load_result != OK:
		return null
	return file_image

func _is_grass_color(color: Color) -> bool:
	return TrackSurface.is_grass_color(color, grass_green_component_threshold, grass_green_dominance_threshold, tarmac_max_saturation, tarmac_max_brightness)

func check_surface_type() -> bool:
	# Returns true if on grass, false if on tarmac
	if track_sprite == null or track_image == null or track_image_size == Vector2i.ZERO:
		return false

	var pixel: Vector2i = TrackSurface.world_to_pixel(global_position, track_sprite, track_image_size)

	# Check bounds
	if pixel.x < 0 or pixel.x >= track_image_size.x or pixel.y < 0 or pixel.y >= track_image_size.y:
		return true  # Outside bounds = grass

	var pixel_color: Color = track_image.get_pixelv(pixel)
	return _is_grass_color(pixel_color)

func _physics_process(delta: float) -> void:
	# Check what surface we're on
	is_on_grass = check_surface_type()
	_purge_old_collision_partners(Engine.get_physics_frames())
	had_collision_this_frame = false

	# Get input
	var reverse_input: float
	var forward_input: float
	var input_turn: float
	if rl_mode:
		reverse_input = _rl_brake
		forward_input = _rl_throttle
		input_turn = _rl_steer
	else:
		reverse_input = Input.get_action_strength(action_brake)
		forward_input = Input.get_action_strength(action_accelerate)
		input_turn = Input.get_axis(action_turn_left, action_turn_right)

	if input_turn != 0.0:
		_turn_hold_time += delta
	else:
		_turn_hold_time = 0.0

	# Adjust physics parameters based on surface
	var effective_max_speed: float = max_speed
	var effective_acceleration: float = acceleration
	var effective_friction: float = friction

	if is_on_grass:
		effective_max_speed = max_speed * grass_speed_multiplier
		effective_acceleration = acceleration * grass_acceleration_multiplier
		effective_friction = friction * grass_friction_multiplier

	# Apply acceleration/braking
	if forward_input > 0.0 and reverse_input == 0.0:
		if current_speed < 0.0:
			var brake_force_forward: float = effective_acceleration * brake_multiplier * forward_input
			current_speed = move_toward(current_speed, 0.0, brake_force_forward * delta)
		else:
			current_speed += forward_input * effective_acceleration * delta
			current_speed = min(current_speed, effective_max_speed)
	elif reverse_input > 0.0 and forward_input == 0.0:
		if current_speed > 0.0:
			var brake_force_reverse: float = effective_acceleration * brake_multiplier * reverse_input
			current_speed = move_toward(current_speed, 0.0, brake_force_reverse * delta)
		else:
			current_speed -= reverse_input * effective_acceleration * delta
			current_speed = max(current_speed, -effective_max_speed * 0.5)
	elif forward_input > 0.0 and reverse_input > 0.0:
		var combined_input: float = max(forward_input, reverse_input)
		var dual_brake_force: float = effective_acceleration * brake_multiplier * combined_input
		current_speed = move_toward(current_speed, 0.0, dual_brake_force * delta)
	else:
		# Apply friction when no input
		if abs(current_speed) > 0:
			var friction_amount: float = effective_friction * delta
			if abs(current_speed) < friction_amount:
				current_speed = 0
			else:
				current_speed -= sign(current_speed) * friction_amount

	# Additional slowdown when on grass and moving too fast
	if is_on_grass and abs(current_speed) > effective_max_speed:
		# Gradually slow down to the grass max speed
		current_speed = move_toward(current_speed, sign(current_speed) * effective_max_speed, effective_friction * delta * 2)

	# Apply Ackermann steering so forward and reverse feel different
	if abs(current_speed) > min_ackermann_speed and abs(input_turn) > 0.0:
		rotation_dir = input_turn
		_apply_ackermann_steering(rotation_dir, delta)
	else:
		angular_velocity = 0.0

	# Calculate velocity with drift/skid behavior
	var forward_dir : Vector2 = Vector2(0, -1).rotated(rotation)
	var desired_velocity : Vector2 = forward_dir * current_speed
	var right_dir := forward_dir.rotated(PI * 0.5)
	var lateral_speed := velocity.dot(right_dir)

	var speed_ratio : float = clamp(abs(current_speed) / max(effective_max_speed, 0.001), 0.0, 1.0)
	var turn_amount : float = clamp(abs(input_turn), 0.0, 1.0)
	var skid_turn_factor := 0.0
	if turn_amount > drift_turn_threshold:
		var normalized_turn : float = (turn_amount - drift_turn_threshold) / (1.0 - drift_turn_threshold)
		skid_turn_factor = clamp(normalized_turn, 0.0, 1.0)
	var skid_intensity : float = clamp(speed_ratio * skid_turn_factor, 0.0, 1.0)

	var lateral_retention : float = lerp(drift_lateral_retention, drift_skid_lateral_retention, skid_intensity)
	var preserved_lateral : float = lateral_speed * lateral_retention
	var target_velocity := desired_velocity + right_dir * preserved_lateral

	var skid_alignment : float = clamp(drift_factor * drift_skid_alignment_multiplier, 0.0, 1.0)
	var alignment_weight : float = clamp(lerp(drift_factor, skid_alignment, skid_intensity), 0.0, 1.0)

	velocity = velocity.lerp(target_velocity, alignment_weight)
	velocity = velocity.limit_length(effective_max_speed)
	var resulting_lateral_speed : float = velocity.dot(right_dir)
	var pre_slide_velocity := velocity

	# Move the car
	move_and_slide()

	_update_skid_marks(forward_dir, right_dir, skid_intensity, resulting_lateral_speed)
	_update_grass_marks(forward_dir, right_dir)
	_process_collisions(forward_dir, pre_slide_velocity)

func _apply_ackermann_steering(steering_input: float, delta: float) -> void:
	var steering_angle: float = deg_to_rad(max_steering_angle_degrees) * clamp(steering_input, -1.0, 1.0)
	if abs(steering_angle) <= 0.0001:
		angular_velocity = 0.0
		return

	var wheel_base_length: float = max(wheel_base, 0.001)
	var curvature: float = tan(steering_angle) / wheel_base_length
	angular_velocity = current_speed * curvature
	var steering_gain: float = forward_steering_multiplier if current_speed >= 0.0 else reverse_steering_multiplier
	var direction_multiplier: float = turn_speed * steering_gain
	rotation += angular_velocity * direction_multiplier * delta

func _update_skid_marks(forward_dir: Vector2, right_dir: Vector2, skid_intensity: float, lateral_speed: float) -> void:
	var should_skid : bool = (
		not is_on_grass
		and abs(current_speed) >= skid_min_speed
		and abs(lateral_speed) >= skid_min_lateral_speed
		and skid_intensity >= skid_min_intensity
		and _turn_hold_time >= skid_turn_hold_threshold
	)
	if not should_skid:
		_reset_skid_state()
		return

	var root := _get_skid_mark_root()
	if root == null:
		return

	var left_world : Vector2 = global_position - forward_dir * skid_mark_longitudinal_offset + right_dir * skid_mark_lateral_offset
	var right_world : Vector2 = global_position - forward_dir * skid_mark_longitudinal_offset - right_dir * skid_mark_lateral_offset

	_active_skid_left = _append_skid_point(_active_skid_left, left_world, root, true)
	_active_skid_right = _append_skid_point(_active_skid_right, right_world, root, false)
	_is_skidding = true

func _update_grass_marks(forward_dir: Vector2, right_dir: Vector2) -> void:
	if not is_on_grass or abs(current_speed) < grass_mark_min_speed:
		_reset_grass_state()
		return

	var root := _get_skid_mark_root()
	if root == null:
		return

	var left_world : Vector2 = global_position - forward_dir * skid_mark_longitudinal_offset + right_dir * skid_mark_lateral_offset
	var right_world : Vector2 = global_position - forward_dir * skid_mark_longitudinal_offset - right_dir * skid_mark_lateral_offset

	_active_grass_left = _append_grass_point(_active_grass_left, left_world, root, true)
	_active_grass_right = _append_grass_point(_active_grass_right, right_world, root, false)

func _append_skid_point(existing_line: Line2D, world_point: Vector2, root: Node2D, is_left: bool) -> Line2D:
	var line := existing_line
	var last_world := _last_skid_point_left if is_left else _last_skid_point_right
	var needs_new_line := (line == null) or (not is_instance_valid(line))
	var local_point := root.to_local(world_point)
	var appended_point := false

	if needs_new_line:
		line = _create_skid_line(root)
		line.add_point(local_point)
		line.add_point(local_point)
		_trim_skid_points(line)
		appended_point = true
	else:
		if last_world == Vector2.INF or last_world.distance_to(world_point) >= skid_mark_spacing:
			line.add_point(local_point)
			_trim_skid_points(line)
			appended_point = true
		else:
			var last_index := line.get_point_count() - 1
			if last_index >= 0:
				line.set_point_position(last_index, local_point)

	if appended_point:
		if is_left:
			_last_skid_point_left = world_point
		else:
			_last_skid_point_right = world_point

	return line

func _append_grass_point(existing_line: Line2D, world_point: Vector2, root: Node2D, is_left: bool) -> Line2D:
	var line := existing_line
	var last_world := _last_grass_point_left if is_left else _last_grass_point_right
	var needs_new_line := (line == null) or (not is_instance_valid(line))
	var local_point := root.to_local(world_point)
	var appended_point := false

	if needs_new_line:
		line = _create_grass_line(root)
		line.add_point(local_point)
		line.add_point(local_point)
		if is_left:
			_last_grass_point_left = world_point
		else:
			_last_grass_point_right = world_point
		appended_point = true
	elif last_world == Vector2.INF or last_world.distance_to(world_point) >= grass_mark_spacing:
		line.add_point(local_point)
		if is_left:
			_last_grass_point_left = world_point
		else:
			_last_grass_point_right = world_point
		appended_point = true
	else:
		var last_index := line.get_point_count() - 1
		if last_index >= 0:
			line.set_point_position(last_index, local_point)

	if not appended_point:
		return line

	if is_left:
		_last_grass_point_left = world_point
	else:
		_last_grass_point_right = world_point

	return line

func _create_mark_line(root: Node2D, width: float, color: Color, z_index_value: int) -> Line2D:
	var line := Line2D.new()
	line.width = width
	line.default_color = color
	line.texture_mode = Line2D.LINE_TEXTURE_NONE
	line.begin_cap_mode = Line2D.LINE_CAP_ROUND
	line.end_cap_mode = Line2D.LINE_CAP_ROUND
	line.joint_mode = Line2D.LINE_JOINT_ROUND
	line.z_index = z_index_value
	line.z_as_relative = false
	root.add_child(line)
	return line

func _create_skid_line(root: Node2D) -> Line2D:
	return _create_mark_line(root, skid_mark_width, skid_mark_color, 1)

func _create_grass_line(root: Node2D) -> Line2D:
	return _create_mark_line(root, grass_mark_width, grass_mark_color, 1)

func _trim_skid_points(line: Line2D) -> void:
	while line.get_point_count() > skid_mark_max_points:
		line.remove_point(0)

func _reset_skid_state() -> void:
	if _is_skidding:
		_is_skidding = false
	_active_skid_left = null
	_active_skid_right = null
	_last_skid_point_left = Vector2.INF
	_last_skid_point_right = Vector2.INF

func _reset_grass_state() -> void:
	_active_grass_left = null
	_active_grass_right = null
	_last_grass_point_left = Vector2.INF
	_last_grass_point_right = Vector2.INF

func _get_skid_mark_root() -> Node2D:
	if skid_mark_root != null and is_instance_valid(skid_mark_root):
		return skid_mark_root

	var scene := get_tree().get_current_scene()
	if scene == null:
		return null

	var node := scene.get_node_or_null("SkidMarks")
	if node == null:
		node = Node2D.new()
		node.name = "SkidMarks"
		node.z_index = 0
		node.z_as_relative = false
		scene.call_deferred("add_child", node)

	skid_mark_root = node
	return skid_mark_root

func _process_collisions(forward_dir: Vector2, pre_slide_velocity: Vector2) -> void:
	if get_slide_collision_count() == 0:
		return

	var accumulated_normal := Vector2.ZERO
	var max_penetration := 0.0

	for i in range(get_slide_collision_count()):
		var collision := get_slide_collision(i)
		if collision == null:
			continue

		var collider := collision.get_collider()
		if collider != null and collider != self and collider.has_method("is_car") and collider.is_car():
			_handle_car_collision(collider, collision, pre_slide_velocity)
			continue
		if collider != null and collider is RigidBody2D and collider.has_method("is_tire_barrier") and collider.is_tire_barrier():
			_handle_tire_collision(collider, collision, pre_slide_velocity)
			continue

		accumulated_normal += collision.get_normal()
		max_penetration = max(max_penetration, collision.get_depth())

	if accumulated_normal != Vector2.ZERO:
		_handle_wall_collision(accumulated_normal, max_penetration, forward_dir)

func _handle_wall_collision(accumulated_normal: Vector2, max_penetration: float, forward_dir: Vector2) -> void:
	had_collision_this_frame = true
	var push_normal := accumulated_normal.normalized()
	position += push_normal * (max_penetration + 1.0)
	current_speed = -abs(current_speed) * bounce_factor
	velocity = forward_dir * current_speed

func _handle_tire_collision(tire_barrier: RigidBody2D, collision: KinematicCollision2D, pre_slide_velocity: Vector2) -> void:
	var surface_normal := collision.get_normal()
	if surface_normal.length_squared() < 0.0001:
		surface_normal = global_position.direction_to(tire_barrier.global_position)
	if surface_normal.length_squared() < 0.0001:
		surface_normal = Vector2.UP
	surface_normal = surface_normal.normalized()

	var tire_impulse := _build_tire_impulse(surface_normal, pre_slide_velocity)
	if tire_impulse != Vector2.ZERO:
		var contact_offset: Vector2 = collision.get_position() - tire_barrier.global_position
		tire_barrier.apply_impulse(tire_impulse, contact_offset)

	var inbound_speed: float = pre_slide_velocity.dot(surface_normal)
	if inbound_speed < 0.0:
		velocity = pre_slide_velocity - surface_normal * inbound_speed * (1.0 + tire_collision_car_bounce)
		velocity *= tire_collision_speed_retention
		sync_speed_from_velocity()

func _build_tire_impulse(surface_normal: Vector2, pre_slide_velocity: Vector2) -> Vector2:
	if surface_normal.length_squared() < 0.0001:
		return Vector2.ZERO
	if pre_slide_velocity.length_squared() < 25.0 and abs(current_speed) < 5.0:
		return Vector2.ZERO

	var collision_normal := surface_normal.normalized()
	var approach_speed: float = max(pre_slide_velocity.dot(-collision_normal), abs(current_speed))
	if approach_speed <= 0.0:
		return Vector2.ZERO

	var impulse_strength: float = max(approach_speed * tire_collision_impulse_multiplier, tire_collision_min_impulse)
	return -collision_normal * impulse_strength

func _handle_car_collision(other_car: CharacterBody2D, collision: KinematicCollision2D, pre_slide_velocity: Vector2) -> void:
	had_collision_this_frame = true
	var other_id := other_car.get_instance_id()
	var current_frame := Engine.get_physics_frames()

	if _collision_partner_frames.get(other_id, -1) == current_frame:
		return

	register_collision_partner(other_id, current_frame)
	if other_car.has_method("register_collision_partner"):
		other_car.register_collision_partner(get_instance_id(), current_frame)

	var collision_normal := other_car.global_position - global_position
	if collision_normal.length_squared() < 0.0001:
		collision_normal = -collision.get_normal()
	if collision_normal.length_squared() < 0.0001:
		collision_normal = Vector2.RIGHT
	collision_normal = collision_normal.normalized()

	var separation_distance := collision.get_depth()
	if separation_distance > 0.0:
		var separation := collision_normal * (separation_distance * 0.5)
		position -= separation
		if other_car is CharacterBody2D:
			other_car.position += separation

	var other_velocity: Vector2 = Vector2.ZERO
	if other_car is CharacterBody2D:
		other_velocity = other_car.velocity

	var self_normal_speed: float = pre_slide_velocity.dot(collision_normal)
	var other_normal_speed: float = other_velocity.dot(collision_normal)
	var relative_normal_speed: float = self_normal_speed - other_normal_speed
	if relative_normal_speed <= 0.0:
		return

	var tangent_self: Vector2 = pre_slide_velocity - collision_normal * self_normal_speed
	var tangent_other: Vector2 = other_velocity - collision_normal * other_normal_speed

	var separation_speed: float = relative_normal_speed * 0.5 * car_collision_bounce_multiplier
	var hit_multiplier: float = max(car_collision_hit_response_multiplier, 1.0)
	var attacker_multiplier: float = 1.0 / hit_multiplier
	var attacker_push: float = separation_speed * attacker_multiplier
	var victim_push: float = separation_speed * hit_multiplier

	velocity = tangent_self - collision_normal * attacker_push
	if other_car is CharacterBody2D:
		other_car.velocity = tangent_other + collision_normal * victim_push

	velocity = velocity.limit_length(max_speed)
	if other_car is CharacterBody2D:
		other_car.velocity = other_car.velocity.limit_length(max_speed)

	sync_speed_from_velocity()
	if other_car.has_method("sync_speed_from_velocity"):
		other_car.sync_speed_from_velocity()

func sync_speed_from_velocity() -> void:
	var forward_dir := Vector2(0, -1).rotated(rotation)
	current_speed = velocity.dot(forward_dir)

func register_collision_partner(partner_id: int, frame: int) -> void:
	_collision_partner_frames[partner_id] = frame

func _purge_old_collision_partners(current_frame: int) -> void:
	for partner_id in _collision_partner_frames.keys():
		if _collision_partner_frames[partner_id] != current_frame:
			_collision_partner_frames.erase(partner_id)

func is_car() -> bool:
	return true
