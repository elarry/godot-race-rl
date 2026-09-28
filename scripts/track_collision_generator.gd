@tool
extends Node2D

## This script generates collision shapes for dark green obstacles (trees/bushes) in the track
## Run this from the Godot editor to generate collision shapes

@export var track_texture: Texture2D
@export var collision_cell_size: int = 16  # Size of each collision cell in pixels
@export var generate_collisions: bool = false:
	set(value):
		if value and Engine.is_editor_hint():
			_generate_collision_shapes()
		generate_collisions = false

func _generate_collision_shapes():
	print("Generating collision shapes for dark green obstacles...")

	if not track_texture:
		push_error("No track texture assigned!")
		return

	var image = track_texture.get_image()
	var texture_size = image.get_size()

	# Clear existing collision children
	for child in get_children():
		child.queue_free()

	# Track which cells contain dark green pixels
	var dark_green_cells = {}

	# Scan the image and mark cells with dark green pixels
	for y in range(0, int(texture_size.y), collision_cell_size):
		for x in range(0, int(texture_size.x), collision_cell_size):
			if _cell_has_dark_green(image, x, y, collision_cell_size):
				var cell_key = Vector2i(x / collision_cell_size, y / collision_cell_size)
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
			_create_collision_for_cluster(cluster)
			cluster_count += 1

	print("Created ", cluster_count, " collision obstacles")

func _cell_has_dark_green(image: Image, start_x: int, start_y: int, cell_size: int) -> bool:
	# Sample a few pixels in the cell to check for dark green
	var samples = 4  # Check 4 points in the cell
	var dark_green_count = 0

	for sy in range(samples):
		for sx in range(samples):
			var x = start_x + (sx * cell_size / samples)
			var y = start_y + (sy * cell_size / samples)

			if x >= image.get_width() or y >= image.get_height():
				continue

			var pixel = image.get_pixel(x, y)
			if _is_dark_green(pixel):
				dark_green_count += 1

	# If more than half the samples are dark green, consider it a dark green cell
	return dark_green_count >= (samples * samples / 2)

func _is_dark_green(color: Color) -> bool:
	# Dark green has: medium G value, lower R and B values
	# Based on analysis: Dark Green (0.298, 0.588, 0.192)
	return (color.g > 0.5 and color.g < 0.7 and
			color.g > color.r * 1.5 and
			color.g > color.b * 2.0)

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

func _create_collision_for_cluster(cluster: Array[Vector2i]):
	# Create a StaticBody2D with a collision polygon for this cluster
	var static_body = StaticBody2D.new()
	static_body.name = "TreeObstacle_%d" % get_child_count()

	# Create a rectangular collision shape for the bounding box
	var min_x = INF
	var min_y = INF
	var max_x = -INF
	var max_y = -INF

	for cell in cluster:
		var cell_x = cell.x * collision_cell_size
		var cell_y = cell.y * collision_cell_size
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

	collision_shape.shape = rect_shape
	collision_shape.position = Vector2(min_x + width/2, min_y + height/2) - Vector2(texture_size) / 2

	static_body.add_child(collision_shape)
	collision_shape.owner = get_tree().edited_scene_root

	add_child(static_body)
	static_body.owner = get_tree().edited_scene_root

	print("Created collision at ", collision_shape.position, " size ", rect_shape.size)

var texture_size: Vector2
