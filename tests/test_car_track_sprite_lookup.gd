extends GutTest

const CAR_SCRIPT: GDScript = preload("res://scripts/car.gd")

## A car with no "Track" sprite in the scene stops retrying the lookup after
## TRACK_LOOKUP_MAX_RETRIES attempts.
func test_track_sprite_lookup_gives_up_after_max_retries() -> void:
	var car: CharacterBody2D = CAR_SCRIPT.new() as CharacterBody2D
	car._track_sprite_warning_logged = true  # suppress the one-time warning; not what this test checks
	add_child_autofree(car)

	for i in range(65):
		await wait_physics_frames(1)

	assert_eq(car._track_lookup_retry_count, 60, "Retry attempts should stop once the cap is reached")
	assert_false(car._track_lookup_retry_scheduled, "No retry should remain scheduled once the cap is reached")
