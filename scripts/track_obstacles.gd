extends Node2D

## Automatically generates collision shapes for dark green obstacles (trees/bushes)
## This runs at game startup to create collision bodies

@export var track_sprite_name: String = "Track"
@export var collision_cell_size: int = 8  # Size of each collision cell in pixels (larger = fewer, bigger shapes)
@export var auto_generate: bool = true
@export var debug_output: bool = true  # Print debug information
@export var show_debug_shapes: bool = true  # Draw debug rectangles for collisions

var track_sprite: Sprite2D

func _ready():
	if auto_generate:
		# Wait one frame to ensure track is loaded
		await get_tree().process_frame
		_generate_collision_shapes()

func _generate_collision_shapes():
	print("Generating collision shapes for dark green obstacles...")

	# Find the track sprite
	track_sprite = _find_track_sprite(get_tree().root)

	if not track_sprite or not track_sprite.texture:
		push_error("Track sprite not found or has no texture!")
		return

	var texture = track_sprite.texture
	var image = texture.get_image()
	var texture_size = image.get_size()

	# Track which cells contain dark green pixels
	var dark_green_cells = {}

	# Scan the image and mark cells with dark green pixels
	for y in range(0, int(texture_size.y), collision_cell_size):
		for x in range(0, int(texture_size.x), collision_cell_size):
			if _cell_has_dark_green(image, x, y, collision_cell_size):
				var cell_key = Vector2i(int(x / float(collision_cell_size)), int(y / float(collision_cell_size)))
				dark_green_cells[cell_key] = true

	print("Found ", dark_green_cells.size(), " cells with dark green obstacles")

	# Create collision shapes for each cluster of dark green cells
	var processed = {}
	var cluster_count = 0

	for cell in dark_green_cells.keys():
		if cell in processed:
			continue

		# Find connected cells (flood fill)
		var cluster = _flood_fill_cluster(cell, dark_green_cells, processed)

		if cluster.size() > 0:
			_create_collision_for_cluster(cluster, texture_size)
			cluster_count += 1

	print("Created ", cluster_count, " collision obstacles for trees/bushes")

func _find_track_sprite(node: Node) -> Sprite2D:
	if node is Sprite2D and node.name == track_sprite_name:
		return node
	for child in node.get_children():
		var result = _find_track_sprite(child)
		if result:
			return result
	return null

func _cell_has_dark_green(image: Image, start_x: int, start_y: int, cell_size: int) -> bool:
	# Sample a few pixels in the cell to check for dark green
	var samples = 3  # Check 3x3 points in the cell
	var dark_green_count = 0
	var total_samples = 0

	for sy in range(samples):
		for sx in range(samples):
			var x = start_x + int(sx * cell_size / float(samples))
			var y = start_y + int(sy * cell_size / float(samples))

			if x >= image.get_width() or y >= image.get_height():
				continue

			var pixel = image.get_pixel(x, y)
			total_samples += 1
			if _is_dark_green(pixel):
				dark_green_count += 1

	# If more than 30% of samples are dark green, consider it an obstacle cell
	return dark_green_count >= (total_samples * 0.3)

func _is_dark_green(color: Color) -> bool:
	# Dark green has: medium G value (0.5-0.65), lower R and B values
	# Based on analysis: Dark Green (0.298, 0.588, 0.192)
	# Also need to exclude light grass (0.580, 0.737, 0.337)
	return (color.g > 0.55 and color.g < 0.65 and
			color.g > color.r * 1.8 and
			color.g > color.b * 2.5)

func _flood_fill_cluster(start: Vector2i, all_cells: Dictionary, processed: Dictionary) -> Array[Vector2i]:
	var cluster: Array[Vector2i] = []
	var to_process: Array[Vector2i] = [start]

	while to_process.size() > 0:
		var current = to_process.pop_back()

		if current in processed:
			continue

		if not current in all_cells:
			continue

		processed[current] = true
		cluster.append(current)

		# Check 4-directional neighbors
		var neighbors = [
			Vector2i(current.x + 1, current.y),
			Vector2i(current.x - 1, current.y),
			Vector2i(current.x, current.y + 1),
			Vector2i(current.x, current.y - 1)
		]

		for neighbor in neighbors:
			if not neighbor in processed and neighbor in all_cells:
				to_process.append(neighbor)

	return cluster

func _create_collision_for_cluster(cluster: Array[Vector2i], texture_size: Vector2):
	# Create a StaticBody2D with a collision shape for this cluster
	var static_body = StaticBody2D.new()
	static_body.name = "TreeObstacle_%d" % get_child_count()

	# Find bounding box of the cluster
	var min_x = INF
	var min_y = INF
	var max_x = -INF
	var max_y = -INF

	for cell in cluster:
		var cell_x = float(cell.x * collision_cell_size)
		var cell_y = float(cell.y * collision_cell_size)
		min_x = min(min_x, cell_x)
		min_y = min(min_y, cell_y)
		max_x = max(max_x, cell_x + collision_cell_size)
		max_y = max(max_y, cell_y + collision_cell_size)

	# Create collision shape
	var collision_shape = CollisionShape2D.new()
	var rect_shape = RectangleShape2D.new()

	var width = max_x - min_x
	var height = max_y - min_y
	rect_shape.size = Vector2(width, height)

	# Convert from texture coordinates to world coordinates
	# Account for track sprite's transform
	var track_scale = track_sprite.scale
	var track_pos = track_sprite.global_position

	# Position in texture space (centered origin)
	var texture_local_pos = Vector2(min_x + width/2, min_y + height/2) - texture_size / 2

	# Scale the position by track scale and add track position to get world position
	var world_pos = track_pos + (texture_local_pos * track_scale)

	collision_shape.shape = rect_shape
	collision_shape.position = Vector2.ZERO  # Position is on the StaticBody2D itself

	static_body.position = world_pos
	static_body.scale = track_scale  # Apply scale to the body, not just the shape
	static_body.add_child(collision_shape)

	# Add debug visualization if enabled
	if show_debug_shapes:
		var debug_rect = ColorRect.new()
		debug_rect.size = rect_shape.size
		debug_rect.position = -rect_shape.size / 2  # Center the rect
		debug_rect.color = Color(1.0, 0.0, 0.0, 0.3)  # Semi-transparent red
		debug_rect.z_index = 100  # Draw on top
		static_body.add_child(debug_rect)

	add_child(static_body)

	if debug_output:
		print("  - Obstacle at world pos ", world_pos, " texture pos ", texture_local_pos, " size ", rect_shape.size * track_scale, " (", cluster.size(), " cells)")
