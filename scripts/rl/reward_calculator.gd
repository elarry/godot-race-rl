class_name RewardCalculator
extends RefCounted

## Per-step reward function. Tune the reward by editing the weights below.

const RACE_POSITION_WEIGHT: float = 0.02  # per-step bonus for leading the pack, scaled by rank
const SPEED_REWARD_WEIGHT: float = 0.1
const REVERSE_PENALTY_FACTOR: float = 0.5
const GRASS_PENALTY: float = 0.05
const COLLISION_PENALTY: float = 1.0
const TIME_PENALTY: float = 0.001

static func compute(speed: float, max_speed: float, on_grass: bool, had_collision: bool, checkpoint_reward: float, race_rank: int = 1, num_cars: int = 1) -> float:
	var reward: float = _speed_reward(speed, max_speed) + checkpoint_reward
	reward += _race_position_bonus(race_rank, num_cars)
	reward -= TIME_PENALTY
	if on_grass:
		reward -= GRASS_PENALTY
	if had_collision:
		reward -= COLLISION_PENALTY
	return reward


# Reverse speed is scaled by REVERSE_PENALTY_FACTOR so driving backwards pays less.
static func _speed_reward(speed: float, max_speed: float) -> float:
	var ratio: float = speed / maxf(max_speed, 0.001)
	var speed_ratio: float
	if ratio >= 0.0:
		speed_ratio = clampf(ratio, 0.0, 1.0)
	else:
		speed_ratio = clampf(-ratio, 0.0, 1.0) * REVERSE_PENALTY_FACTOR
	return speed_ratio * SPEED_REWARD_WEIGHT


# Full bonus for first place, none for last, linear in between. Zero for a single car.
static func _race_position_bonus(race_rank: int, num_cars: int) -> float:
	if num_cars <= 1:
		return 0.0
	var normalized_rank: float = float(num_cars - race_rank) / float(num_cars - 1)
	return normalized_rank * RACE_POSITION_WEIGHT
