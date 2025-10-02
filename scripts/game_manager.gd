extends Node2D

const BALL_SCENE := preload("res://scenes/ball.tscn")
const BallScript := preload("res://scripts/ball.gd")
const SpikeIndicatorScene: PackedScene = preload("res://scenes/spike_indicator.tscn")
const BULLET_TIME_SCALE := 0.35
const BULLET_TIME_ENTER := 0.12
const BULLET_TIME_HOLD := 0.18
const BULLET_TIME_EXIT := 0.45

@export var arena_size: float = 640.0
@export var wall_thickness: float = 20.0
@export var base_frequency: float = 220.0
@export var tone_duration: float = 0.14
@export var bottom_active_duration: float = 0.1
@export var bottom_fade_duration: float = 0.2
@export_range(0.0, 1.0, 0.01) var bottom_ghost_alpha: float = 0.35
@export_range(0.0, 1.0, 0.01) var bottom_bounce_alpha_threshold: float = 0.6

var arena_rect: Rect2
@onready var _background_rect: ColorRect = $Background
@onready var _walls_container: Node2D = $Walls
@onready var _obstacles_container: Node2D = $Obstacles
@onready var _combo_label: Label = $UI/ComboCounter
@onready var _blur_rect: ColorRect = $UI/BlurOverlay
var _blur_material: ShaderMaterial
var _bottom_wall: StaticBody2D
var _bottom_collision: CollisionShape2D
var _bottom_visual: Polygon2D
var _bottom_active := false
enum BottomWallState {GHOST, SOLID, FADING}
var _bottom_state: BottomWallState = BottomWallState.GHOST
var _bottom_transition_tween: Tween
var _bottom_release_timer: Timer
var _bottom_fade_alpha: float = 1.0
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
var _time_scale_before_bullet: float = 1.0

func _ready() -> void:
	_rng.randomize()
	_current_frequency = base_frequency
	bottom_bounce_alpha_threshold = clamp(bottom_bounce_alpha_threshold, bottom_ghost_alpha, 1.0)
	_recalculate_arena_rect()
	_setup_background()
	_setup_ui()
	_setup_audio()
	if not _bottom_release_timer:
		_bottom_release_timer = Timer.new()
		_bottom_release_timer.one_shot = true
		_bottom_release_timer.name = "BottomWallReleaseTimer"
		add_child(_bottom_release_timer)
		_bottom_release_timer.timeout.connect(_on_bottom_wall_release_timeout)
	_build_walls()
	_initialize_obstacle()
	_spawn_ball()
	set_process(true)

func _process(_delta: float) -> void:
	if Input.is_action_just_pressed("ui_accept"):
		_request_bottom_wall_activation()

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
		_combo_label.pivot_offset = _combo_label.size * 0.5
		var resized_callable := Callable(self, "_on_combo_label_resized")
		if not _combo_label.is_connected("resized", resized_callable):
			_combo_label.resized.connect(resized_callable)
		call_deferred("_update_combo_label_pivot")
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

func _recalculate_arena_rect() -> void:
	var viewport_rect := get_viewport_rect()
	var size := Vector2(arena_size, arena_size)
	var center := viewport_rect.size * 0.5
	var top_left := center - size * 0.5
	arena_rect = Rect2(top_left, size)

func _build_walls() -> void:
	if not _walls_container:
		_walls_container = Node2D.new()
		_walls_container.name = "Walls"
		add_child(_walls_container)
	for child in _walls_container.get_children():
		child.queue_free()
	var left_wall := _create_wall_rect("WallLeft", Rect2(arena_rect.position, Vector2(wall_thickness, arena_rect.size.y)))
	var right_wall := _create_wall_rect("WallRight", Rect2(Vector2(arena_rect.position.x + arena_rect.size.x - wall_thickness, arena_rect.position.y), Vector2(wall_thickness, arena_rect.size.y)))
	var top_wall := _create_wall_rect("WallTop", Rect2(arena_rect.position, Vector2(arena_rect.size.x, wall_thickness)))
	_walls_container.add_child(left_wall)
	_walls_container.add_child(right_wall)
	_walls_container.add_child(top_wall)
	_build_bottom_wall()

func _create_wall_rect(wall_name: String, rect: Rect2) -> StaticBody2D:
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
	body.position = rect.position
	return body

func _build_bottom_wall() -> void:
	var rect := Rect2(
		Vector2(arena_rect.position.x, arena_rect.position.y + arena_rect.size.y - wall_thickness),
		Vector2(arena_rect.size.x, wall_thickness)
	)
	_bottom_wall = _create_wall_rect("WallBottom", rect)
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
	if _bottom_state != BottomWallState.GHOST:
		return
	_activate_bottom_wall()

func _activate_bottom_wall() -> void:
	_kill_bottom_transition_tween()
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

func _initialize_obstacle() -> void:
	if not _obstacles_container:
		_obstacles_container = Node2D.new()
		_obstacles_container.name = "Obstacles"
		add_child(_obstacles_container)
	for child in _obstacles_container.get_children():
		child.queue_free()
	_retiring_obstacles.clear()
	_obstacle = null
	_incoming_obstacle = null
	_pending_obstacle_config.clear()
	var initial_config := _generate_obstacle_config()
	_replace_obstacle_immediate(initial_config)
	_prepare_next_indicator(initial_config)

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
	if direction == Vector2.DOWN:
		return Vector2(base.x - half_tile, base.y)
	if direction == Vector2.UP:
		return Vector2(base.x - half_tile, base.y - wall_thickness)
	if direction == Vector2.RIGHT:
		return Vector2(base.x, base.y - half_tile)
	return Vector2(base.x - wall_thickness, base.y - half_tile)

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
	var base: Vector2 = _current_obstacle_config.get("base", Vector2.ZERO) as Vector2
	var direction: Vector2 = _current_obstacle_config.get("direction", Vector2.DOWN) as Vector2
	_obstacle.configure(base, direction, wall_thickness)
	_obstacle.set_length_immediate(_obstacle.current_length)
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
	var new_obstacle := _create_obstacle_instance()
	new_obstacle.configure(next_config.get("base", Vector2.ZERO), next_config.get("direction", Vector2.DOWN), wall_thickness)
	new_obstacle.set_length_immediate(0.0)
	_current_obstacle_config = next_config.duplicate(true)
	_prepare_next_indicator(_current_obstacle_config)
	_obstacle = new_obstacle
	_incoming_obstacle = new_obstacle
	_obstacle_animating = true
	_obstacle_broken = false
	var extend_length: float = float(next_config.get("length", wall_thickness * 2.5))
	var extend_tween := new_obstacle.extend_to(extend_length, 0.55)
	if extend_tween:
		extend_tween.finished.connect(Callable(self, "_on_incoming_obstacle_extended").bind(new_obstacle), Object.CONNECT_ONE_SHOT)
	else:
		_on_incoming_obstacle_extended(new_obstacle)

func _replace_obstacle_immediate(config: Dictionary) -> void:
	if is_instance_valid(_obstacle):
		_obstacle.queue_free()
	var new_obstacle := _create_obstacle_instance()
	new_obstacle.configure(config.get("base", Vector2.ZERO), config.get("direction", Vector2.DOWN), wall_thickness)
	var target_length: float = float(config.get("length", wall_thickness * 2.5))
	new_obstacle.set_length_immediate(target_length)
	_obstacle = new_obstacle
	_current_obstacle_config = config.duplicate(true)
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
		_blur_tween = create_tween()
		_blur_tween.tween_property(_blur_material, "shader_parameter/intensity", 0.85, 0.07).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		_blur_tween.tween_property(_blur_material, "shader_parameter/intensity", 0.0, 0.24).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

func _trigger_bullet_time() -> void:
	if _bullet_time_tween:
		_clear_bullet_time_state()
	_bullet_time_tween = create_tween()
	_bullet_time_tween.set_ignore_time_scale(true)
	_time_scale_before_bullet = Engine.time_scale
	_set_bullet_time_state(0.0)
	_bullet_time_tween.tween_method(Callable(self, "_set_bullet_time_state"), 0.0, 1.0, BULLET_TIME_ENTER).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	if BULLET_TIME_HOLD > 0.0:
		_bullet_time_tween.tween_method(Callable(self, "_set_bullet_time_state"), 1.0, 1.0, BULLET_TIME_HOLD)
	_bullet_time_tween.tween_method(Callable(self, "_set_bullet_time_state"), 1.0, 0.0, BULLET_TIME_EXIT).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	_bullet_time_tween.tween_callback(Callable(self, "_clear_bullet_time_state"))

func _set_bullet_time_state(amount: float) -> void:
	var clamped: float = clamp(amount, 0.0, 1.0)
	var target_scale: float = lerp(1.0, BULLET_TIME_SCALE, clamped)
	Engine.time_scale = target_scale
	_set_freeze_amount(clamped)

func _set_freeze_amount(amount: float) -> void:
	_freeze_amount = clamp(amount, 0.0, 1.0)
	if _blur_material:
		_blur_material.set_shader_parameter("freeze_amount", _freeze_amount)

func _clear_bullet_time_state() -> void:
	Engine.time_scale = _time_scale_before_bullet
	_time_scale_before_bullet = 1.0
	_set_freeze_amount(0.0)
	if _bullet_time_tween and _bullet_time_tween.is_running():
		_bullet_time_tween.kill()
	_bullet_time_tween = null

func _spawn_ball() -> void:
	_ball = BALL_SCENE.instantiate() as BallScript
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
	var should_reset := next_bounce % 20 == 0
	if should_reset and is_instance_valid(_ball):
		_ball.restore_initial_speed()
	elif is_instance_valid(_ball):
		_ball.boost_speed()
	_bounce_count = next_bounce
	if should_reset:
		_current_frequency = base_frequency
	_play_bounce_tone()
	_flash_combo_effect()
	_force_obstacle_retract_on_bottom_bounce()
	print("底部连击：%d" % _bounce_count)

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
	var retract_tween := retiring.retract()
	if retract_tween:
		retract_tween.finished.connect(Callable(self, "_on_retiring_obstacle_retracted").bind(retiring), Object.CONNECT_ONE_SHOT)
	else:
		_on_retiring_obstacle_retracted(retiring)

func _reset_round() -> void:
	_bounce_count = 0
	_current_frequency = base_frequency
	_clear_bullet_time_state()
	if is_instance_valid(_ball):
		_ball.reset_ball(arena_rect.position + arena_rect.size * 0.5)
	_bottom_state = BottomWallState.GHOST
	_bottom_fade_alpha = bottom_ghost_alpha
	_kill_bottom_transition_tween()
	if _bottom_release_timer:
		_bottom_release_timer.stop()
	_bottom_active = false
	_update_bottom_wall_state()
	_obstacle_animating = false
	_obstacle_pending_cycle = false
	_obstacle_broken = false
	_obstacle_hits = 0
	for retiring_obstacle in _retiring_obstacles:
		if is_instance_valid(retiring_obstacle):
			retiring_obstacle.queue_free()
	_retiring_obstacles.clear()
	_pending_obstacle_config.clear()
	_cycle_obstacle(true)
	if _combo_label:
		_combo_label.text = "0"
		_combo_label.modulate = _combo_base_color
		_combo_label.scale = Vector2.ONE
	if _blur_material:
		_blur_material.set_shader_parameter("intensity", 0.0)

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
