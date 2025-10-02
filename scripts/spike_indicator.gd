extends StaticBody2D

class_name SpikeIndicator

@export var direction: Vector2 = Vector2.DOWN # 只能为UP/DOWN/LEFT/RIGHT，指向场地内部
@export var tile_size: float = 20.0
@export var spike_length: float = 20.0
@export var anim_duration: float = 1

var _polygon: Polygon2D
var _collision: CollisionPolygon2D
var _tween: Tween
var _visible_amount: float = 0.0 # 0=缩回, 1=完全弹出

var visible_amount: float:
	set(value):
		_visible_amount = clamp(value, 0.0, 1.0)
		_update_shape()
	get:
		return _visible_amount

func _ready() -> void:
	_ensure_nodes()
	_update_shape()
	visible_amount = 0.0
	collision_layer = 1
	collision_mask = 1

func set_direction(dir: Vector2) -> void:
	if dir.length_squared() < 0.001:
		direction = Vector2.DOWN
	else:
		direction = dir.normalized()
	_update_shape()

func set_visible_amount(amount: float) -> void:
	visible_amount = amount

func animate_show() -> void:
	if _tween and _tween.is_running():
		_tween.kill()
	_tween = create_tween()
	var tween_step := _tween.tween_property(self, "visible_amount", 1.0, anim_duration)
	tween_step.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween_step.from(0.0)

func animate_hide() -> void:
	if _tween and _tween.is_running():
		_tween.kill()
	_tween = create_tween()
	var tween_step := _tween.tween_property(self, "visible_amount", 0.0, anim_duration * 0.5)
	tween_step.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	tween_step.from(visible_amount)

func _ensure_nodes() -> void:
	if not _polygon:
		_polygon = Polygon2D.new()
		_polygon.color = Color.WHITE
		add_child(_polygon)
	if not _collision:
		_collision = CollisionPolygon2D.new()
		_collision.disabled = true
		_collision.polygon = PackedVector2Array([
			Vector2.ZERO,
			Vector2(tile_size, 0.0),
			Vector2(tile_size * 0.5, max(1.0, spike_length * 0.25))
		])
		add_child(_collision)

func _update_shape() -> void:
	_ensure_nodes()
	# 以tile为底，spike_length为高，direction为朝向
	var base = tile_size
	var height = spike_length * _visible_amount
	var tri = []
	if direction == Vector2.UP:
		tri = [Vector2(0, base), Vector2(base, base), Vector2(base * 0.5, base - height)]
	elif direction == Vector2.DOWN:
		tri = [Vector2(0, 0), Vector2(base, 0), Vector2(base * 0.5, height)]
	elif direction == Vector2.LEFT:
		tri = [Vector2(base, 0), Vector2(base, base), Vector2(base - height, base * 0.5)]
	elif direction == Vector2.RIGHT:
		tri = [Vector2(0, 0), Vector2(0, base), Vector2(height, base * 0.5)]
	else:
		tri = [Vector2(0, base), Vector2(base, base), Vector2(base * 0.5, base - height)]
	_polygon.polygon = PackedVector2Array(tri)
	_collision.polygon = tri
	_collision.disabled = (_visible_amount < 0.05)
