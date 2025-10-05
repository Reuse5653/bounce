extends "res://scripts/stages/stage_base.gd"
class_name StageStaticArena

func get_id() -> StringName:
	return &"stage_static_arena"

func enter(stage_context: StageContext) -> void:
	super.enter(stage_context)
	if context:
		context.reset_arena_transform()

func exit() -> void:
	if context:
		context.reset_arena_transform()
	super.exit()
