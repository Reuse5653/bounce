extends RefCounted
class_name StageContext

var game_manager: Node
var arena_root: Node2D # rotation pivot root
var motion_root: Node2D # translation root
var walls_container: Node2D
var obstacles_container: Node2D
var rng: RandomNumberGenerator
var max_horizontal_offset: float = 0.0
var arena_center_local: Vector2 = Vector2.ZERO
var wall_thickness: float = 0.0
var motion_origin: Vector2 = Vector2.ZERO

func create_tween() -> Tween:
	if game_manager:
		return game_manager.create_tween()
	return null

func reset_arena_transform() -> void:
	if motion_root:
		motion_root.position = motion_origin
		motion_root.rotation = 0.0
	if arena_root:
		arena_root.rotation = 0.0
		arena_root.position = arena_center_local
	if game_manager and game_manager.has_method("sync_arena_motion_history"):
		game_manager.sync_arena_motion_history()

func clamp_arena_horizontal_position() -> void:
	if not motion_root:
		return
	var base_x := motion_origin.x
	if max_horizontal_offset <= 0.0:
		if not is_equal_approx(motion_root.position.x, base_x):
			motion_root.position.x = base_x
			if game_manager and game_manager.has_method("sync_arena_motion_history"):
				game_manager.sync_arena_motion_history()
		return
	var offset := motion_root.position.x - base_x
	offset = clamp(offset, -max_horizontal_offset, max_horizontal_offset)
	var target_x := base_x + offset
	if not is_equal_approx(motion_root.position.x, target_x):
		motion_root.position.x = target_x
		if game_manager and game_manager.has_method("sync_arena_motion_history"):
			game_manager.sync_arena_motion_history()

func get_arena_center_global() -> Vector2:
	if arena_root:
		return arena_root.to_global(Vector2.ZERO)
	return Vector2.ZERO

func get_motion_offset_x() -> float:
	if not motion_root:
		return 0.0
	return motion_root.position.x - motion_origin.x

func set_motion_offset_x(offset: float) -> void:
	if not motion_root:
		return
	motion_root.position.x = motion_origin.x + offset
