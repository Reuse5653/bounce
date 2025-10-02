extends StaticBody2D

class_name ObstacleSegment

@export var thickness: float = 20.0

var direction: Vector2 = Vector2.DOWN
var current_length: float:
    set(value):
        _current_length = max(value, 0.0)
        _update_geometry()
    get:
        return _current_length

var _current_length: float = 0.0
var _collision: CollisionShape2D
var _visual: Polygon2D
var _tween: Tween
var _base_color: Color = Color.WHITE

func _ready() -> void:
    _collision = CollisionShape2D.new()
    _collision.name = "CollisionShape2D"
    var shape := RectangleShape2D.new()
    shape.size = Vector2(1.0, thickness)
    _collision.shape = shape
    add_child(_collision)

    _visual = Polygon2D.new()
    _visual.name = "Visual"
    _visual.color = _base_color
    _visual.antialiased = true
    add_child(_visual)

    _update_geometry()

func configure(base_position: Vector2, new_direction: Vector2, new_thickness: float) -> void:
    stop_animation()
    position = base_position
    direction = new_direction.normalized()
    thickness = new_thickness
    rotation = direction.angle()
    _base_color = Color.WHITE
    if _visual:
        _visual.color = _base_color
    _ensure_shape_exists()
    _update_geometry()

func set_length_immediate(length: float) -> void:
    current_length = length

func extend_to(target_length: float, duration: float = 0.6, overshoot_ratio: float = 0.08) -> Tween:
    stop_animation()
    var queued_length: float = max(target_length, 0.0)
    var overshoot: float = queued_length * overshoot_ratio
    _tween = create_tween()
    _tween.tween_property(self, "current_length", queued_length + overshoot, duration * 0.7).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
    _tween.tween_property(self, "current_length", queued_length, duration * 0.3).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
    return _tween

func retract(duration: float = 0.45) -> Tween:
    stop_animation()
    var fallback: float = max(thickness * 0.4, current_length * 0.12)
    _tween = create_tween()
    _tween.tween_property(self, "current_length", fallback, duration * 0.55).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
    _tween.tween_property(self, "current_length", 0.0, duration * 0.35).set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)
    _tween.tween_property(self, "current_length", 0.0, 0.08).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
    return _tween

func stop_animation() -> void:
    if _tween and _tween.is_running():
        _tween.kill()
    _tween = null

func set_damage_ratio(ratio: float) -> void:
    var clamped: float = clamp(ratio, 0.0, 1.0)
    var tint: float = lerp(1.0, 0.55, clamped)
    if _visual:
        _visual.color = Color(1.0, tint, tint, _visual.color.a)

func shatter(duration: float = 0.22) -> Tween:
    stop_animation()
    var fade_color := Color(1.0, 0.2, 0.2, 0.0)
    _tween = create_tween()
    _tween.tween_property(self, "current_length", 0.0, duration).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
    if _visual:
        _tween.parallel().tween_property(_visual, "color", fade_color, duration).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_IN)
    _tween.tween_callback(Callable(self, "_on_shatter_finished"))
    return _tween

func _on_shatter_finished() -> void:
    if _visual:
        _visual.color = _base_color

func _ensure_shape_exists() -> void:
    if not _collision:
        return
    if not _collision.shape:
        var shape := RectangleShape2D.new()
        shape.size = Vector2(1.0, thickness)
        _collision.shape = shape

func _update_geometry() -> void:
    _ensure_shape_exists()
    var shape := _collision.shape as RectangleShape2D
    if not shape:
        return
    var effective_length: float = max(_current_length, 0.01)
    shape.size = Vector2(effective_length, thickness)
    _collision.position = Vector2(effective_length * 0.5, 0.0)
    _collision.disabled = effective_length < 4.0

    _visual.polygon = PackedVector2Array([
        Vector2(0.0, -thickness * 0.5),
        Vector2(effective_length, -thickness * 0.5),
        Vector2(effective_length, thickness * 0.5),
        Vector2(0.0, thickness * 0.5)
    ])
    _visual.position = Vector2.ZERO
    _visual.scale = Vector2.ONE
    _visual.offset = Vector2.ZERO