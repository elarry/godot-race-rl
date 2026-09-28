extends GutTest

const TIRE_BARRIER_SCENE: PackedScene = preload("res://scenes/tire_barrier.tscn")

func test_tire_barrier_uses_independent_rigid_bodies() -> void:
	var tire_barrier: Node2D = TIRE_BARRIER_SCENE.instantiate() as Node2D

	assert_not_null(tire_barrier, "Tire barrier scene should instantiate")
	assert_true(tire_barrier is Node2D, "Tire barrier root should stay transformable")

	var tire_count: int = 0
	for child: Node in tire_barrier.get_children():
		var tire_body := child as RigidBody2D
		assert_not_null(tire_body, "Each direct child should be an independent tire body")
		assert_true(tire_body.has_method("is_tire_barrier"), "Each tire body should expose the collision marker")

		var sprite: Sprite2D = tire_body.get_node_or_null("Sprite2D") as Sprite2D
		var collider: CollisionShape2D = tire_body.get_node_or_null("CollisionShape2D") as CollisionShape2D
		assert_not_null(sprite, "Each tire body should own a sprite")
		assert_not_null(collider, "Each tire body should own a collision shape")
		tire_count += 1

	assert_eq(tire_count, 13, "The scene should keep the full tire barrier layout")
	tire_barrier.free()
