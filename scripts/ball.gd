extends CharacterBody2D

class_name Ball

signal bottom_bounce
signal escaped
signal obstacle_hit(collider)
signal shallow_correction_applied
signal surface_contact(collider)

@export var initial_speed: float = 440.0
@export var speed_multiplier: float = 1.08
@export var radius: float = 12.0

var _arena_rect: Rect2 = Rect2()
var _velocity: Vector2
var _game_manager: Node
var _rng := RandomNumberGenerator.new()
const BOTTOM_BOUNCE_COOLDOWN_FRAMES := 6
const MAX_COLLISION_ITERATIONS := 6
const COLLISION_SOUND_INTERVAL := 0.08
const COLLISION_SOUND_MIN_NORMAL_SPEED := 60.0
var _bottom_contact_cooldown_frames: int = 0
var _bottom_touching: bool = false
var _obstacle_contacts_prev: Dictionary = {}
var _obstacle_contacts_current: Dictionary = {}
var _contact_emit_this_frame: Dictionary = {}
const SHALLOW_ANGLE_THRESHOLD_DEG := 40.0
const SHALLOW_DURATION_THRESHOLD := 1.0
const SHALLOW_TARGET_ANGLE_DEG := 60.0
const SHALLOW_ARROW_FLASH_DURATION := 1.5
const SHALLOW_CORRECTION_COOLDOWN := 1.0
const SLIDE_NORMAL_THRESHOLD := 48.0
const SLIDE_WORLD_THRESHOLD := 22.0
var _control_wall_normal: Vector2 = Vector2.UP
var _control_wall_tangent: Vector2 = Vector2.RIGHT
var _shallow_angle_timer: float = 0.0
var _shallow_correction_active: bool = false
var _shallow_correction_cooldown: float = 0.0
var _arrow_flash_tween: Tween
var _scale_tween: Tween
var _last_tangent_sign: float = 1.0
var _last_normal_sign: float = 1.0
var _shallow_warning_active: bool = false
var _shallow_warning_seed: int = 0
var _shallow_warning_time: float = 0.0
var _shallow_correction_enabled: bool = true
var _last_wall_velocity: Vector2 = Vector2.ZERO
var _last_collision_sound_times: Dictionary = {}
var _last_collision_normal: Vector2 = Vector2.UP

func _ready() -> void:
    _rng.randomize()
    reset_ball(global_position)
    queue_redraw()
    set_physics_process(true)

func _draw() -> void:
    var base_color := Color(1.0, 1.0, 1.0, 1.0)
    draw_circle(Vector2.ZERO, radius, base_color)
    if _shallow_warning_active:
        var rng := RandomNumberGenerator.new()
        rng.seed = int(_shallow_warning_seed)
        var max_radius := radius * 1.6
        var line_color := Color(1.0, 1.0, 1.0, 0.78)
        for _i in range(18):
            var angle_a := rng.randf_range(0.0, TAU)
            var angle_b := angle_a + rng.randf_range(-0.9, 0.9)
            var r1 := max_radius * rng.randf_range(0.25, 1.0)
            var r2 := max_radius * rng.randf_range(0.25, 1.0)
            var p1 := Vector2(cos(angle_a), sin(angle_a)) * r1
            var p2 := Vector2(cos(angle_b), sin(angle_b)) * r2
            draw_line(p1, p2, line_color, 2.0, true)

func _physics_process(delta: float) -> void:
    if _bottom_contact_cooldown_frames > 0:
        _bottom_contact_cooldown_frames -= 1
    if _shallow_correction_cooldown > 0.0:
        _shallow_correction_cooldown = max(_shallow_correction_cooldown - delta, 0.0)
    _obstacle_contacts_current.clear()
    _contact_emit_this_frame.clear()
    var remaining_motion := _velocity * delta
    var bottom_collided_this_step: bool = false
    var iterations := 0
    while iterations < MAX_COLLISION_ITERATIONS and remaining_motion.length() > 0.0:
        var collision := move_and_collide(remaining_motion)
        if not collision:
            break
        bottom_collided_this_step = _handle_collision(collision) or bottom_collided_this_step
        var remainder_len := collision.get_remainder().length()
        if remainder_len <= 0.0 or _velocity.is_zero_approx():
            remaining_motion = Vector2.ZERO
        else:
            remaining_motion = _velocity.normalized() * remainder_len
        iterations += 1
    if not bottom_collided_this_step:
        _bottom_touching = false
    _obstacle_contacts_prev = _obstacle_contacts_current.duplicate()
    if _game_manager and _game_manager.has_method("clamp_ball_to_arena_bounds"):
        _game_manager.clamp_ball_to_arena_bounds(self)
    if _should_escape(delta):
        escaped.emit()
    _update_shallow_angle_state(delta)
    if _shallow_warning_active:
        _shallow_warning_time += delta
        _shallow_warning_seed = Time.get_ticks_usec()
        queue_redraw()

func set_arena(rect: Rect2) -> void:
    _arena_rect = rect

func set_game_manager(manager: Node) -> void:
    _game_manager = manager

func get_velocity_vector() -> Vector2:
    return _velocity

func reset_ball(origin: Vector2) -> void:
    global_position = origin
    _set_random_velocity(initial_speed)
    queue_redraw()
    _bottom_contact_cooldown_frames = 0
    _bottom_touching = false
    _obstacle_contacts_prev.clear()
    _obstacle_contacts_current.clear()
    _last_wall_velocity = Vector2.ZERO
    _last_collision_sound_times.clear()
    _last_collision_normal = Vector2.UP
    _shallow_angle_timer = 0.0
    _shallow_correction_active = false
    _shallow_correction_cooldown = 0.0
    scale = Vector2.ONE
    if _arrow_flash_tween and _arrow_flash_tween.is_running():
        _arrow_flash_tween.kill()
    if _scale_tween and _scale_tween.is_running():
        _scale_tween.kill()
    _arrow_flash_tween = null
    _scale_tween = null
    _stop_shallow_warning_effect()

func set_shallow_correction_enabled(enabled: bool) -> void:
    if _shallow_correction_enabled == enabled:
        return
    _shallow_correction_enabled = enabled
    if not _shallow_correction_enabled:
        if _shallow_correction_active:
            _cancel_shallow_correction()
        _shallow_angle_timer = 0.0
        _shallow_correction_cooldown = 0.0
        _stop_shallow_warning_effect()
    else:
        _shallow_angle_timer = 0.0
        _shallow_correction_cooldown = 0.0

func _should_escape(delta: float) -> bool:
    if _game_manager and _game_manager.has_method("should_ball_escape"):
        return bool(_game_manager.should_ball_escape(self, delta))
    if _arena_rect.size != Vector2.ZERO and global_position.y > _arena_rect.position.y + _arena_rect.size.y + radius * 2.0:
        return true
    return false

func restore_initial_speed(wall_velocity: Vector2 = Vector2.ZERO) -> void:
    _apply_relative_speed(initial_speed, wall_velocity)

func boost_speed(wall_velocity: Vector2 = Vector2.ZERO) -> void:
    var relative := _velocity - wall_velocity
    var target_speed := relative.length() * speed_multiplier
    _apply_relative_speed(target_speed, wall_velocity)

func get_speed() -> float:
    return _velocity.length()

func set_control_wall_normal(normal: Vector2) -> void:
    if normal.length_squared() <= 0.0001:
        return
    _control_wall_normal = normal.normalized()
    _control_wall_tangent = Vector2(-_control_wall_normal.y, _control_wall_normal.x)

func _set_random_velocity(speed: float) -> void:
    var direction := Vector2(_rng.randf_range(-0.8, 0.8), -1.0).normalized()
    if abs(direction.y) < 0.2:
        direction.y = -0.2
    _velocity = direction * speed

func _handle_collision(collision: KinematicCollision2D) -> bool:
    var collider := collision.get_collider()
    var collider_node := collider as Node
    var collided_bottom: bool = collider_node != null and collider_node.is_in_group("bottom_wall")
    var was_touching: bool = _bottom_touching
    if collided_bottom:
        if not was_touching and _bottom_contact_cooldown_frames <= 0:
            bottom_bounce.emit()
            _bottom_contact_cooldown_frames = BOTTOM_BOUNCE_COOLDOWN_FRAMES
        _bottom_touching = true
    elif collider_node != null and (collider_node.is_in_group("breakable_obstacle") or collider is ObstacleSegment):
        var obstacle_id := collider_node.get_instance_id()
        _obstacle_contacts_current[obstacle_id] = true
        if not _obstacle_contacts_prev.has(obstacle_id):
            obstacle_hit.emit(collider)
    var collision_point: Vector2 = collision.get_position()
    var wall_velocity := Vector2.ZERO
    if _game_manager and _game_manager.has_method("get_arena_surface_velocity"):
        wall_velocity = _game_manager.get_arena_surface_velocity(collision_point)
    var normal := collision.get_normal()
    _last_collision_normal = normal
    var relative_velocity_before := _velocity - wall_velocity
    var relative_normal_speed := relative_velocity_before.dot(normal)
    var world_normal_speed := _velocity.dot(normal)
    var normal_speed: float = abs(relative_normal_speed)
    var should_bounce := collided_bottom or (relative_normal_speed < -SLIDE_NORMAL_THRESHOLD and world_normal_speed < -SLIDE_WORLD_THRESHOLD)
    var bounced_relative: Vector2
    if should_bounce:
        bounced_relative = relative_velocity_before.bounce(normal)
    else:
        bounced_relative = relative_velocity_before.slide(normal)
    _velocity = bounced_relative + wall_velocity
    _last_wall_velocity = wall_velocity
    if not collided_bottom:
        var contact_target := collider_node if collider_node != null else collider
        if contact_target != null and contact_target is Object:
            var contact_id := contact_target.get_instance_id()
            if contact_id != 0 and not _contact_emit_this_frame.has(contact_id):
                var allow_sound := true
                var now: float = float(Time.get_ticks_msec()) / 1000.0
                var last_time: float = float(_last_collision_sound_times.get(contact_id, -1000.0))
                if now - last_time < COLLISION_SOUND_INTERVAL or normal_speed < COLLISION_SOUND_MIN_NORMAL_SPEED:
                    allow_sound = false
                _last_collision_sound_times[contact_id] = now
                if _last_collision_sound_times.size() > 64:
                    _prune_collision_sound_times(now)
                if allow_sound:
                    surface_contact.emit(contact_target)
                    _contact_emit_this_frame[contact_id] = true
    _separate_from_collision(collision)
    if collided_bottom:
        _clamp_inside_arena()
    return collided_bottom

func _separate_from_collision(collision: KinematicCollision2D) -> void:
    var depth := collision.get_depth()
    if depth > 0.0:
        global_position += collision.get_normal() * depth

func _clamp_inside_arena() -> void:
    if _game_manager and _game_manager.has_method("get_rotation_root") and _game_manager.has_method("get_arena_half_extents"):
        var rotation_root := _game_manager.get_rotation_root() as Node2D
        if rotation_root and is_instance_valid(rotation_root):
            var local := rotation_root.to_local(global_position)
            var half_extents: Vector2 = _game_manager.get_arena_half_extents()
            var thickness := 0.0
            if _game_manager.has_method("get_wall_thickness"):
                thickness = _game_manager.get_wall_thickness()
            var margin := radius + thickness * 0.5
            var clamped_x: float = clamp(local.x, -half_extents.x + margin, half_extents.x - margin)
            var clamped_y: float = clamp(local.y, -half_extents.y + margin, half_extents.y - margin)
            local = Vector2(clamped_x, clamped_y)
            global_position = rotation_root.to_global(local)
            return
    if _arena_rect.size == Vector2.ZERO:
        return
    var fallback_margin := radius + 2.0
    var min_x := _arena_rect.position.x + fallback_margin
    var max_x := _arena_rect.position.x + _arena_rect.size.x - fallback_margin
    var min_y := _arena_rect.position.y + fallback_margin
    var max_y := _arena_rect.position.y + _arena_rect.size.y - fallback_margin
    global_position.x = clamp(global_position.x, min_x, max_x)
    global_position.y = clamp(global_position.y, min_y, max_y)

func _create_speed_arrow() -> void:
    pass # obsolete (arrow removed)

func _update_shallow_angle_state(delta: float) -> void:
    if not _shallow_correction_enabled:
        return
    var speed := _velocity.length()
    if speed <= 0.01:
        _shallow_angle_timer = 0.0
        if _shallow_correction_active:
            _cancel_shallow_correction()
        return

    var normalized_vel := _velocity / speed
    var tangent_projection := normalized_vel.dot(_control_wall_tangent)
    var normal_projection := normalized_vel.dot(_control_wall_normal)
    if abs(tangent_projection) > 0.0005:
        _last_tangent_sign = sign(tangent_projection)
    if abs(normal_projection) > 0.0005:
        _last_normal_sign = sign(normal_projection)

    var angle_to_plane := acos(clamp(abs(tangent_projection), -1.0, 1.0))
    if _shallow_correction_active:
        if angle_to_plane > deg_to_rad(SHALLOW_ANGLE_THRESHOLD_DEG):
            _cancel_shallow_correction()
        return

    if angle_to_plane <= deg_to_rad(SHALLOW_ANGLE_THRESHOLD_DEG) and _shallow_correction_cooldown <= 0.0:
        _shallow_angle_timer += delta
        if _shallow_angle_timer >= SHALLOW_DURATION_THRESHOLD:
            _start_shallow_angle_correction()
    else:
        _shallow_angle_timer = 0.0

func _start_shallow_angle_correction() -> void:
    _shallow_angle_timer = 0.0
    _shallow_correction_active = true
    _shallow_correction_cooldown = SHALLOW_CORRECTION_COOLDOWN
    _start_shallow_warning_effect()
    if _arrow_flash_tween and _arrow_flash_tween.is_running():
        _arrow_flash_tween.kill()
    if _scale_tween and _scale_tween.is_running():
        _scale_tween.kill()
    _arrow_flash_tween = create_tween()
    _arrow_flash_tween.tween_interval(SHALLOW_ARROW_FLASH_DURATION)
    _arrow_flash_tween.tween_callback(Callable(self, "_apply_shallow_angle_correction"))

    _scale_tween = create_tween()
    var steps: int = max(1, int(round(SHALLOW_ARROW_FLASH_DURATION / 0.08)))
    var step_duration := SHALLOW_ARROW_FLASH_DURATION / float(steps)
    for _i in range(steps):
        _scale_tween.tween_callback(Callable(self, "_shallow_warning_jitter_step"))
        _scale_tween.tween_interval(step_duration)

func _start_shallow_warning_effect() -> void:
    _shallow_warning_active = true
    _shallow_warning_time = 0.0
    _shallow_warning_seed = Time.get_ticks_usec()
    scale = Vector2.ONE
    rotation = 0.0
    modulate = Color(1.0, 1.0, 1.0, 1.0)
    queue_redraw()

func _shallow_warning_jitter_step() -> void:
    if not _shallow_warning_active:
        return
    var scale_variation: float = 1.0 + _rng.randf_range(-0.2, 0.35)
    var squash_variation: float = 1.0 + _rng.randf_range(-0.25, 0.25)
    scale = Vector2(scale_variation, squash_variation)
    rotation = deg_to_rad(_rng.randf_range(-14.0, 14.0))
    modulate = Color(1.0, 1.0, 1.0, 1.0)
    queue_redraw()

func _stop_shallow_warning_effect() -> void:
    if not _shallow_warning_active and _shallow_warning_seed == 0:
        modulate = Color(1, 1, 1, 1)
        return
    _shallow_warning_active = false
    _shallow_warning_time = 0.0
    _shallow_warning_seed = 0
    scale = Vector2.ONE
    rotation = 0.0
    modulate = Color(1, 1, 1, 1)
    queue_redraw()

func _finalize_shallow_correction(applied: bool) -> void:
    if _arrow_flash_tween and _arrow_flash_tween.is_running():
        _arrow_flash_tween.kill()
    if _scale_tween and _scale_tween.is_running():
        _scale_tween.kill()
    _arrow_flash_tween = null
    _scale_tween = null
    _stop_shallow_warning_effect()
    _shallow_correction_active = false
    if not applied:
        _shallow_correction_cooldown = 0.0

func _cancel_shallow_correction() -> void:
    _finalize_shallow_correction(false)

func _apply_shallow_angle_correction() -> void:
    if not _shallow_correction_active:
        _stop_shallow_warning_effect()
        return
    var speed := _velocity.length()
    if speed <= 0.01:
        _finalize_shallow_correction(false)
        return
    # 若在等待期间已经离开浅角条件则取消
    var normalized_vel := _velocity.normalized()
    var tangent_projection := normalized_vel.dot(_control_wall_tangent)
    var angle_to_plane := acos(clamp(abs(tangent_projection), -1.0, 1.0))
    if angle_to_plane > deg_to_rad(SHALLOW_ANGLE_THRESHOLD_DEG):
        _finalize_shallow_correction(false)
        return
    var target_angle_rad := deg_to_rad(SHALLOW_TARGET_ANGLE_DEG)
    # 根据当前速度决定左右方向（沿切线正负符号）
    var tangent_sign: float = sign(_velocity.dot(_control_wall_tangent))
    if tangent_sign == 0.0:
        tangent_sign = (_last_tangent_sign if abs(_last_tangent_sign) >= 0.5 else 1.0)
    var normal_dir: Vector2 = _control_wall_normal
    if normal_dir.length_squared() <= 0.0001:
        normal_dir = Vector2.UP
    else:
        normal_dir = normal_dir.normalized()
    var tangent_dir: Vector2 = _control_wall_tangent * tangent_sign
    var new_direction: Vector2 = (tangent_dir * cos(target_angle_rad) + normal_dir * sin(target_angle_rad)).normalized()
    _velocity = new_direction * speed
    _last_tangent_sign = tangent_sign
    _last_normal_sign = sign(new_direction.dot(normal_dir))
    _finalize_shallow_correction(true)
    shallow_correction_applied.emit()

func get_last_wall_velocity() -> Vector2:
    return _last_wall_velocity

func _apply_relative_speed(target_speed: float, wall_velocity: Vector2) -> void:
    var clamped_speed: float = max(target_speed, 0.01)
    var relative := _velocity - wall_velocity
    if relative.length() <= 0.01:
        var direction := _last_collision_normal.normalized()
        if direction.length_squared() <= 0.0001:
            direction = Vector2(_rng.randf_range(-0.8, 0.8), -1.0).normalized()
            if abs(direction.y) < 0.2:
                direction.y = -0.2
        relative = direction.normalized() * clamped_speed
    else:
        relative = relative.normalized() * clamped_speed
    _velocity = relative + wall_velocity

func _prune_collision_sound_times(current_time: float) -> void:
    var keys := _last_collision_sound_times.keys()
    for key in keys:
        var timestamp: float = float(_last_collision_sound_times.get(key, -1000.0))
        if current_time - timestamp > 1.5:
            _last_collision_sound_times.erase(key)
