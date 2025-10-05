extends RefCounted
class_name StageBase

var context: StageContext

func get_id() -> StringName:
	return &"stage_base"

func enter(stage_context: StageContext) -> void:
	context = stage_context

func exit() -> void:
	context = null

func process(_delta: float) -> void:
	pass

func on_score_changed(_new_score: int) -> void:
	pass

func should_ball_escape(_ball: Ball, _delta: float) -> Variant:
	return null
