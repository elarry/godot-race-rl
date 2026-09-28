extends Node2D

@export var arena_rect: Rect2        # e.g., Rect2(0, 0, 1920, 1080)
@export var thickness: float = 48.0  # wall thickness in pixels

func _ready() -> void:
	_make_wall(arena_rect.position + Vector2(arena_rect.size.x/2, -thickness/2),
			   Vector2(arena_rect.size.x + 2*thickness, thickness))       # top
	_make_wall(arena_rect.position + Vector2(arena_rect.size.x/2, arena_rect.size.y + thickness/2),
			   Vector2(arena_rect.size.x + 2*thickness, thickness))       # bottom
	_make_wall(arena_rect.position + Vector2(-thickness/2, arena_rect.size.y/2),
			   Vector2(thickness, arena_rect.size.y))                     # left
	_make_wall(arena_rect.position + Vector2(arena_rect.size.x + thickness/2, arena_rect.size.y/2),
			   Vector2(thickness, arena_rect.size.y))                     # right

func _make_wall(center: Vector2, size: Vector2) -> void:
	var body := StaticBody2D.new()
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = size
	shape.shape = rect
	body.position = center
	body.add_child(shape)
	add_child(body)
