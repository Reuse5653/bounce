extends Node2D

const BALL_SCENE := preload("res://scenes/ball.tscn")
const BallScript := preload("res://scripts/ball.gd")
const SpikeIndicatorScene: PackedScene = preload("res://scenes/spike_indicator.tscn")
const BULLET_TIME_SCALE := 0.35
const BULLET_TIME_ENTER := 0.12
const BULLET_TIME_HOLD := 0.18
const BULLET_TIME_EXIT := 0.45
const FAST_FORWARD_STAGE1_DELAY := 0.3
const FAST_FORWARD_STAGE2_DURATION := 0.5
const FAST_FORWARD_STAGE2_END := FAST_FORWARD_STAGE1_DELAY + FAST_FORWARD_STAGE2_DURATION
const POINTS_PER_STAGE := 20

@export var arena_size: float = 640.0
@export var wall_thickness: float = 20.0
@export var base_frequency: float = 220.0
@export var tone_duration: float = 0.14
@export var bottom_active_duration: float = 0.1
@export var bottom_fade_duration: float = 0.2
@export_range(0.0, 1.0, 0.01) var bottom_ghost_alpha: float = 0.35
@export_range(0.0, 1.0, 0.01) var bottom_bounce_alpha_threshold: float = 0.75
@export var bottom_rearm_cooldown: float = 0.1
@export var bottom_rearm_cooldown_min: float = 0
@export_range(0.0, 1.0, 0.01) var combo_blur_max_intensity: float = 0.35
@export var debug_initial_stage_id: StringName = StringName()

var arena_rect: Rect2
@onready var _background_rect: ColorRect = $Background
@onready var _walls_container: Node2D = $Walls
@onready var _obstacles_container: Node2D = $Obstacles
@onready var _combo_label: Label = $UI/ComboCounter
@onready var _blur_rect: ColorRect = $UI/BlurOverlay
var _blur_material: ShaderMaterial
var _arena_motion_root: Node2D
var _arena_rotation_root: Node2D
var _bottom_wall: StaticBody2D
var _bottom_collision: CollisionShape2D
var _bottom_visual: Polygon2D
var _bottom_active := false
enum BottomWallState {GHOST, SOLID, FADING}
var _bottom_state: BottomWallState = BottomWallState.GHOST
var _bottom_transition_tween: Tween
var _bottom_release_timer: Timer
var _bottom_rearm_timer: Timer
var _bottom_fade_alpha: float = 1.0
var _bottom_rearm_blocked: bool = false
var _bottom_immediate_rearm_available: bool = false
var _ball: BallScript
var _bounce_count: int = 0
var _current_frequency: float
var _audio_player: AudioStreamPlayer
var _audio_playback: AudioStreamGeneratorPlayback
var _rng := RandomNumberGenerator.new()
var _obstacle: ObstacleSegment
var _obstacle_animating := false
var _obstacle_pending_cycle := false
var _obstacle_hits: int = 0
var _obstacle_broken := false
var _incoming_obstacle: ObstacleSegment = null
var _retiring_obstacles: Array[ObstacleSegment] = []
var _current_obstacle_config: Dictionary = {}
var _pending_obstacle_config: Dictionary = {}
var _next_obstacle_config: Dictionary = {}
var _indicator_config: Dictionary = {}
var _spike_indicator: SpikeIndicator
var _combo_base_color := Color(1, 1, 1, 0.32)
var _blur_tween: Tween
var _label_tween: Tween
var _label_scale_tween: Tween
var _bullet_time_tween: Tween
var _freeze_amount: float = 0.0
var _fast_forward_tween: Tween
var _fast_forward_blend: float = 0.0
var _fast_forward_active: bool = false
var _fast_forward_hold_time: float = 0.0
var _bullet_time_scale: float = 1.0
var _stage_manager: StageManager
var _combo_label_anchor_configured := false
var _arena_motion_prev_global: Vector2 = Vector2.ZERO
var _arena_motion_velocity: Vector2 = Vector2.ZERO
var _arena_rotation_prev_rotation: float = 0.0
var _arena_rotation_angular_velocity: float = 0.0

func _ready() -> void:
	_rng.randomize()
	_current_frequency = base_frequency
	bottom_bounce_alpha_threshold = clamp(bottom_bounce_alpha_threshold, bottom_ghost_alpha, 1.0)
	_recalculate_arena_rect()
	_ensure_arena_motion_root()
	_setup_background()
	_setup_ui()
	_setup_audio()
	if not _bottom_release_timer:
		_bottom_release_timer = Timer.new()
		_bottom_release_timer.one_shot = true
		_bottom_release_timer.name = "BottomWallReleaseTimer"
		add_child(_bottom_release_timer)
		_bottom_release_timer.timeout.connect(_on_bottom_wall_release_timeout)
	if not _bottom_rearm_timer:
		_bottom_rearm_timer = Timer.new()
		_bottom_rearm_timer.one_shot = true
		_bottom_rearm_timer.name = "BottomWallRearmTimer"
		add_child(_bottom_rearm_timer)
		_bottom_rearm_timer.timeout.connect(_on_bottom_wall_rearm_timeout)
	_build_walls()
	_initialize_obstacle()
	_reparent_to_arena_rotation_root(_walls_container)
	_reparent_to_arena_rotation_root(_obstacles_container)
	_initialize_stage_system()
	_spawn_ball()
	if debug_initial_stage_id != StringName():
		developer_jump_to_stage(debug_initial_stage_id)
	set_process(true)

func _process(delta: float) -> void:
	var just_pressed := Input.is_action_just_pressed("ui_accept")
	var just_released := Input.is_action_just_released("ui_accept")
	var pressed := Input.is_action_pressed("ui_accept")
	if just_pressed:
		_request_bottom_wall_activation()
	if pressed:
		_fast_forward_hold_time = min(_fast_forward_hold_time + delta, FAST_FORWARD_STAGE2_END + 1.0)
		var target_multiplier: float = _compute_fast_forward_multiplier(_fast_forward_hold_time)
		_set_fast_forward_state(target_multiplier > 1.0, target_multiplier)
	else:
		_fast_forward_hold_time = 0.0
		_set_fast_forward_state(false, 1.0)
	if just_released and not pressed:
		_fast_forward_hold_time = 0.0
	if _stage_manager:
		_stage_manager.process(delta)
	_update_arena_motion_metrics(delta)
	_update_combo_label_follow()

func _setup_background() -> void:
	RenderingServer.set_default_clear_color(Color.BLACK)
	if _background_rect:
		_background_rect.color = Color.BLACK
		_background_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_background_rect.z_index = -100
		_background_rect.z_as_relative = false

func _setup_ui() -> void:
	if _combo_label:
		_combo_label.text = "0"
		_combo_label.scale = Vector2.ONE
		_combo_base_color = _combo_label.modulate
		_combo_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_combo_label.set_anchors_preset(Control.PRESET_CENTER)
		_combo_label.anchor_left = 0.5
		_combo_label.anchor_right = 0.5
		_combo_label.anchor_top = 0.5
		_combo_label.anchor_bottom = 0.5
		_combo_label.position = Vector2.ZERO
		_combo_label.pivot_offset = _combo_label.size * 0.5
		var resized_callable := Callable(self, "_on_combo_label_resized")
		if not _combo_label.is_connected("resized", resized_callable):
			_combo_label.resized.connect(resized_callable)
		call_deferred("_update_combo_label_pivot")
		_combo_label_anchor_configured = true
	if _blur_rect:
		if not _blur_material:
			var shader := load("res://shaders/flash_blur.gdshader") as Shader
			if shader:
				_blur_material = ShaderMaterial.new()
				_blur_material.shader = shader
				_blur_rect.material = _blur_material
		else:
			_blur_material = _blur_rect.material as ShaderMaterial
		_blur_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_blur_rect.z_index = 1000
		_blur_rect.z_as_relative = false
	if _blur_material:
		_blur_material.set_shader_parameter("intensity", 0.0)
		_blur_material.set_shader_parameter("freeze_amount", 0.0)

func _on_combo_label_resized() -> void:
	_update_combo_label_pivot()

func _update_combo_label_pivot() -> void:
	if _combo_label:
		_combo_label.pivot_offset = _combo_label.size * 0.5
		_update_combo_label_follow()

func _setup_audio() -> void:
	_audio_player = AudioStreamPlayer.new()
	_audio_player.name = "BounceTone"
	var generator := AudioStreamGenerator.new()
	generator.mix_rate = 48000
	generator.buffer_length = 0.3
	_audio_player.stream = generator
	add_child(_audio_player)
	_audio_player.play()
	_audio_playback = _audio_player.get_stream_playback()

func _ensure_arena_motion_root() -> void:
	if not _arena_motion_root or not is_instance_valid(_arena_motion_root):
		if has_node("ArenaMotionRoot"):
			_arena_motion_root = get_node("ArenaMotionRoot") as Node2D
		else:
			_arena_motion_root = Node2D.new()
			_arena_motion_root.name = "ArenaMotionRoot"
			add_child(_arena_motion_root)
	if not _arena_rotation_root or not is_instance_valid(_arena_rotation_root):
		if _arena_motion_root.has_node("ArenaRotationRoot"):
			_arena_rotation_root = _arena_motion_root.get_node("ArenaRotationRoot") as Node2D
		else:
			_arena_rotation_root = Node2D.new()
			_arena_rotation_root.name = "ArenaRotationRoot"
			_arena_motion_root.add_child(_arena_rotation_root)
	_reset_arena_roots_transform()

func _reset_arena_roots_transform() -> void:
	if _arena_motion_root:
		_arena_motion_root.position = _get_arena_center_local()
		_arena_motion_root.rotation = 0.0
		_arena_motion_root.scale = Vector2.ONE
	if _arena_rotation_root:
		_arena_rotation_root.rotation = 0.0
		_arena_rotation_root.scale = Vector2.ONE
		_arena_rotation_root.position = Vector2.ZERO
		if _stage_manager:
			_stage_manager.update_arena_center(_arena_motion_root.position)
	_sync_arena_motion_history()

func _reparent_to_arena_rotation_root(node: Node) -> void:
	if not node:
		return
	if not _arena_rotation_root:
		return
	if node == _arena_rotation_root:
		return
	var parent := node.get_parent()
	if parent == _arena_rotation_root:
		return
	if parent:
		parent.remove_child(node)
	_arena_rotation_root.add_child(node)

func _compute_arena_horizontal_offset_limit() -> float:
	var viewport_rect := get_viewport_rect()
	var surplus := (viewport_rect.size.x - arena_rect.size.x) * 0.5
	if surplus <= 0.0:
		return 0.0
	return max(surplus - wall_thickness * 0.5, 0.0)

func _get_arena_center_local() -> Vector2:
	return arena_rect.position + arena_rect.size * 0.5

func _to_arena_local(point: Vector2) -> Vector2:
	return point - _get_arena_center_local()

func _from_arena_local(point: Vector2) -> Vector2:
	return _get_arena_center_local() + point

func get_arena_motion_velocity() -> Vector2:
	return _arena_motion_velocity

func get_arena_surface_velocity(global_point: Vector2) -> Vector2:
	var velocity := _arena_motion_velocity
	if _arena_rotation_root and is_instance_valid(_arena_rotation_root):
		var center := _arena_rotation_root.get_global_position()
		var omega := _arena_rotation_angular_velocity
		if abs(omega) > 0.0001:
			var r := global_point - center
			velocity += Vector2(-r.y, r.x) * omega
	return velocity

func sync_arena_motion_history() -> void:
	_sync_arena_motion_history()

func get_arena_center_global() -> Vector2:
	if _arena_rotation_root and is_instance_valid(_arena_rotation_root):
		return _arena_rotation_root.get_global_position()
	return arena_rect.position + arena_rect.size * 0.5

func get_arena_half_extents() -> Vector2:
	return arena_rect.size * 0.5

func launch_ball_from_center(reset_velocity: bool = true) -> void:
	if not is_instance_valid(_ball):
		return
	var center := get_arena_center_global()
	if reset_velocity:
		_ball.reset_ball(center)
	else:
		_ball.global_position = center

func _update_stage_context_bounds() -> void:
	if not _stage_manager:
		return
	_stage_manager.update_horizontal_limit(_compute_arena_horizontal_offset_limit())

func _sync_arena_motion_history() -> void:
	if _arena_motion_root and is_instance_valid(_arena_motion_root):
		_arena_motion_prev_global = _arena_motion_root.get_global_position()
	else:
		_arena_motion_prev_global = Vector2.ZERO
	_arena_motion_velocity = Vector2.ZERO
	if _arena_rotation_root and is_instance_valid(_arena_rotation_root):
		_arena_rotation_prev_rotation = _arena_rotation_root.global_rotation
	else:
		_arena_rotation_prev_rotation = 0.0
	_arena_rotation_angular_velocity = 0.0

func _update_arena_motion_metrics(delta: float) -> void:
	var safe_delta: float = max(delta, 0.0001)
	if _arena_motion_root and is_instance_valid(_arena_motion_root):
		var current_motion := _arena_motion_root.get_global_position()
		_arena_motion_velocity = (current_motion - _arena_motion_prev_global) / safe_delta
		_arena_motion_prev_global = current_motion
	else:
		_arena_motion_velocity = Vector2.ZERO
		_arena_motion_prev_global = Vector2.ZERO
	if _arena_rotation_root and is_instance_valid(_arena_rotation_root):
		var current_rotation := _arena_rotation_root.global_rotation
		var delta_rot := wrapf(current_rotation - _arena_rotation_prev_rotation, -PI, PI)
		_arena_rotation_angular_velocity = delta_rot / safe_delta
		_arena_rotation_prev_rotation = current_rotation
	else:
		_arena_rotation_angular_velocity = 0.0
		_arena_rotation_prev_rotation = 0.0

func _convert_obstacle_base(base_global: Vector2, direction: Vector2, length: float) -> Vector2:
	var local := _to_arena_local(base_global)
	var dir := direction.normalized()
	if dir.length_squared() <= 0.0001:
		return local
	var half := arena_rect.size * 0.5
	var margin := wall_thickness
	var min_bounds := Vector2(-half.x + margin, -half.y + margin)
	var max_bounds := Vector2(half.x - margin, half.y - margin)
	var start := local
	var end := local + dir * length
	var shift := Vector2.ZERO
	if abs(dir.x) > abs(dir.y):
		var min_x: float = min(start.x, end.x)
		var max_x: float = max(start.x, end.x)
		if min_x < min_bounds.x:
			shift.x = min_bounds.x - min_x
			min_x += shift.x
			max_x += shift.x
		if max_x > max_bounds.x:
			shift.x += max_bounds.x - max_x
	else:
		var min_y: float = min(start.y, end.y)
		var max_y: float = max(start.y, end.y)
		if min_y < min_bounds.y:
			shift.y = min_bounds.y - min_y
			min_y += shift.y
			max_y += shift.y
		if max_y > max_bounds.y:
			shift.y += max_bounds.y - max_y
	return local + shift

func _prepare_obstacle_runtime_config(config: Dictionary) -> Dictionary:
	var runtime := {}
	var direction: Vector2 = config.get("direction", Vector2.DOWN) as Vector2
	if direction.length_squared() <= 0.0001:
		direction = Vector2.DOWN
	direction = direction.normalized()
	var length: float = float(config.get("length", wall_thickness * 2.5))
	var base_global: Vector2 = config.get("base", _from_arena_local(Vector2.ZERO)) as Vector2
	var local_base := _convert_obstacle_base(base_global, direction, length)
	var corrected_base_global := _from_arena_local(local_base)
	config["base"] = corrected_base_global
	config["direction"] = direction
	config["length"] = length
	runtime["local_base"] = local_base
	runtime["direction"] = direction
	runtime["length"] = length
	runtime["base_global"] = corrected_base_global
	return runtime

func _get_arena_center_screen_position() -> Vector2:
	if _arena_rotation_root and is_instance_valid(_arena_rotation_root):
		return _arena_rotation_root.to_global(Vector2.ZERO)
	return arena_rect.position + arena_rect.size * 0.5

func _update_combo_label_follow() -> void:
	if not _combo_label or not _combo_label_anchor_configured:
		return
	var center := _get_arena_center_screen_position()
	var pivot := _combo_label.pivot_offset
	var scaled_pivot := Vector2(pivot.x * _combo_label.scale.x, pivot.y * _combo_label.scale.y)
	_combo_label.global_position = center - scaled_pivot

func _initialize_stage_system() -> void:
	var context := StageContext.new()
	context.game_manager = self
	context.arena_root = _arena_rotation_root
	context.motion_root = _arena_motion_root
	context.walls_container = _walls_container
	context.obstacles_container = _obstacles_container
	context.rng = _rng
	context.max_horizontal_offset = _compute_arena_horizontal_offset_limit()
	context.motion_origin = _arena_motion_root.position if _arena_motion_root else Vector2.ZERO
	context.arena_center_local = _arena_rotation_root.position if _arena_rotation_root else Vector2.ZERO
	context.wall_thickness = wall_thickness
	_stage_manager = StageManager.new(context, POINTS_PER_STAGE)
	_stage_manager.register_stage(0, StageStaticArena.new())
	_stage_manager.register_stage(POINTS_PER_STAGE, StageRotatingArena.new())
	_stage_manager.activate_for_score(_bounce_count)

func developer_list_stage_ids() -> Array[StringName]:
	if not _stage_manager:
		return []
	return _stage_manager.get_registered_stage_ids()

func developer_configure_stage_sequence(stage_ids: Array[StringName]) -> void:
	if not _stage_manager:
		return
	_stage_manager.set_custom_sequence(stage_ids)
	_stage_manager.activate_for_score(_bounce_count)

func developer_clear_stage_sequence_override() -> void:
	if not _stage_manager:
		return
	_stage_manager.clear_custom_sequence()
	_stage_manager.activate_for_score(_bounce_count)

func developer_clear_stage_override() -> void:
	if not _stage_manager:
		return
	_stage_manager.clear_override_stage(false)
	_stage_manager.activate_for_score(_bounce_count)

func developer_jump_to_stage(stage_id: StringName, lock_stage: bool = true, restart_stage: bool = true) -> void:
	if not _stage_manager:
		return
	if stage_id == StringName():
		push_warning("developer_jump_to_stage: stage_id is empty")
		return
	if not _stage_manager.has_stage(stage_id):
		push_warning("developer_jump_to_stage: unknown stage '%s'" % stage_id)
		return
	if lock_stage:
		_stage_manager.set_override_stage(stage_id, false)
	else:
		_stage_manager.clear_override_stage(false)
	_reset_round()
	if lock_stage:
		_stage_manager.set_override_stage(stage_id, restart_stage)
	else:
		_stage_manager.force_switch_to_stage(stage_id, restart_stage)

func get_ball() -> BallScript:
	return _ball

func get_bottom_wall() -> StaticBody2D:
	return _bottom_wall

func get_bottom_wall_center() -> Vector2:
	if _bottom_collision and is_instance_valid(_bottom_collision):
		return _bottom_collision.to_global(Vector2.ZERO)
	if _bottom_wall and is_instance_valid(_bottom_wall):
		return _bottom_wall.to_global(Vector2.ZERO)
	return Vector2.ZERO

func get_control_wall_normal() -> Vector2:
	if _bottom_wall and is_instance_valid(_bottom_wall):
		var wall_transform := _bottom_wall.get_global_transform()
		var interior := (-wall_transform.y).normalized()
		if interior.length_squared() > 0.0001:
			return interior
	return Vector2.UP

func get_motion_root() -> Node2D:
	return _arena_motion_root

func get_rotation_root() -> Node2D:
	return _arena_rotation_root

func should_ball_escape(ball: Ball, delta: float) -> bool:
	var stage_result: Variant = null
	if _stage_manager:
		stage_result = _stage_manager.should_ball_escape(ball, delta)
	if stage_result is bool and stage_result:
		return true
	if _is_ball_outside_arena_bounds(ball):
		clamp_ball_to_arena_bounds(ball)
		if _is_ball_outside_arena_bounds(ball):
			return true
	if stage_result is bool:
		return false
	return false

func clamp_ball_to_arena_bounds(ball: Ball) -> void:
	if not ball:
		return
	var rotation_root := get_rotation_root()
	if not rotation_root or not is_instance_valid(rotation_root):
		return
	var half_extents := get_arena_half_extents()
	if half_extents == Vector2.ZERO:
		return
	var margin := wall_thickness + ball.radius
	var local_pos := rotation_root.to_local(ball.global_position)
	var clamped_local := local_pos
	var left_limit := -half_extents.x + margin
	var right_limit := half_extents.x - margin
	clamped_local.x = clamp(local_pos.x, left_limit, right_limit)
	var top_limit := -half_extents.y + margin
	if local_pos.y < top_limit:
		clamped_local.y = top_limit
	elif _bottom_active:
		var bottom_limit := half_extents.y - margin
		if local_pos.y > bottom_limit:
			clamped_local.y = bottom_limit
	if not clamped_local.is_equal_approx(local_pos):
		ball.global_position = rotation_root.to_global(clamped_local)

func _is_ball_outside_arena_bounds(ball: Ball) -> bool:
	if not ball:
		return false
	var rotation_root := get_rotation_root()
	if not rotation_root or not is_instance_valid(rotation_root):
		return false
	var inv := rotation_root.get_global_transform().affine_inverse()
	var local_pos: Vector2 = inv * ball.global_position
	var half_extents := get_arena_half_extents()
	var margin := wall_thickness * 2.0 + ball.radius
	if abs(local_pos.x) > half_extents.x + margin:
		return true
	if abs(local_pos.y) > half_extents.y + margin:
		return true
	return false

func _recalculate_arena_rect() -> void:
	var viewport_rect := get_viewport_rect()
	var size := Vector2(arena_size, arena_size)
	var center := viewport_rect.size * 0.5
	var top_left := center - size * 0.5
	arena_rect = Rect2(top_left, size)
	_update_stage_context_bounds()

func _build_walls() -> void:
	if not _walls_container:
		_walls_container = Node2D.new()
		_walls_container.name = "Walls"
		_reparent_to_arena_rotation_root(_walls_container)
	else:
		_reparent_to_arena_rotation_root(_walls_container)
	for child in _walls_container.get_children():
		child.queue_free()
	var center := _get_arena_center_local()
	var left_wall := _create_wall_rect("WallLeft", Rect2(arena_rect.position, Vector2(wall_thickness, arena_rect.size.y)), center)
	var right_wall := _create_wall_rect("WallRight", Rect2(Vector2(arena_rect.position.x + arena_rect.size.x - wall_thickness, arena_rect.position.y), Vector2(wall_thickness, arena_rect.size.y)), center)
	var top_wall := _create_wall_rect("WallTop", Rect2(arena_rect.position, Vector2(arena_rect.size.x, wall_thickness)), center)
	_walls_container.add_child(left_wall)
	_walls_container.add_child(right_wall)
	_walls_container.add_child(top_wall)
	_build_bottom_wall(center)

func _create_wall_rect(wall_name: String, rect: Rect2, center: Vector2) -> StaticBody2D:
	var body := StaticBody2D.new()
	body.name = wall_name
	var collision := CollisionShape2D.new()
	collision.name = "CollisionShape2D"
	var shape := RectangleShape2D.new()
	shape.size = rect.size
	collision.shape = shape
	collision.position = rect.size * 0.5
	body.add_child(collision)
	var visual := Polygon2D.new()
	visual.name = "Visual"
	visual.polygon = PackedVector2Array([
		Vector2.ZERO,
		Vector2(rect.size.x, 0.0),
		rect.size,
		Vector2(0.0, rect.size.y)
	])
	visual.color = Color.WHITE
	body.add_child(visual)
	body.position = rect.position - center
	return body

func _build_bottom_wall(center: Vector2) -> void:
	var rect := Rect2(
		Vector2(arena_rect.position.x, arena_rect.position.y + arena_rect.size.y - wall_thickness),
		Vector2(arena_rect.size.x, wall_thickness)
	)
	_bottom_wall = _create_wall_rect("WallBottom", rect, center)
	_bottom_wall.add_to_group("bottom_wall")
	_walls_container.add_child(_bottom_wall)
	_bottom_collision = _bottom_wall.get_node("CollisionShape2D") as CollisionShape2D
	_bottom_visual = _bottom_wall.get_node("Visual") as Polygon2D
	_bottom_active = false
	_bottom_state = BottomWallState.GHOST
	_bottom_fade_alpha = bottom_ghost_alpha
	_kill_bottom_transition_tween()
	if _bottom_release_timer:
		_bottom_release_timer.stop()
	if _bottom_rearm_timer:
		_bottom_rearm_timer.stop()
	_bottom_rearm_blocked = false
	_update_bottom_wall_state()

func _update_bottom_wall_state() -> void:
	if not _bottom_collision or not _bottom_visual:
		return
	match _bottom_state:
		BottomWallState.GHOST:
			_apply_bottom_wall_alpha(bottom_ghost_alpha)
		BottomWallState.SOLID:
			_apply_bottom_wall_alpha(1.0)
		BottomWallState.FADING:
			_apply_bottom_wall_alpha(_bottom_fade_alpha)

func _apply_bottom_wall_alpha(alpha: float) -> void:
	_bottom_fade_alpha = clamp(alpha, 0.0, 1.0)
	if _bottom_visual:
		_bottom_visual.color = Color(1, 1, 1, _bottom_fade_alpha)
	var can_bounce := false
	match _bottom_state:
		BottomWallState.SOLID:
			can_bounce = true
		BottomWallState.FADING:
			can_bounce = _bottom_fade_alpha >= bottom_bounce_alpha_threshold
		_:
			can_bounce = false
	if _bottom_collision:
		_bottom_collision.disabled = not can_bounce
	_bottom_active = can_bounce

func _set_bottom_fade_alpha(alpha: float) -> void:
	_bottom_fade_alpha = clamp(alpha, bottom_ghost_alpha, 1.0)
	_apply_bottom_wall_alpha(_bottom_fade_alpha)

func _request_bottom_wall_activation() -> void:
	if _bottom_rearm_blocked:
		return
	if _bottom_state == BottomWallState.SOLID:
		return
	if _bottom_state == BottomWallState.FADING and not _bottom_immediate_rearm_available:
		return
	_activate_bottom_wall()

func _activate_bottom_wall() -> void:
	_kill_bottom_transition_tween()
	if _bottom_rearm_timer:
		_bottom_rearm_timer.stop()
	_bottom_rearm_blocked = false
	if _bottom_immediate_rearm_available:
		_bottom_immediate_rearm_available = false
	_bottom_state = BottomWallState.SOLID
	_bottom_fade_alpha = 1.0
	_update_bottom_wall_state()
	if _bottom_release_timer:
		_bottom_release_timer.stop()
		_bottom_release_timer.wait_time = max(bottom_active_duration, 0.01)
		_bottom_release_timer.start()

func _kill_bottom_transition_tween() -> void:
	if _bottom_transition_tween:
		if _bottom_transition_tween.is_running():
			_bottom_transition_tween.kill()
		_bottom_transition_tween = null

func _on_bottom_wall_release_timeout() -> void:
	if _bottom_state != BottomWallState.SOLID:
		return
	_begin_bottom_wall_fade()

func _begin_bottom_wall_fade() -> void:
	_bottom_state = BottomWallState.FADING
	_bottom_rearm_blocked = not _bottom_immediate_rearm_available
	_bottom_fade_alpha = 1.0
	_update_bottom_wall_state()
	_kill_bottom_transition_tween()
	if _bottom_release_timer:
		_bottom_release_timer.stop()
	if not _bottom_visual:
		_on_bottom_wall_fade_finished()
		return
	_bottom_transition_tween = create_tween()
	_bottom_transition_tween.tween_method(Callable(self, "_set_bottom_fade_alpha"), _bottom_fade_alpha, bottom_ghost_alpha, max(bottom_fade_duration, 0.01)).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	_bottom_transition_tween.finished.connect(_on_bottom_wall_fade_finished)

func _on_bottom_wall_fade_finished() -> void:
	_bottom_transition_tween = null
	_bottom_state = BottomWallState.GHOST
	_bottom_fade_alpha = bottom_ghost_alpha
	_update_bottom_wall_state()
	if _bottom_immediate_rearm_available:
		_bottom_rearm_blocked = false
		_bottom_immediate_rearm_available = false
		return
	_schedule_bottom_wall_rearm()

func _schedule_bottom_wall_rearm() -> void:
	if _bottom_immediate_rearm_available:
		return
	if _bottom_rearm_timer:
		_bottom_rearm_timer.stop()
	_bottom_immediate_rearm_available = false
	var wait_time: float = _get_dynamic_bottom_rearm_cooldown()
	if wait_time <= 0.0:
		_bottom_rearm_blocked = false
		return
	_bottom_rearm_blocked = true
	if _bottom_rearm_timer:
		_bottom_rearm_timer.wait_time = max(wait_time, 0.01)
		_bottom_rearm_timer.start()

func _on_bottom_wall_rearm_timeout() -> void:
	_bottom_rearm_blocked = false

func _get_dynamic_bottom_rearm_cooldown() -> float:
	var base_cooldown: float = max(bottom_rearm_cooldown, bottom_rearm_cooldown_min)
	if bottom_rearm_cooldown_min >= base_cooldown:
		return bottom_rearm_cooldown_min
	if not is_instance_valid(_ball):
		return base_cooldown
	var base_speed: float = max(_ball.initial_speed, 1.0)
	var current_speed: float = max(_ball.get_speed(), base_speed)
	var speed_multiplier: float = max(_ball.speed_multiplier, 1.0)
	var max_combo_ratio: float = 1.0
	if speed_multiplier > 1.001:
		max_combo_ratio = pow(speed_multiplier, 19.0)
	if max_combo_ratio <= 1.0:
		return base_cooldown
	var current_ratio: float = current_speed / base_speed
	var normalized: float = clamp((current_ratio - 1.0) / (max_combo_ratio - 1.0), 0.0, 1.0)
	return lerp(base_cooldown, bottom_rearm_cooldown_min, normalized)

func _initialize_obstacle() -> void:
	if not _obstacles_container:
		_obstacles_container = Node2D.new()
		_obstacles_container.name = "Obstacles"
		_reparent_to_arena_rotation_root(_obstacles_container)
	else:
		_reparent_to_arena_rotation_root(_obstacles_container)
	for child in _obstacles_container.get_children():
		child.queue_free()
	_spike_indicator = null
	_retiring_obstacles.clear()
	_obstacle = null
	_incoming_obstacle = null
	_pending_obstacle_config.clear()
	_prime_obstacle_queue(true)

func _prime_obstacle_queue(animated_indicator: bool) -> void:
	if not _obstacles_container:
		return
	if is_instance_valid(_obstacle):
		_obstacle.queue_free()
	_obstacle = null
	if is_instance_valid(_incoming_obstacle):
		_incoming_obstacle.queue_free()
	_incoming_obstacle = null
	for retiring_obstacle in _retiring_obstacles:
		if is_instance_valid(retiring_obstacle):
			retiring_obstacle.queue_free()
	_retiring_obstacles.clear()
	_obstacle_animating = false
	_obstacle_pending_cycle = false
	_obstacle_broken = false
	_obstacle_hits = 0
	_pending_obstacle_config.clear()
	_current_obstacle_config.clear()
	var initial_config := _generate_obstacle_config()
	_next_obstacle_config = initial_config.duplicate(true)
	_prepare_obstacle_runtime_config(_next_obstacle_config)
	_indicator_config = _next_obstacle_config.duplicate(true)
	_show_indicator_for_config(_indicator_config, animated_indicator)

func _ensure_spike_indicator() -> SpikeIndicator:
	if not _obstacles_container:
		return null
	if not is_instance_valid(_spike_indicator):
		_spike_indicator = SpikeIndicatorScene.instantiate() as SpikeIndicator
		_spike_indicator.tile_size = wall_thickness
		_spike_indicator.spike_length = wall_thickness
		_spike_indicator.z_index = 5
		_spike_indicator.z_as_relative = false
		_spike_indicator.set_visible_amount(0.0)
		_obstacles_container.add_child(_spike_indicator)
	return _spike_indicator

func _prepare_next_indicator(current_config: Dictionary) -> void:
	if not _obstacles_container:
		return
	if current_config.is_empty():
		_hide_indicator(true)
		return
	_next_obstacle_config = _generate_obstacle_config(current_config)
	_indicator_config = _next_obstacle_config.duplicate(true)
	_prepare_obstacle_runtime_config(_indicator_config)
	_show_indicator_for_config(_indicator_config, true)

func _show_indicator_for_config(config: Dictionary, animated: bool) -> void:
	if config.is_empty():
		_hide_indicator(animated)
		return
	var indicator := _ensure_spike_indicator()
	if not indicator:
		return
	indicator.tile_size = wall_thickness
	indicator.spike_length = wall_thickness
	var base: Vector2 = config.get("base", Vector2.ZERO) as Vector2
	var direction: Vector2 = _quantize_direction(config.get("direction", Vector2.DOWN) as Vector2)
	indicator.set_direction(direction)
	indicator.position = _indicator_origin_for_config(base, direction)
	if animated:
		indicator.set_visible_amount(0.0)
		indicator.animate_show()
	else:
		indicator.set_visible_amount(1.0)

func _hide_indicator(animated: bool) -> void:
	if not is_instance_valid(_spike_indicator):
		return
	if animated:
		_spike_indicator.animate_hide()
	else:
		_spike_indicator.set_visible_amount(0.0)

func _consume_indicator_for_config(target_config: Dictionary) -> void:
	if _indicator_config.is_empty():
		return
	if not _configs_equivalent(_indicator_config, target_config):
		return
	_hide_indicator(true)
	_indicator_config.clear()

func _quantize_direction(direction: Vector2) -> Vector2:
	var dir := direction.normalized()
	if abs(dir.x) > abs(dir.y):
		return Vector2.RIGHT if dir.x >= 0.0 else Vector2.LEFT
	return Vector2.DOWN if dir.y >= 0.0 else Vector2.UP

func _indicator_origin_for_config(base: Vector2, direction: Vector2) -> Vector2:
	var half_tile := wall_thickness * 0.5
	var origin := Vector2.ZERO
	if direction == Vector2.DOWN:
		origin = Vector2(base.x - half_tile, base.y)
	elif direction == Vector2.UP:
		origin = Vector2(base.x - half_tile, base.y - wall_thickness)
	elif direction == Vector2.RIGHT:
		origin = Vector2(base.x, base.y - half_tile)
	else:
		origin = Vector2(base.x - wall_thickness, base.y - half_tile)
	return _to_arena_local(origin)

func _configs_equivalent(a: Dictionary, b: Dictionary) -> bool:
	if a.is_empty() or b.is_empty():
		return false
	var base_a: Vector2 = a.get("base", Vector2.ZERO) as Vector2
	var base_b: Vector2 = b.get("base", Vector2.ZERO) as Vector2
	if base_a.distance_squared_to(base_b) > 0.25:
		return false
	var dir_a: Vector2 = (a.get("direction", Vector2.ZERO) as Vector2).normalized()
	var dir_b: Vector2 = (b.get("direction", Vector2.ZERO) as Vector2).normalized()
	if dir_a.dot(dir_b) < 0.995:
		return false
	return true

func _generate_obstacle_config(exclude_config: Dictionary = {}) -> Dictionary:
	var attempt := 0
	var candidate: Dictionary = {}
	while attempt < 16:
		candidate = _sample_obstacle_config()
		if exclude_config.is_empty() or not _configs_overlap(exclude_config, candidate):
			return candidate
		attempt += 1
	return candidate

func _sample_obstacle_config() -> Dictionary:
	var thickness_half := wall_thickness * 0.5
	var interior_min := arena_rect.position + Vector2(wall_thickness, wall_thickness)
	var interior_max := arena_rect.position + arena_rect.size - Vector2(wall_thickness, wall_thickness)
	var interior_width := interior_max.x - interior_min.x
	var interior_height := interior_max.y - interior_min.y
	var min_length := wall_thickness * 2.5
	var max_horizontal: float = max(interior_width * 0.55, min_length)
	var side := _rng.randi_range(0, 2)
	var base := Vector2.ZERO
	var direction := Vector2.DOWN
	var length: float = min_length
	match side:
		0:
			var x := _rng.randf_range(interior_min.x + thickness_half, interior_max.x - thickness_half)
			base = Vector2(x, interior_min.y)
			direction = Vector2.DOWN
			var max_vertical_available: float = max(interior_height, min_length)
			length = clamp(_rng.randf_range(min_length, max_vertical_available), min_length, max_vertical_available)
		1:
			var y := _rng.randf_range(interior_min.y + thickness_half, interior_max.y - thickness_half)
			base = Vector2(interior_min.x, y)
			direction = Vector2.RIGHT
			length = clamp(_rng.randf_range(min_length, max_horizontal), min_length, interior_width)
		2:
			var y_r := _rng.randf_range(interior_min.y + thickness_half, interior_max.y - thickness_half)
			base = Vector2(interior_max.x, y_r)
			direction = Vector2.LEFT
			length = clamp(_rng.randf_range(min_length, max_horizontal), min_length, interior_width)
	return {
		"base": base,
		"direction": direction,
		"length": length
	}

func _configs_overlap(previous_config: Dictionary, next_config: Dictionary) -> bool:
	if previous_config.is_empty() or next_config.is_empty():
		return false
	var prev_rect := _config_bounds(previous_config).grow(wall_thickness)
	var next_rect := _config_bounds(next_config).grow(wall_thickness)
	return prev_rect.intersects(next_rect)

func _config_bounds(config: Dictionary) -> Rect2:
	var base: Vector2 = config.get("base", Vector2.ZERO) as Vector2
	var direction: Vector2 = (config.get("direction", Vector2.DOWN) as Vector2).normalized()
	var length: float = float(config.get("length", wall_thickness * 2.5))
	var thickness_half: float = wall_thickness * 0.5
	if abs(direction.x) > abs(direction.y):
		var start_x: float = base.x
		var end_x: float = base.x + direction.x * length
		var min_x: float = min(start_x, end_x)
		var width: float = max(abs(end_x - start_x), 0.01)
		return Rect2(Vector2(min_x, base.y - thickness_half), Vector2(width, wall_thickness))
	else:
		var start_y: float = base.y
		var end_y: float = base.y + direction.y * length
		var min_y: float = min(start_y, end_y)
		var height: float = max(abs(end_y - start_y), 0.01)
		return Rect2(Vector2(base.x - thickness_half, min_y), Vector2(wall_thickness, height))

func _apply_obstacle_config(config: Dictionary) -> void:
	if not is_instance_valid(_obstacle):
		return
	_current_obstacle_config = config.duplicate(true)
	var runtime: Dictionary = _prepare_obstacle_runtime_config(_current_obstacle_config)
	var local_base: Vector2 = runtime.get("local_base", Vector2.ZERO) as Vector2
	var direction: Vector2 = runtime.get("direction", Vector2.DOWN) as Vector2
	var length: float = float(runtime.get("length", wall_thickness * 2.5))
	_obstacle.configure(local_base, direction, wall_thickness)
	_obstacle.set_length_immediate(length)
	_obstacle_hits = 0
	_obstacle_broken = false
	if _obstacle.has_method("set_damage_ratio"):
		_obstacle.set_damage_ratio(0.0)

func _cycle_obstacle(immediate: bool = false) -> void:
	var next_config := _next_obstacle_config.duplicate(true)
	if next_config.is_empty():
		next_config = _generate_obstacle_config(_current_obstacle_config)
	_consume_indicator_for_config(next_config)
	if immediate:
		_replace_obstacle_immediate(next_config)
		_prepare_next_indicator(_current_obstacle_config)
	else:
		_start_obstacle_transition(next_config)

func _force_obstacle_retract_on_bottom_bounce() -> void:
	_cycle_obstacle(false)

func _start_obstacle_transition(next_config: Dictionary) -> void:
	if next_config.is_empty():
		next_config = _generate_obstacle_config(_current_obstacle_config)
	_consume_indicator_for_config(next_config)
	_next_obstacle_config = next_config.duplicate(true)
	if _obstacle_animating or _incoming_obstacle:
		_pending_obstacle_config = next_config.duplicate(true)
		_obstacle_pending_cycle = true
		return
	_next_obstacle_config.clear()
	_obstacle_hits = 0
	_obstacle_pending_cycle = false
	if is_instance_valid(_obstacle) and _obstacle.has_method("set_damage_ratio"):
		_obstacle.set_damage_ratio(0.0)
	var old_obstacle := _obstacle if is_instance_valid(_obstacle) else null
	if is_instance_valid(old_obstacle):
		old_obstacle.remove_from_group("breakable_obstacle")
		_retiring_obstacles.append(old_obstacle)
		var retract_tween := old_obstacle.retract()
		if retract_tween:
			retract_tween.finished.connect(Callable(self, "_on_retiring_obstacle_retracted").bind(old_obstacle), Object.CONNECT_ONE_SHOT)
		else:
			_on_retiring_obstacle_retracted(old_obstacle)
	var runtime: Dictionary = _prepare_obstacle_runtime_config(next_config)
	var new_obstacle := _create_obstacle_instance()
	var local_base: Vector2 = runtime.get("local_base", Vector2.ZERO) as Vector2
	var direction: Vector2 = runtime.get("direction", Vector2.DOWN) as Vector2
	new_obstacle.configure(local_base, direction, wall_thickness)
	new_obstacle.set_length_immediate(0.0)
	_current_obstacle_config = next_config.duplicate(true)
	_prepare_next_indicator(_current_obstacle_config)
	_obstacle = new_obstacle
	_incoming_obstacle = new_obstacle
	_obstacle_animating = true
	_obstacle_broken = false
	var extend_length: float = float(runtime.get("length", wall_thickness * 2.5))
	var extend_tween := new_obstacle.extend_to(extend_length, 0.55)
	if extend_tween:
		extend_tween.finished.connect(Callable(self, "_on_incoming_obstacle_extended").bind(new_obstacle), Object.CONNECT_ONE_SHOT)
	else:
		_on_incoming_obstacle_extended(new_obstacle)

func _replace_obstacle_immediate(config: Dictionary) -> void:
	if is_instance_valid(_obstacle):
		_obstacle.queue_free()
	var config_copy: Dictionary = config.duplicate(true)
	var runtime: Dictionary = _prepare_obstacle_runtime_config(config_copy)
	var new_obstacle := _create_obstacle_instance()
	var local_base: Vector2 = runtime.get("local_base", Vector2.ZERO) as Vector2
	var direction: Vector2 = runtime.get("direction", Vector2.DOWN) as Vector2
	var target_length: float = float(runtime.get("length", wall_thickness * 2.5))
	new_obstacle.configure(local_base, direction, wall_thickness)
	new_obstacle.set_length_immediate(target_length)
	_obstacle = new_obstacle
	_current_obstacle_config = config_copy
	_obstacle_hits = 0
	_obstacle_broken = false
	_obstacle_animating = false
	_obstacle_pending_cycle = false
	_incoming_obstacle = null
	_pending_obstacle_config.clear()

func _create_obstacle_instance() -> ObstacleSegment:
	var obstacle := ObstacleSegment.new()
	obstacle.name = "Obstacle_%s" % str(Time.get_ticks_usec())
	obstacle.add_to_group("breakable_obstacle")
	_obstacles_container.add_child(obstacle)
	return obstacle

func _on_retiring_obstacle_retracted(obstacle: ObstacleSegment) -> void:
	_retiring_obstacles.erase(obstacle)
	if is_instance_valid(obstacle):
		obstacle.queue_free()

func _on_incoming_obstacle_extended(obstacle: ObstacleSegment) -> void:
	if obstacle == _incoming_obstacle:
		_incoming_obstacle = null
	_obstacle_animating = false
	if _obstacle_pending_cycle:
		_obstacle_pending_cycle = false
		var next_config := _pending_obstacle_config.duplicate(true)
		_pending_obstacle_config.clear()
		_start_obstacle_transition(next_config)

func _flash_combo_effect() -> void:
	var blur_peak := 0.0
	if is_instance_valid(_ball):
		var base_speed: float = max(_ball.initial_speed, 1.0)
		var current_speed: float = _ball.get_speed()
		var speed_ratio: float = clamp((current_speed / base_speed) - 1.0, 0.0, 1.2)
		var intensity_factor: float = clamp(pow(speed_ratio, 0.75), 0.0, 1.0)
		blur_peak = clamp(intensity_factor * combo_blur_max_intensity, 0.0, 1.0)
	if _combo_label:
		_combo_label.text = str(_bounce_count)
		if _label_tween and _label_tween.is_running():
			_label_tween.kill()
		_label_tween = create_tween()
		_label_tween.tween_property(_combo_label, "modulate", Color(1, 1, 1, 0.9), 0.05).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		_label_tween.tween_property(_combo_label, "modulate", _combo_base_color, 0.2).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		if _label_scale_tween and _label_scale_tween.is_running():
			_label_scale_tween.kill()
		_label_scale_tween = create_tween()
		_label_scale_tween.tween_property(_combo_label, "scale", Vector2(1.2, 1.2), 0.06).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		_label_scale_tween.tween_property(_combo_label, "scale", Vector2.ONE, 0.22).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	if _blur_material:
		if _blur_tween and _blur_tween.is_running():
			_blur_tween.kill()
		if blur_peak <= 0.001:
			_blur_material.set_shader_parameter("intensity", 0.0)
			_blur_tween = null
		else:
			_blur_tween = create_tween()
			_blur_tween.tween_property(_blur_material, "shader_parameter/intensity", blur_peak, 0.07).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
			_blur_tween.tween_property(_blur_material, "shader_parameter/intensity", 0.0, 0.24).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

func _trigger_bullet_time() -> void:
	if _bullet_time_tween:
		_clear_bullet_time_state()
	_bullet_time_tween = create_tween()
	_bullet_time_tween.set_ignore_time_scale(true)
	_set_bullet_time_state(0.0)
	_bullet_time_tween.tween_method(Callable(self, "_set_bullet_time_state"), 0.0, 1.0, BULLET_TIME_ENTER).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	if BULLET_TIME_HOLD > 0.0:
		_bullet_time_tween.tween_method(Callable(self, "_set_bullet_time_state"), 1.0, 1.0, BULLET_TIME_HOLD)
	_bullet_time_tween.tween_method(Callable(self, "_set_bullet_time_state"), 1.0, 0.0, BULLET_TIME_EXIT).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	_bullet_time_tween.tween_callback(Callable(self, "_clear_bullet_time_state"))

func _set_bullet_time_state(amount: float) -> void:
	var clamped: float = clamp(amount, 0.0, 1.0)
	_bullet_time_scale = lerp(1.0, BULLET_TIME_SCALE, clamped)
	_set_freeze_amount(clamped)
	_update_time_scale()

func _set_freeze_amount(amount: float) -> void:
	_freeze_amount = clamp(amount, 0.0, 1.0)
	if _blur_material:
		_blur_material.set_shader_parameter("freeze_amount", _freeze_amount)

func _set_fast_forward_intensity(amount: float) -> void:
	_fast_forward_blend = clamp(amount, 0.0, 2.0)
	_update_time_scale()

func _set_fast_forward_state(active: bool, target_multiplier: float = 1.0) -> void:
	var target_blend: float = clamp(target_multiplier - 1.0, 0.0, 2.0)
	if active == _fast_forward_active and is_equal_approx(target_blend, _fast_forward_blend):
		return
	if not active:
		_fast_forward_active = false
		if _fast_forward_tween and _fast_forward_tween.is_running():
			_fast_forward_tween.kill()
		_fast_forward_tween = null
		_set_fast_forward_intensity(target_blend)
		return
	_fast_forward_active = true
	if _fast_forward_tween and _fast_forward_tween.is_running():
		_fast_forward_tween.kill()
	_fast_forward_tween = create_tween()
	_fast_forward_tween.set_ignore_time_scale(true)
	var ease_type := Tween.EASE_OUT if target_blend >= _fast_forward_blend else Tween.EASE_IN
	_fast_forward_tween.tween_method(Callable(self, "_set_fast_forward_intensity"), _fast_forward_blend, target_blend, 0.12).set_trans(Tween.TRANS_QUART).set_ease(ease_type)

func _update_time_scale() -> void:
	var fast_multiplier: float = 1.0 + clamp(_fast_forward_blend, 0.0, 2.0)
	Engine.time_scale = _bullet_time_scale * fast_multiplier

func _compute_fast_forward_multiplier(hold_time: float) -> float:
	if hold_time < FAST_FORWARD_STAGE1_DELAY:
		return 1.0
	if hold_time >= FAST_FORWARD_STAGE2_END:
		return 2.5
	var stage_progress: float = clamp((hold_time - FAST_FORWARD_STAGE1_DELAY) / FAST_FORWARD_STAGE2_DURATION, 0.0, 1.0)
	return lerp(2.0, 2.5, stage_progress)

func _clear_bullet_time_state() -> void:
	_bullet_time_scale = 1.0
	_set_freeze_amount(0.0)
	if _bullet_time_tween and _bullet_time_tween.is_running():
		_bullet_time_tween.kill()
	_bullet_time_tween = null
	_update_time_scale()

func _exit_tree() -> void:
	if _fast_forward_tween and _fast_forward_tween.is_running():
		_fast_forward_tween.kill()
	_fast_forward_tween = null
	_fast_forward_active = false
	_fast_forward_hold_time = 0.0
	_fast_forward_blend = 0.0
	if _bottom_rearm_timer:
		_bottom_rearm_timer.stop()
	_bottom_rearm_blocked = false
	if _bullet_time_tween and _bullet_time_tween.is_running():
		_bullet_time_tween.kill()
	_bullet_time_tween = null
	_bullet_time_scale = 1.0
	_set_freeze_amount(0.0)
	if _blur_material:
		_blur_material.set_shader_parameter("intensity", 0.0)
	_set_fast_forward_intensity(0.0)

func _spawn_ball() -> void:
	_ball = BALL_SCENE.instantiate() as BallScript
	_ball.set_game_manager(self)
	_ball.set_arena(arena_rect)
	_ball.global_position = arena_rect.position + arena_rect.size * 0.5
	_ball.set_control_wall_normal(Vector2.UP)
	add_child(_ball)
	_ball.bottom_bounce.connect(_on_ball_bottom_bounce)
	_ball.surface_contact.connect(_on_ball_surface_contact)
	_ball.obstacle_hit.connect(_on_ball_obstacle_hit)
	_ball.escaped.connect(_on_ball_escaped)
	_ball.shallow_correction_applied.connect(_on_ball_shallow_correction_applied)

func _on_ball_bottom_bounce() -> void:
	if not _bottom_active:
		return
	var next_bounce := _bounce_count + 1
	var should_reset := next_bounce % POINTS_PER_STAGE == 0
	if should_reset and is_instance_valid(_ball):
		var wall_velocity := _ball.get_last_wall_velocity()
		_ball.restore_initial_speed(wall_velocity)
	elif is_instance_valid(_ball):
		var wall_velocity := _ball.get_last_wall_velocity()
		_ball.boost_speed(wall_velocity)
	_bounce_count = next_bounce
	if should_reset:
		_current_frequency = base_frequency
	_play_bounce_tone()
	_flash_combo_effect()
	_force_obstacle_retract_on_bottom_bounce()
	_allow_immediate_bottom_rearm()
	if _stage_manager:
		_stage_manager.on_score_changed(_bounce_count)

func _allow_immediate_bottom_rearm() -> void:
	if _bottom_release_timer:
		_bottom_release_timer.stop()
	if _bottom_rearm_timer:
		_bottom_rearm_timer.stop()
	_bottom_immediate_rearm_available = true
	_bottom_rearm_blocked = false
	match _bottom_state:
		BottomWallState.SOLID:
			_begin_bottom_wall_fade()
		BottomWallState.FADING:
			if not _bottom_transition_tween:
				var duration: float = max(bottom_fade_duration, 0.01)
				_bottom_transition_tween = create_tween()
				_bottom_transition_tween.tween_method(Callable(self, "_set_bottom_fade_alpha"), _bottom_fade_alpha, bottom_ghost_alpha, duration).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
				_bottom_transition_tween.finished.connect(_on_bottom_wall_fade_finished)
		_:
			_update_bottom_wall_state()

func _on_ball_surface_contact(collider: Object) -> void:
	var collider_node := collider as Node
	if collider_node and collider_node.is_in_group("bottom_wall"):
		return
	_play_collision_tone()

func _on_ball_obstacle_hit(collider: Object) -> void:
	if _obstacle_broken or not is_instance_valid(_obstacle):
		return
	if collider != _obstacle:
		return
	_obstacle_hits += 1
	var damage_ratio: float = clamp(float(_obstacle_hits) / 3.0, 0.0, 1.0)
	if _obstacle.has_method("set_damage_ratio"):
		_obstacle.set_damage_ratio(damage_ratio)
	if _obstacle_hits >= 3:
		_trigger_obstacle_shatter()

func _on_ball_shallow_correction_applied() -> void:
	_trigger_bullet_time()

func _on_ball_escaped() -> void:
	_reset_round()

func _trigger_obstacle_shatter() -> void:
	if _obstacle_broken or not is_instance_valid(_obstacle):
		return
	_obstacle_broken = true
	_obstacle_hits = 0
	_obstacle.stop_animation()
	var tween := _obstacle.shatter()
	if tween:
		tween.finished.connect(_on_obstacle_shatter_finished)
	else:
		_on_obstacle_shatter_finished()

func _on_obstacle_shatter_finished() -> void:
	if not is_instance_valid(_obstacle):
		return
	_obstacle.stop_animation()
	_obstacle.remove_from_group("breakable_obstacle")
	_obstacle_animating = false
	_obstacle_pending_cycle = false
	var retiring := _obstacle
	_obstacle = null
	_retiring_obstacles.append(retiring)
	_on_retiring_obstacle_retracted(retiring)

func _reset_round() -> void:
	_bounce_count = 0
	_current_frequency = base_frequency
	_clear_bullet_time_state()
	_set_fast_forward_state(false, 1.0)
	_fast_forward_hold_time = 0.0
	if is_instance_valid(_ball):
		launch_ball_from_center()
	_bottom_state = BottomWallState.GHOST
	_bottom_fade_alpha = bottom_ghost_alpha
	_kill_bottom_transition_tween()
	if _bottom_release_timer:
		_bottom_release_timer.stop()
	if _bottom_rearm_timer:
		_bottom_rearm_timer.stop()
	_bottom_rearm_blocked = false
	_bottom_active = false
	_bottom_immediate_rearm_available = false
	_update_bottom_wall_state()
	_prime_obstacle_queue(true)
	if _combo_label:
		_combo_label.text = "0"
		_combo_label.modulate = _combo_base_color
		_combo_label.scale = Vector2.ONE
	if _blur_material:
		_blur_material.set_shader_parameter("intensity", 0.0)
	if _stage_manager:
		_stage_manager.on_score_changed(_bounce_count)

func _play_bounce_tone() -> void:
	if not _audio_player or not _audio_playback:
		return
	var generator := _audio_player.stream as AudioStreamGenerator
	if not generator:
		return
	var sample_rate := generator.mix_rate
	var frame_count := int(sample_rate * tone_duration)
	if frame_count <= 0:
		return
	var phase := 0.0
	var increment := TAU * _current_frequency / sample_rate
	var frames_available := _audio_playback.get_frames_available()
	if frames_available <= 0:
		return
	var frames_to_write: int = min(frame_count, frames_available)
	for _i in frames_to_write:
		var sample := sin(phase) * 0.6
		phase += increment
		_audio_playback.push_frame(Vector2(sample, sample))
	if not _audio_player.playing:
		_audio_player.play()
	_current_frequency *= pow(2.0, 1.0 / 12.0)

func _play_collision_tone() -> void:
	if not _audio_player or not _audio_playback:
		return
	var generator := _audio_player.stream as AudioStreamGenerator
	if not generator:
		return
	var sample_rate := generator.mix_rate
	var frame_count := int(sample_rate * tone_duration)
	if frame_count <= 0:
		return
	var base_freq: float = clamp(_current_frequency, 180.0, 2000.0)
	var detune: float = pow(2.0, _rng.randf_range(-0.08, 0.08))
	var primary_frequency: float = clamp(base_freq * detune, 180.0, 2200.0)
	var overtone_ratio: float = 1.5 + _rng.randf_range(-0.04, 0.04)
	var phase_primary := 0.0
	var phase_overtone := 0.0
	var increment_primary: float = TAU * primary_frequency / float(sample_rate)
	var increment_overtone: float = TAU * (primary_frequency * overtone_ratio) / float(sample_rate)
	var frames_available := _audio_playback.get_frames_available()
	if frames_available <= 0:
		return
	var frames_to_write: int = min(frame_count, frames_available)
	var decay := 1.0
	var decay_step: float = 1.0 / float(max(frames_to_write, 1))
	for _i in frames_to_write:
		var sample_primary := sin(phase_primary)
		var sample_overtone := sin(phase_overtone)
		var sample := (sample_primary * 0.55 + sample_overtone * 0.35) * decay
		sample = clamp(sample, -1.0, 1.0)
		phase_primary += increment_primary
		phase_overtone += increment_overtone
		decay = max(decay - decay_step, 0.0)
		_audio_playback.push_frame(Vector2(sample, sample))
	if not _audio_player.playing:
		_audio_player.play()
