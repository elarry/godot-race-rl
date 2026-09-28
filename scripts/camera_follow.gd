extends Camera2D

@export var target_paths: Array[NodePath] = []
@export var target_group: StringName = StringName("")
@export var follow_lerp_speed: float = 5.0
@export var zoom_lerp_speed: float = 3.0
@export var min_zoom: float = 0.1
@export var max_zoom: float = 0.3
@export var padding: float = 1000.0
@export var min_extent: float = 120.0

var _viewport_size: Vector2 = Vector2.ZERO

func _ready() -> void:
	_viewport_size = get_viewport_rect().size
	var viewport := get_viewport()
	if viewport:
		viewport.size_changed.connect(_on_viewport_size_changed)

func _on_viewport_size_changed() -> void:
	_viewport_size = get_viewport_rect().size

func _process(delta: float) -> void:
	var targets: Array[Node2D] = _gather_targets()
	if targets.is_empty():
		return

	var bounds: Rect2 = _calculate_bounds(targets)
	var target_position: Vector2 = bounds.get_center()
	global_position = global_position.lerp(target_position, follow_lerp_speed * delta)

	var desired_zoom: float = _compute_zoom(bounds)
	var zoom_vector: Vector2 = Vector2.ONE * desired_zoom
	zoom = zoom.lerp(zoom_vector, zoom_lerp_speed * delta)

func _gather_targets() -> Array[Node2D]:
	var nodes: Array[Node2D] = []
	for path: NodePath in target_paths:
		if path.is_empty():
			continue
		var node: Node = get_node_or_null(path)
		if node is Node2D and is_instance_valid(node):
			nodes.append(node)

	if target_group != StringName(""):
		for group_node: Node in get_tree().get_nodes_in_group(target_group):
			if group_node is Node2D and is_instance_valid(group_node) and not nodes.has(group_node):
				nodes.append(group_node)

	return nodes

func _calculate_bounds(nodes: Array[Node2D]) -> Rect2:
	var rect: Rect2 = Rect2(nodes[0].global_position, Vector2.ZERO)
	for i in range(1, nodes.size()):
		rect = rect.expand(nodes[i].global_position)
	rect = rect.grow(padding)
	return rect

func _compute_zoom(bounds: Rect2) -> float:
	if _viewport_size == Vector2.ZERO:
		_viewport_size = get_viewport_rect().size
		if _viewport_size == Vector2.ZERO:
			return clamp(zoom.x, min_zoom, max_zoom)

	var width: float = max(bounds.size.x, min_extent)
	var height: float = max(bounds.size.y, min_extent)
	var ratio_x: float = _viewport_size.x / width
	var ratio_y: float = _viewport_size.y / height
	var desired: float = min(ratio_x, ratio_y)
	if desired <= 0.0:
		desired = min_zoom

	return clamp(desired, min_zoom, max_zoom)
