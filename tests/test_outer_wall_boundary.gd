extends GutTest

const OUTER_WALL_BOUNDARY_SCRIPT: GDScript = preload("res://scripts/outer_wall_boundary.gd")

func test_ready_creates_four_aligned_walls() -> void:
	var arena: Rect2 = Rect2(Vector2(10, 20), Vector2(100, 60))
	var thickness: float = 8.0
	var boundary: Node2D = _make_boundary(arena, thickness)

	assert_eq(boundary.get_child_count(), 4, "Expected top/bottom/left/right walls")

	_assert_wall(boundary.get_child(0), Vector2(arena.position.x + arena.size.x * 0.5, arena.position.y - thickness * 0.5),
		Vector2(arena.size.x + thickness * 2.0, thickness), "top wall")
	_assert_wall(boundary.get_child(1), Vector2(arena.position.x + arena.size.x * 0.5, arena.position.y + arena.size.y + thickness * 0.5),
		Vector2(arena.size.x + thickness * 2.0, thickness), "bottom wall")
	_assert_wall(boundary.get_child(2), Vector2(arena.position.x - thickness * 0.5, arena.position.y + arena.size.y * 0.5),
		Vector2(thickness, arena.size.y), "left wall")
	_assert_wall(boundary.get_child(3), Vector2(arena.position.x + arena.size.x + thickness * 0.5, arena.position.y + arena.size.y * 0.5),
		Vector2(thickness, arena.size.y), "right wall")
	_free_boundary(boundary)

func _make_boundary(arena: Rect2, thickness: float) -> Node2D:
	var boundary: Node2D = OUTER_WALL_BOUNDARY_SCRIPT.new() as Node2D
	boundary.arena_rect = arena
	boundary.thickness = thickness
	boundary._ready()
	return boundary

func _assert_wall(node: Node, expected_position: Vector2, expected_size: Vector2, label: String) -> void:
	var body: StaticBody2D = node as StaticBody2D
	assert_not_null(body, "%s should be a StaticBody2D" % label)
	assert_eq(body.position, expected_position, "%s center mismatch" % label)

	var shape_node: CollisionShape2D = body.get_child(0) as CollisionShape2D
	assert_not_null(shape_node, "%s needs a CollisionShape2D" % label)
	var rect_shape: RectangleShape2D = shape_node.shape as RectangleShape2D
	assert_not_null(rect_shape, "%s collider must be rectangular" % label)
	assert_eq(rect_shape.size, expected_size, "%s size mismatch" % label)

func _free_boundary(boundary: Node2D) -> void:
	if boundary == null:
		return
	for child in boundary.get_children():
		if is_instance_valid(child):
			child.free()
	boundary.free()
