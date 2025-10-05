extends "res://scripts/stages/stage_base.gd"
class_name StageRotatingArena

const MAX_ROTATION_DEG := 210.0
const MIN_ROTATION_DEG := 90.0
const MIN_ROTATION_DURATION := 2.6
const MAX_ROTATION_DURATION := 4.8
const MIN_TRAVEL_DURATION := 1.1
const MAX_TRAVEL_DURATION := 3.7
const TRAVEL_INNER_RATIO := 0.35
const TRAVEL_OUTER_RATIO := 0.82
const ESCAPE_MARGIN_MULTIPLIER := 2.0

var _rotation_tween: Tween
var _travel_tween: Tween
var _ball: Ball
var _bottom_wall: StaticBody2D

func get_id() -> StringName:
	return &"stage_rotating_arena"

func enter(stage_context: StageContext) -> void:
	super.enter(stage_context)
	context.reset_arena_transform()
	context.clamp_arena_horizontal_position()
	var gm := context.game_manager
	if gm:
		if gm.has_method("launch_ball_from_center"):
			gm.launch_ball_from_center()
		if gm.has_method("get_ball"):
			_ball = gm.get_ball()
		if gm.has_method("get_bottom_wall"):
			_bottom_wall = gm.get_bottom_wall()
		if _ball and is_instance_valid(_ball) and _ball.has_method("set_shallow_correction_enabled"):
			_ball.set_shallow_correction_enabled(false)
	_start_next_rotation()
	_start_next_travel()

func exit() -> void:
	_kill_tweens()
	if context:
		context.reset_arena_transform()
	if _ball and is_instance_valid(_ball) and _ball.has_method("set_shallow_correction_enabled"):
		_ball.set_shallow_correction_enabled(true)
	_ball = null
	_bottom_wall = null
	super.exit()

func on_score_changed(_new_score: int) -> void:
	# no-op for now, kept for future hooks
	pass

func on_horizontal_limit_changed(limit: float) -> void:
	if not context:
		return
	context.max_horizontal_offset = limit
	context.clamp_arena_horizontal_position()
	if _travel_tween and _travel_tween.is_running():
		_travel_tween.kill()
		_start_next_travel()

func _kill_tweens() -> void:
	if _rotation_tween and _rotation_tween.is_running():
		_rotation_tween.kill()
	_rotation_tween = null
	if _travel_tween and _travel_tween.is_running():
		_travel_tween.kill()
	_travel_tween = null

func _start_next_rotation() -> void:
	if not context:
		return
	var arena := context.arena_root
	if not arena:
		return
	var rng := context.rng
	if not rng:
		return
	var direction := 1 if rng.randf() >= 0.5 else -1
	var angle_deg := rng.randf_range(MIN_ROTATION_DEG, MAX_ROTATION_DEG)
	var duration := rng.randf_range(MIN_ROTATION_DURATION, MAX_ROTATION_DURATION)
	var target_rotation := arena.rotation + deg_to_rad(angle_deg * direction)
	_rotation_tween = context.create_tween()
	if not _rotation_tween:
		arena.rotation = wrapf(target_rotation, -TAU, TAU)
		return
	_rotation_tween.tween_property(arena, "rotation", target_rotation, duration).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_rotation_tween.finished.connect(_on_rotation_completed, Object.CONNECT_ONE_SHOT)

func _start_next_travel() -> void:
	if not context:
		return
	var motion := context.motion_root
	if not motion:
		return
	var rng := context.rng
	if not rng:
		return
	var max_offset: float = max(context.max_horizontal_offset, 0.0)
	var base_x := context.motion_origin.x
	if max_offset <= 0.0:
		motion.position.x = base_x
		return
	var inner_limit: float = max_offset * TRAVEL_INNER_RATIO
	if inner_limit >= max_offset:
		inner_limit = max_offset * 0.5
	var outer_limit: float = clamp(max_offset * TRAVEL_OUTER_RATIO, inner_limit, max_offset)
	var direction: float
	var current_offset := motion.position.x - base_x
	if abs(current_offset) > inner_limit:
		direction = - sign(current_offset)
	else:
		direction = -1.0 if rng.randf() < 0.5 else 1.0
	var target_offset: float = direction * rng.randf_range(inner_limit, outer_limit)
	var duration := rng.randf_range(MIN_TRAVEL_DURATION, MAX_TRAVEL_DURATION)
	var target_position: float = base_x + clamp(target_offset, -outer_limit, outer_limit)
	_travel_tween = context.create_tween()
	if not _travel_tween:
		motion.position.x = target_position
		return
	_travel_tween.tween_property(motion, "position:x", target_position, duration).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_travel_tween.finished.connect(_on_travel_completed, Object.CONNECT_ONE_SHOT)

func _on_rotation_completed() -> void:
	_rotation_tween = null
	if not context or not context.arena_root:
		return
	context.arena_root.rotation = wrapf(context.arena_root.rotation, -TAU, TAU)
	_start_next_rotation()

func _on_travel_completed() -> void:
	_travel_tween = null
	if not context:
		return
	context.clamp_arena_horizontal_position()
	_start_next_travel()
func should_ball_escape(ball: Ball, _delta: float) -> Variant:
	if not context or not ball:
		return null
	var gm := context.game_manager
	if not gm:
		return null
	if (not _ball or not is_instance_valid(_ball)) and gm.has_method("get_ball"):
		_ball = gm.get_ball()
	if (not _bottom_wall or not is_instance_valid(_bottom_wall)) and gm.has_method("get_bottom_wall"):
		_bottom_wall = gm.get_bottom_wall()
	var motion := context.motion_root
	if not motion or not is_instance_valid(motion) or not _bottom_wall or not is_instance_valid(_bottom_wall):
		return null
	if not gm.has_method("get_bottom_wall_center") or not gm.has_method("get_control_wall_normal"):
		return null
	var center: Vector2 = gm.get_bottom_wall_center()
	var interior_normal: Vector2 = gm.get_control_wall_normal()
	var to_ball: Vector2 = ball.global_position - center
	var distance: float = to_ball.dot(interior_normal)
	var margin := context.wall_thickness * ESCAPE_MARGIN_MULTIPLIER + ball.radius
	return distance < -margin
