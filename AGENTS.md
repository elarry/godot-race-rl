# Repository Guidelines

GODOT_PATH="/Applications/Games/Godot.app/Contents/MacOS/Godot"
Godot Version=4.7
Enforce use of static types scripts


## Project Structure & Module Organization
The Godot 4.7 project root contains `project.godot` plus shared resources. Gameplay scenes live in `scenes/` (`main.tscn`, car variants, barrier props) and load scripts from `scripts/`. Reusable art, audio, and UI go in `assets/`. Automated specs and the manual harness are under `tests/`; treat `tests/README.md` as the canonical testing playbook. The RL layer lives under `scripts/rl/` and `scenes/rl/` (Godot side) and `rl/` (Python side, `uv`-managed, its own `pyproject.toml`), kept separate from the shared game scene (`car.tscn`, `main.tscn` are never modified for RL needs).

## Build, Test, and Development Commands
- `"$GODOT_PATH" --editor --path .` opens the project with the expected feature flags (GL Compatibility) and is the preferred way to edit scenes and tweak input maps.
- `"$GODOT_PATH" --path .` launches the main scene defined in `project.godot` for a quick playtest.
- `tests/run_gut.sh` runs the GUT suite headlessly (GUT is vendored in `addons/gut`); in-editor, use **Project → Tools → Gut → Run All**.
- `rl/train.sh` and `rl/inference.sh` launch Godot on `scenes/rl/rl_training.tscn` and start PPO training or inference; see the usage headers in each script.

## Coding Style & Naming Conventions
Author gameplay logic in GDScript with tab indentation (Godot's default) and explicit type hints when Godot infers physics types (`var track_sprite: Sprite2D`). Exported configuration values should favor lower_snake_case (`max_speed`, `drift_factor`) and include inline comments when the tuning is not obvious. Name scenes and resources with descriptive snake_case (`car.tscn`, `outer_wall_boundary.gd`) to mirror existing nodes.

## Testing Guidelines
Primary coverage is the GUT suite in `tests/`: `test_car_surface_detection.gd` (grass/tarmac detection), `test_car_tire_collision.gd` (tire barrier impulse response), `test_car_rl_mode.gd` (RL input hook and collision flag), `test_car_track_sprite_lookup.gd` (bounded Track-sprite retry), `test_car_sensors.gd` (RL observation/raycast extraction), `test_reward_calculator.gd` (RL reward terms), `test_checkpoint_manager.gd` (RL gate/lap/termination logic), `test_outer_wall_boundary.gd` (wall geometry), and `test_tire_barrier_scene.gd` (tire barrier scene structure). Add new tests beside the system under test and mirror the existing `test_*` function naming. When features depend on feel (drift, collision response), validate manually in-editor and describe the steps and observations in the pull request.

## Commit & Pull Request Guidelines
Recent history favors short, present-tense summaries (`drifting works`, `Breaking fixed`). Keep that tone but ensure clarity: lead with the behavior change, optionally append scope (e.g., `Tune friction for grass tiles`). Pull requests should link tracking issues, describe testing (unit + manual), and attach screenshots or GIFs when gameplay visuals change; include reproduction steps for physics regressions.

## Configuration & Input Tips
Centralized input actions (`ui_up`, `ui_left`, etc.) are defined in `project.godot`. Update them through the editor to keep serialized JSON consistent. When adding new scenes, register them in `scenes/` and expose configurable values with `@export` so designers can tweak parameters without modifying scripts.
