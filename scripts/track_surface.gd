class_name TrackSurface
extends RefCounted

## Shared track-texture surface classification, reused by car.gd (grass driving
## physics) and car_sensors.gd (grass-distance raycasts) so both read the track
## image the same way. Static, parameter-driven - no node/scene-tree dependency.

static func is_grass_color(color: Color, green_component_threshold: float, green_dominance_threshold: float, max_saturation: float, max_brightness: float) -> bool:
	if color.a < 0.1:
		return false

	var max_rgb: float = max(color.r, max(color.g, color.b))
	var min_rgb: float = min(color.r, min(color.g, color.b))
	var saturation: float = max_rgb - min_rgb
	var brightness: float = (color.r + color.g + color.b) * 0.333333
	var green_dominance: float = color.g - 0.5 * (color.r + color.b)

	if saturation <= max_saturation and brightness <= max_brightness:
		return false

	if color.g >= green_component_threshold and green_dominance >= green_dominance_threshold:
		return true

	return color.g > color.r and color.g > color.b and green_dominance > 0.02

static func world_to_pixel(world_pos: Vector2, track_sprite: Sprite2D, track_image_size: Vector2i) -> Vector2i:
	var track_transform: Transform2D = track_sprite.get_global_transform().affine_inverse()
	var local_pos: Vector2 = track_transform * world_pos
	var half_size: Vector2 = Vector2(track_image_size.x, track_image_size.y) * 0.5
	var tex_x: int = int(floor(local_pos.x + half_size.x))
	var tex_y: int = int(floor(local_pos.y + half_size.y))
	return Vector2i(tex_x, tex_y)
