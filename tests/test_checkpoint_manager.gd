extends GutTest

func _make_manager(gate_count: int) -> CheckpointManager:
	var manager := CheckpointManager.new()
	for i in range(gate_count):
		manager.add_child(Area2D.new())
	manager._ready()
	return manager

func _free_manager(manager: CheckpointManager) -> void:
	if manager == null:
		return
	for child in manager.get_children():
		if is_instance_valid(child):
			child.free()
	manager.free()

func test_gates_in_order_accumulate_reward() -> void:
	var manager: CheckpointManager = _make_manager(3)
	manager.reward_per_checkpoint = 2.0
	var car := Node2D.new()
	manager.register_car(car)

	manager.get_child(0).body_entered.emit(car)
	manager.get_child(1).body_entered.emit(car)

	assert_eq(manager.consume_checkpoint_reward(car), 4.0, "Two in-order gate passes should accumulate 2x the per-gate reward")
	_free_manager(manager)
	car.free()

func test_out_of_order_pass_is_ignored() -> void:
	var manager: CheckpointManager = _make_manager(3)
	var car := Node2D.new()
	manager.register_car(car)

	manager.get_child(2).body_entered.emit(car)  # skip ahead; should be ignored

	assert_eq(manager.consume_checkpoint_reward(car), 0.0, "Passing a gate out of order should not award reward")
	_free_manager(manager)
	car.free()

func test_wrap_to_zero_completes_a_lap() -> void:
	var manager: CheckpointManager = _make_manager(2)
	var car := Node2D.new()
	manager.register_car(car)

	manager.get_child(0).body_entered.emit(car)
	manager.get_child(1).body_entered.emit(car)

	assert_eq(manager.lap_count(car), 1, "Wrapping past the last gate should complete a lap")
	_free_manager(manager)
	car.free()

func test_lap_completion_awards_lap_bonus_on_top_of_gate_reward() -> void:
	var manager: CheckpointManager = _make_manager(2)
	manager.reward_per_checkpoint = 5.0
	manager.lap_bonus = 50.0
	var car := Node2D.new()
	manager.register_car(car)

	manager.get_child(0).body_entered.emit(car)
	manager.get_child(1).body_entered.emit(car)  # wraps, completing the lap

	assert_eq(manager.consume_checkpoint_reward(car), 60.0, "Lap completion should add lap_bonus on top of the two gate rewards")
	_free_manager(manager)
	car.free()

func test_consume_checkpoint_reward_drains_the_accumulator() -> void:
	var manager: CheckpointManager = _make_manager(1)
	var car := Node2D.new()
	manager.register_car(car)
	manager.get_child(0).body_entered.emit(car)

	assert_gt(manager.consume_checkpoint_reward(car), 0.0)
	assert_eq(manager.consume_checkpoint_reward(car), 0.0, "A second consume should drain to zero")
	_free_manager(manager)
	car.free()

func test_unregistered_body_is_ignored() -> void:
	var manager: CheckpointManager = _make_manager(1)
	var car := Node2D.new()
	manager.register_car(car)
	var other := Node2D.new()  # never registered

	manager.get_child(0).body_entered.emit(other)
	assert_eq(manager.consume_checkpoint_reward(car), 0.0, "An unregistered body passing a gate should not affect a registered car's reward")

	manager.get_child(0).body_entered.emit(car)
	assert_gt(manager.consume_checkpoint_reward(car), 0.0, "A registered car should still be able to pass gates")

	_free_manager(manager)
	car.free()
	other.free()

func test_gate_direction_is_perpendicular_to_shape_rotation() -> void:
	var manager := CheckpointManager.new()

	# Gate 0's CollisionShape2D is rotated 90 deg, so its crossing line runs
	# vertically and travel direction should be perpendicular to that (+X),
	# regardless of where the neighboring gate is.
	var gate0 := Area2D.new()
	var shape0 := CollisionShape2D.new()
	shape0.shape = RectangleShape2D.new()
	shape0.rotation = PI * 0.5
	gate0.add_child(shape0)
	manager.add_child(gate0)

	var gate1 := Area2D.new()
	var shape1 := CollisionShape2D.new()
	shape1.shape = RectangleShape2D.new()
	shape1.position = Vector2(100, 20)
	gate1.add_child(shape1)
	manager.add_child(gate1)

	manager._ready()

	var direction: Vector2 = manager.gate_direction(0)
	assert_almost_eq(direction.x, 1.0, 0.001, "Perpendicular to a shape rotated 90 deg should point along +X")
	assert_almost_eq(direction.y, 0.0, 0.001, "Should ignore the neighbor gate's off-axis Y offset")

	_free_manager(manager)

func test_gate_direction_flips_when_shape_rotates_180_degrees() -> void:
	var manager_before := CheckpointManager.new()
	var gate_before := Area2D.new()
	var shape_before := CollisionShape2D.new()
	shape_before.shape = RectangleShape2D.new()
	shape_before.rotation = PI * 0.5
	gate_before.add_child(shape_before)
	manager_before.add_child(gate_before)
	manager_before._ready()

	var manager_after := CheckpointManager.new()
	var gate_after := Area2D.new()
	var shape_after := CollisionShape2D.new()
	shape_after.shape = RectangleShape2D.new()
	shape_after.rotation = PI * 0.5 + PI  # same shape, rotated a further 180 deg
	gate_after.add_child(shape_after)
	manager_after.add_child(gate_after)
	manager_after._ready()

	var direction_before: Vector2 = manager_before.gate_direction(0)
	var direction_after: Vector2 = manager_after.gate_direction(0)

	assert_almost_eq(direction_after.x, -direction_before.x, 0.001, "Rotating a gate 180 deg should flip its computed direction, not leave it unchanged")
	assert_almost_eq(direction_after.y, -direction_before.y, 0.001)

	_free_manager(manager_before)
	_free_manager(manager_after)

func test_is_stuck_flips_after_threshold() -> void:
	var manager: CheckpointManager = CheckpointManager.new()
	var car := Node2D.new()
	manager.register_car(car)
	assert_false(manager.is_stuck(car, 10.0, 3.9), "3.9s of continuous low speed should not yet flip stuck")
	assert_true(manager.is_stuck(car, 10.0, 0.2), "Crossing 4.0s of continuous low speed should flip stuck")
	manager.free()
	car.free()

func test_is_stuck_resets_when_speed_recovers() -> void:
	var manager: CheckpointManager = CheckpointManager.new()
	var car := Node2D.new()
	manager.register_car(car)
	manager.is_stuck(car, 10.0, 3.0)
	assert_false(manager.is_stuck(car, 100.0, 0.0), "A speed above threshold should reset the stuck timer immediately")
	assert_false(manager.is_stuck(car, 10.0, 3.9), "The reset should mean 3.9s more of low speed is still not enough")
	manager.free()
	car.free()

func test_grass_timer_flips_after_threshold() -> void:
	var manager: CheckpointManager = CheckpointManager.new()
	var car := Node2D.new()
	manager.register_car(car)
	assert_false(manager.update_grass_timer(car, true, CheckpointManager.GRASS_TIME_THRESHOLD - 0.1))
	assert_true(manager.update_grass_timer(car, true, 0.2))
	manager.free()
	car.free()

func test_grass_timer_resets_off_grass() -> void:
	var manager: CheckpointManager = CheckpointManager.new()
	var car := Node2D.new()
	manager.register_car(car)
	manager.update_grass_timer(car, true, 5.0)
	assert_false(manager.update_grass_timer(car, false, 0.0))
	assert_false(manager.update_grass_timer(car, true, 5.9))
	manager.free()
	car.free()

func test_tick_step_flips_after_max_steps() -> void:
	var manager: CheckpointManager = CheckpointManager.new()
	var car := Node2D.new()
	manager.register_car(car)
	var truncated := false
	for i in range(CheckpointManager.MAX_STEPS - 1):
		truncated = manager.tick_step(car)
	assert_false(truncated, "One step short of MAX_STEPS should not truncate yet")
	assert_true(manager.tick_step(car), "Reaching MAX_STEPS should truncate")
	manager.free()
	car.free()

func test_termination_timers_do_not_conflate_with_each_other() -> void:
	var manager: CheckpointManager = CheckpointManager.new()
	var car := Node2D.new()
	manager.register_car(car)
	var stuck: bool = manager.is_stuck(car, 0.0, 10.0)
	var grass: bool = manager.update_grass_timer(car, false, 0.0)
	var truncated: bool = manager.tick_step(car)

	assert_true(stuck, "Stuck should fire on its own schedule")
	assert_false(grass, "Grass timer should not be affected by the stuck timer firing")
	assert_false(truncated, "Step counter should not be affected by the stuck timer firing")
	manager.free()
	car.free()

func test_reset_clears_all_state() -> void:
	var manager: CheckpointManager = _make_manager(2)
	var car := Node2D.new()
	manager.register_car(car)
	manager.get_child(0).body_entered.emit(car)
	manager.get_child(1).body_entered.emit(car)  # completes a lap
	manager.is_stuck(car, 0.0, 10.0)
	manager.update_grass_timer(car, true, 10.0)
	manager.tick_step(car)

	manager.reset(car)

	assert_eq(manager.lap_count(car), 0, "reset() should clear the lap counter")
	assert_eq(manager.consume_checkpoint_reward(car), 0.0, "reset() should clear accumulated reward")
	assert_false(manager.is_stuck(car, 0.0, 0.1), "reset() should clear the stuck timer")
	assert_false(manager.update_grass_timer(car, true, 0.1), "reset() should clear the grass timer")

	manager.get_child(0).body_entered.emit(car)
	assert_gt(manager.consume_checkpoint_reward(car), 0.0, "reset() should rewind next_index so gate 0 is accepted again")

	_free_manager(manager)
	car.free()

# --- Multi-car ---

func test_two_cars_track_progress_independently() -> void:
	var manager: CheckpointManager = _make_manager(3)
	var car_a := Node2D.new()
	var car_b := Node2D.new()
	manager.register_car(car_a)
	manager.register_car(car_b)

	manager.get_child(0).body_entered.emit(car_a)
	manager.get_child(1).body_entered.emit(car_a)  # car_a is now expecting gate 2

	manager.get_child(2).body_entered.emit(car_b)  # out of order for car_b (still expects gate 0) - ignored
	assert_eq(manager.consume_checkpoint_reward(car_b), 0.0, "car_b's out-of-order pass should be ignored regardless of car_a's progress")

	manager.get_child(0).body_entered.emit(car_b)  # in order for car_b
	assert_gt(manager.consume_checkpoint_reward(car_b), 0.0, "car_b should still be able to pass its own next gate")
	assert_gt(manager.consume_checkpoint_reward(car_a), 0.0, "car_a's own accumulated reward should be untouched by car_b's gate passes")

	_free_manager(manager)
	car_a.free()
	car_b.free()

func test_progress_score_orders_by_lap_then_gate() -> void:
	var manager: CheckpointManager = _make_manager(3)
	var leader := Node2D.new()
	var trailer := Node2D.new()
	manager.register_car(leader)
	manager.register_car(trailer)

	# leader completes a full lap (3 gates) plus one more gate into lap 2.
	manager.get_child(0).body_entered.emit(leader)
	manager.get_child(1).body_entered.emit(leader)
	manager.get_child(2).body_entered.emit(leader)  # wraps, lap 1 complete
	manager.get_child(0).body_entered.emit(leader)  # one gate into lap 2

	# trailer passes two gates within lap 1 - more gates passed in-lap, but fewer laps.
	manager.get_child(0).body_entered.emit(trailer)
	manager.get_child(1).body_entered.emit(trailer)

	assert_gt(manager.progress_score(leader), manager.progress_score(trailer), "A car further into a later lap should outrank one with more in-lap gates but fewer laps")

	_free_manager(manager)
	leader.free()
	trailer.free()

func test_lap_count_increments_exactly_once_per_lap() -> void:
	var manager: CheckpointManager = _make_manager(3)
	var car := Node2D.new()
	manager.register_car(car)

	for lap in range(2):
		for i in range(3):
			manager.get_child(i).body_entered.emit(car)

	assert_eq(manager.lap_count(car), 2, "Two full laps of crossings should increment lap_count exactly twice, not more")
	_free_manager(manager)
	car.free()

# --- respawn_at_gate() ---

func test_respawn_at_gate_does_not_inflate_progress_score() -> void:
	var manager: CheckpointManager = _make_manager(5)
	var car := Node2D.new()
	manager.register_car(car)
	manager.get_child(0).body_entered.emit(car)  # earns one gate of legitimate progress
	var score_before: float = manager.progress_score(car)

	manager.respawn_at_gate(car, 4)  # random respawn lands far ahead

	assert_eq(manager.progress_score(car), score_before, "A respawn to a higher gate must not inflate progress_score()")
	_free_manager(manager)
	car.free()

func test_respawn_at_gate_preserves_lap_count() -> void:
	var manager: CheckpointManager = _make_manager(2)
	var car := Node2D.new()
	manager.register_car(car)
	manager.get_child(0).body_entered.emit(car)
	manager.get_child(1).body_entered.emit(car)  # wraps, lap 1 complete
	manager.get_child(0).body_entered.emit(car)
	manager.get_child(1).body_entered.emit(car)  # wraps, lap 2 complete

	manager.respawn_at_gate(car, 0)

	assert_eq(manager.lap_count(car), 2, "respawn_at_gate() must not erase laps already legitimately completed")
	_free_manager(manager)
	car.free()

func test_respawn_at_gate_still_allows_next_gate_to_be_crossed() -> void:
	var manager: CheckpointManager = _make_manager(4)
	var car := Node2D.new()
	manager.register_car(car)

	manager.respawn_at_gate(car, 1)  # placed at gate 1, so gate 2 is next
	manager.get_child(2).body_entered.emit(car)

	assert_gt(manager.consume_checkpoint_reward(car), 0.0, "The gate physically after the respawn point should still award reward when crossed")
	_free_manager(manager)
	car.free()

func test_respawn_at_gate_clears_termination_timers_and_reward() -> void:
	var manager: CheckpointManager = _make_manager(2)
	var car := Node2D.new()
	manager.register_car(car)
	manager.is_stuck(car, 0.0, 10.0)
	manager.update_grass_timer(car, true, 20.0)
	manager.get_child(0).body_entered.emit(car)  # leaves accumulated_reward > 0

	manager.respawn_at_gate(car, 0)

	assert_false(manager.is_stuck(car, 0.0, 0.1), "respawn_at_gate() should clear the stuck timer so the car doesn't insta-re-terminate")
	assert_false(manager.update_grass_timer(car, true, 0.1), "respawn_at_gate() should clear the grass timer so the car doesn't insta-re-terminate")
	assert_eq(manager.consume_checkpoint_reward(car), 0.0, "respawn_at_gate() should clear stale accumulated reward")
	_free_manager(manager)
	car.free()

func test_respawn_at_gate_preserves_step_count_by_default() -> void:
	var manager: CheckpointManager = _make_manager(2)
	var car := Node2D.new()
	manager.register_car(car)
	for i in range(CheckpointManager.MAX_STEPS):
		manager.tick_step(car)  # exhausts the step budget (stuck/grass respawn path)

	manager.respawn_at_gate(car, 0)

	assert_true(manager.tick_step(car), "A stuck/grass respawn must not refill the step budget, or a repeatedly-stuck car could dodge MAX_STEPS forever")
	_free_manager(manager)
	car.free()

func test_respawn_at_gate_resets_step_count_when_timeout_caused_it() -> void:
	var manager: CheckpointManager = _make_manager(2)
	var car := Node2D.new()
	manager.register_car(car)
	for i in range(CheckpointManager.MAX_STEPS):
		manager.tick_step(car)  # this is the respawn's own cause

	manager.respawn_at_gate(car, 0, true)

	assert_false(manager.tick_step(car), "A timeout-caused respawn must refill the step budget, or every following step for this car truncates forever")
	_free_manager(manager)
	car.free()

func test_reset_at_gate_yields_zero_progress_score_regardless_of_gate() -> void:
	var manager: CheckpointManager = _make_manager(5)
	var car := Node2D.new()
	manager.register_car(car)
	manager.get_child(0).body_entered.emit(car)  # some progress before the full reset

	manager.reset_at_gate(car, 3)

	assert_eq(manager.progress_score(car), 0.0, "reset_at_gate() is a full episode reset, so progress_score() should start at 0 regardless of the starting gate")
	_free_manager(manager)
	car.free()

func test_per_car_stuck_timer_does_not_bleed_between_cars() -> void:
	var manager: CheckpointManager = CheckpointManager.new()
	var car_a := Node2D.new()
	var car_b := Node2D.new()
	manager.register_car(car_a)
	manager.register_car(car_b)

	manager.is_stuck(car_a, 0.0, 3.9)  # car_a nearly stuck
	assert_false(manager.is_stuck(car_b, 0.0, 0.2), "car_b's fresh timer should not inherit car_a's accumulated stuck time")

	manager.free()
	car_a.free()
	car_b.free()
