extends RefCounted
class_name StageManager

var _context: StageContext
var _points_per_stage: int = 20
var _entries: Array[Dictionary] = []
var _stage_lookup: Dictionary = {}
var _default_sequence: Array[StringName] = []
var _custom_sequence: Array[StringName] = []
var _active_stage: StageBase = null
var _active_index: int = -1
var _active_stage_id: StringName = StringName()
var _override_stage_id: StringName = StringName()

func _init(context: StageContext, points_per_stage: int = 20) -> void:
	_context = context
	_points_per_stage = max(points_per_stage, 1)

func register_stage(range_start: int, stage: StageBase) -> void:
	if not stage:
		return
	_entries.append({
		"start": range_start,
		"stage": stage
	})
	_entries.sort_custom(Callable(self, "_compare_entry_start"))
	_rebuild_lookup()

func on_score_changed(new_score: int) -> void:
	var target_stage_id := _resolve_stage_id_for_score(new_score)
	if target_stage_id == StringName():
		_deactivate_stage()
	else:
		_switch_to_stage_id(target_stage_id)
	if _active_stage:
		_active_stage.on_score_changed(new_score)

func activate_for_score(score: int) -> void:
	var target_stage_id := _resolve_stage_id_for_score(score)
	if target_stage_id == StringName():
		_deactivate_stage()
	else:
		_switch_to_stage_id(target_stage_id)

func process(delta: float) -> void:
	if _active_stage:
		_active_stage.process(delta)

func should_ball_escape(ball: Ball, delta: float) -> Variant:
	if _active_stage:
		return _active_stage.should_ball_escape(ball, delta)
	return null

func update_horizontal_limit(limit: float) -> void:
	if not _context:
		return
	_context.max_horizontal_offset = max(limit, 0.0)
	if _active_stage and _active_stage.has_method("on_horizontal_limit_changed"):
		_active_stage.on_horizontal_limit_changed(_context.max_horizontal_offset)

func update_arena_center(center: Vector2) -> void:
	if not _context:
		return
	_context.motion_origin = center
	_context.arena_center_local = Vector2.ZERO

func has_stage(stage_id: StringName) -> bool:
	return _stage_lookup.has(stage_id)

func get_registered_stage_ids() -> Array[StringName]:
	return _default_sequence.duplicate()

func get_active_stage_id() -> StringName:
	return _active_stage_id

func get_sequence_index(stage_id: StringName) -> int:
	if not _stage_lookup.has(stage_id):
		return -1
	return int(_stage_lookup[stage_id])

func get_points_per_stage() -> int:
	return _points_per_stage

func set_custom_sequence(sequence: Array[StringName]) -> void:
	var sanitized: Array[StringName] = []
	for stage_id in sequence:
		if _stage_lookup.has(stage_id) and not sanitized.has(stage_id):
			sanitized.append(stage_id)
	if sanitized.is_empty():
		_custom_sequence.clear()
	else:
		_custom_sequence = sanitized

func clear_custom_sequence() -> void:
	_custom_sequence.clear()

func set_override_stage(stage_id: StringName, activate_now: bool = true) -> void:
	if not has_stage(stage_id):
		_override_stage_id = StringName()
		return
	_override_stage_id = stage_id
	if activate_now:
		_switch_to_stage_id(stage_id, true)

func clear_override_stage(refresh: bool = true) -> void:
	_override_stage_id = StringName()
	if refresh:
		activate_for_score(max(_active_index, 0) * _points_per_stage)

func force_switch_to_stage(stage_id: StringName, restart_if_same: bool = false) -> void:
	_switch_to_stage_id(stage_id, restart_if_same)

func _sequence_for_runtime() -> Array[StringName]:
	return _custom_sequence if not _custom_sequence.is_empty() else _default_sequence

func _resolve_stage_id_for_score(score: int) -> StringName:
	if _override_stage_id != StringName():
		return _override_stage_id
	var sequence := _sequence_for_runtime()
	if sequence.is_empty():
		return StringName()
	if _points_per_stage <= 0:
		return sequence.back()
	var index := int(floor(float(score) / float(_points_per_stage)))
	if index < 0:
		index = 0
	elif index >= sequence.size():
		index = sequence.size() - 1
	return sequence[index]

func _switch_to_stage_id(stage_id: StringName, restart_if_same: bool = false) -> void:
	if not has_stage(stage_id):
		return
	var target_index := int(_stage_lookup[stage_id])
	var should_restart := restart_if_same and stage_id == _active_stage_id
	_switch_to_index(target_index, should_restart)

func _switch_to_index(target_index: int, restart_if_same: bool = false) -> void:
	if target_index == _active_index and not restart_if_same:
		return
	_deactivate_stage()
	if target_index < 0:
		return
	if target_index >= _entries.size():
		return
	var entry := _entries[target_index]
	var stage: StageBase = entry.get("stage", null)
	if not stage:
		return
	_active_stage = stage
	_active_index = target_index
	_active_stage_id = entry.get("id", stage.get_id())
	_active_stage.enter(_context)

func _deactivate_stage() -> void:
	if _active_stage:
		_active_stage.exit()
	_active_stage = null
	_active_index = -1
	_active_stage_id = StringName()

func _rebuild_lookup() -> void:
	_stage_lookup.clear()
	_default_sequence.clear()
	for i in _entries.size():
		var entry := _entries[i]
		var stage: StageBase = entry.get("stage", null)
		if not stage:
			continue
		var stage_id := stage.get_id()
		entry["id"] = stage_id
		_entries[i] = entry
		_stage_lookup[stage_id] = i
		if not _default_sequence.has(stage_id):
			_default_sequence.append(stage_id)
	if not _custom_sequence.is_empty():
		set_custom_sequence(_custom_sequence.duplicate())

func _compare_entry_start(a: Dictionary, b: Dictionary) -> bool:
	return int(a.get("start", 0)) < int(b.get("start", 0))
