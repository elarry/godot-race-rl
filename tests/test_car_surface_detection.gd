extends GutTest

const CAR_SCRIPT: GDScript = preload("res://scripts/car.gd")

func test_is_grass_color_detects_green() -> void:
	var car: CharacterBody2D = CAR_SCRIPT.new() as CharacterBody2D
	var bright_grass: Color = Color(0.62, 0.78, 0.34, 1.0)
	var is_grass: bool = car.call("_is_grass_color", bright_grass) as bool
	assert_true(is_grass, "Vibrant greens should be treated as grass")
	_free_car(car)

func test_is_grass_color_rejects_dark_asphalt() -> void:
	var car: CharacterBody2D = CAR_SCRIPT.new() as CharacterBody2D
	var asphalt: Color = Color(0.12, 0.12, 0.12, 1.0)
	var is_grass: bool = car.call("_is_grass_color", asphalt) as bool
	assert_false(is_grass, "Dark greys should be classified as tarmac")
	_free_car(car)

func test_check_surface_type_detects_grass_pixel() -> void:
	var image: Image = _make_track_image(Color(0.2, 0.2, 0.2, 1.0))
	image.set_pixel(1, 1, Color(0.65, 0.8, 0.35, 1.0))
	var car: CharacterBody2D = _car_with_track(image)
	car.global_position = Vector2.ZERO
	assert_true(car.check_surface_type(), "Car centered over a grass pixel should report grass")
	_free_car(car)

func test_check_surface_type_detects_tarmac_pixel() -> void:
	var image: Image = _make_track_image(Color(0.2, 0.2, 0.2, 1.0))
	image.set_pixel(1, 1, Color(0.18, 0.18, 0.18, 1.0))
	var car: CharacterBody2D = _car_with_track(image)
	car.global_position = Vector2.ZERO
	assert_false(car.check_surface_type(), "Car centered over dark asphalt should stay on tarmac")
	_free_car(car)

func test_check_surface_type_treats_out_of_bounds_as_grass() -> void:
	var image: Image = _make_track_image(Color(0.2, 0.2, 0.2, 1.0))
	var car: CharacterBody2D = _car_with_track(image)
	car.global_position = Vector2(256, 256)
	assert_true(car.check_surface_type(), "Positions outside the texture bounds should default to grass")
	_free_car(car)

func _make_track_image(base_color: Color) -> Image:
	var image: Image = Image.create(2, 2, false, Image.FORMAT_RGBA8)
	image.fill(base_color)
	return image

func _car_with_track(image: Image) -> CharacterBody2D:
	var car: CharacterBody2D = CAR_SCRIPT.new() as CharacterBody2D
	var sprite: Sprite2D = Sprite2D.new()
	sprite.position = Vector2.ZERO
	car.track_sprite = sprite
	car.track_image = image
	car.track_image_size = Vector2i(image.get_width(), image.get_height())
	return car

func _free_car(car: CharacterBody2D) -> void:
	if car == null:
		return
	var sprite: Sprite2D = car.track_sprite
	if sprite != null and is_instance_valid(sprite):
		sprite.free()
	car.free()
