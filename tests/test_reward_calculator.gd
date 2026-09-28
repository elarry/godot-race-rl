extends GutTest

const TOLERANCE: float = 0.0001

func test_pure_speed_term() -> void:
	var reward: float = RewardCalculator.compute(200.0, 400.0, false, false, 0.0)
	assert_almost_eq(reward, 0.049, TOLERANCE, "Half of max speed should contribute 0.05, minus the per-step cost")

func test_grass_penalty_term() -> void:
	var reward: float = RewardCalculator.compute(0.0, 400.0, true, false, 0.0)
	assert_almost_eq(reward, -0.051, TOLERANCE, "On-grass penalty should subtract 0.05")

func test_collision_penalty_term() -> void:
	var reward: float = RewardCalculator.compute(0.0, 400.0, false, true, 0.0)
	assert_almost_eq(reward, -1.001, TOLERANCE, "Collision penalty should subtract 1.0")

func test_checkpoint_bonus_term() -> void:
	var reward: float = RewardCalculator.compute(0.0, 400.0, false, false, 10.0)
	assert_almost_eq(reward, 9.999, TOLERANCE, "Checkpoint reward should pass through untouched, minus the per-step cost")

func test_combination_of_all_terms() -> void:
	var reward: float = RewardCalculator.compute(400.0, 400.0, true, true, 5.0)
	assert_almost_eq(reward, 4.049, TOLERANCE, "Max speed + grass + collision + checkpoint should sum every term")

func test_zero_max_speed_avoids_division_by_zero() -> void:
	var reward: float = RewardCalculator.compute(100.0, 0.0, false, false, 0.0)
	assert_almost_eq(reward, 0.099, TOLERANCE, "A zero max_speed should not crash; the ratio clamps to 1.0 instead of dividing by zero")

func test_reversing_penalizes_speed_term_by_reverse_penalty_factor() -> void:
	var forward: float = RewardCalculator.compute(200.0, 400.0, false, false, 0.0)
	var reverse: float = RewardCalculator.compute(-200.0, 400.0, false, false, 0.0)
	var forward_speed_term: float = forward + RewardCalculator.TIME_PENALTY
	var reverse_speed_term: float = reverse + RewardCalculator.TIME_PENALTY
	assert_almost_eq(reverse_speed_term, forward_speed_term * RewardCalculator.REVERSE_PENALTY_FACTOR, TOLERANCE, "Reversing at the same magnitude should score REVERSE_PENALTY_FACTOR of forward's speed term, not the same (see _speed_reward()'s comment)")

func test_speed_ratio_clamps_above_max_speed() -> void:
	var reward: float = RewardCalculator.compute(800.0, 400.0, false, false, 0.0)
	assert_almost_eq(reward, 0.099, TOLERANCE, "A speed above max_speed (e.g. a collision bounce) should clamp to a ratio of 1.0, not exceed it")

# --- Race-position term ---

func test_single_car_default_args_reproduce_original_values() -> void:
	var reward: float = RewardCalculator.compute(200.0, 400.0, false, false, 0.0)
	assert_almost_eq(reward, 0.049, TOLERANCE, "Omitting race_rank/num_cars should behave exactly like the pre-multi-car formula")

func test_num_cars_one_ignores_rank() -> void:
	var rank_one: float = RewardCalculator.compute(0.0, 400.0, false, false, 0.0, 1, 1)
	var rank_irrelevant: float = RewardCalculator.compute(0.0, 400.0, false, false, 0.0, 5, 1)
	assert_almost_eq(rank_one, -0.001, TOLERANCE, "A single car should score no race-position bonus regardless of the rank value passed")
	assert_almost_eq(rank_irrelevant, -0.001, TOLERANCE, "num_cars = 1 means there is no pack to lead, so rank must not matter")

func test_race_leader_gets_full_position_bonus() -> void:
	var reward: float = RewardCalculator.compute(0.0, 400.0, false, false, 0.0, 1, 4)
	assert_almost_eq(reward, RewardCalculator.RACE_POSITION_WEIGHT - 0.001, TOLERANCE, "Rank 1 of N should score the full RACE_POSITION_WEIGHT bonus")

func test_race_last_place_gets_no_position_bonus() -> void:
	var reward: float = RewardCalculator.compute(0.0, 400.0, false, false, 0.0, 4, 4)
	assert_almost_eq(reward, -0.001, TOLERANCE, "Last place (rank == num_cars) should score zero race-position bonus")

func test_race_position_bonus_is_linear_for_a_middle_rank() -> void:
	var reward: float = RewardCalculator.compute(0.0, 400.0, false, false, 0.0, 2, 3)
	assert_almost_eq(reward, RewardCalculator.RACE_POSITION_WEIGHT * 0.5 - 0.001, TOLERANCE, "Middle rank of 3 should score half the leader's bonus")
