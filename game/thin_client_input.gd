class_name ThinClientInput
extends RefCounted
## Inputs belong to a player, so simultaneous thin clients never share Input state.

const TIMEOUT_MS := 500
const QUEUE_LIMIT := 32
const BUTTONS := {
	&"fire": 1, &"aim": 2, &"jump": 4, &"crouch": 8, &"sprint": 16,
	&"reload": 32, &"interact": 64, &"use_item": 128, &"drop_item": 256,
	&"ping": 512, &"ready_up": 1024, &"throw_grenade": 2048, &"throw_dome": 4096,
}
const SLOTS := [&"", &"weapon_1", &"weapon_2", &"weapon_3", &"weapon_4", &"weapon_5"]

var id: int
var move := Vector2.ZERO
var look := Vector2.ZERO
var has_look := false
var ack := -1
var _last_seq := -1
var _last_ms := 0
var _queue: Array[Dictionary] = []
var _buttons := 0
var _pressed := 0
var _released := 0
var _slot := 0
var _wheel := 0
var _slot_edge := &""
var _wheel_edge := &""


func _init(peer_id: int) -> void:
	id = peer_id


func clear() -> void:
	_queue.clear()
	move = Vector2.ZERO
	has_look = false
	ack = -1
	_last_seq = -1
	_buttons = 0
	_pressed = 0
	_released = 0
	_slot = 0
	_wheel = 0


func enqueue(frame: Dictionary) -> bool:
	var seq := integer(frame.get("seq"), 0, 9007199254740991, -1)
	if seq <= _last_seq:
		return false
	var mv: Variant = frame.get("mv")
	if not mv is Array or mv.size() != 2 or not number(mv[0]) or not number(mv[1]):
		return false
	if not number(frame.get("yaw")) or not number(frame.get("pitch")):
		return false
	var aim := Vector2(wrapf(frame.yaw, -PI, PI), clampf(frame.pitch, -PI, PI))
	if not aim.is_finite():
		return false
	_last_seq = seq
	_last_ms = Time.get_ticks_msec()
	if _queue.size() == QUEUE_LIMIT:
		_queue.pop_front()
	_queue.append({"seq": seq, "move": Vector2(clampf(mv[0], -1.0, 1.0),
		clampf(mv[1], -1.0, 1.0)).limit_length(), "look": aim,
		"buttons": integer(frame.get("b"), 0, 8191, 0),
		"slot": integer(frame.get("slot"), 0, 5, 0),
		"wheel": integer(frame.get("wheel"), -1, 1, 0)})
	return true


func advance() -> void:
	_pressed = 0
	_released = 0
	_slot_edge = &""
	_wheel_edge = &""
	if Time.get_ticks_msec() - _last_ms > TIMEOUT_MS:
		move = Vector2.ZERO
		_released = _buttons
		_buttons = 0
		_queue.clear()
		return
	if _queue.is_empty():
		return
	var frame: Dictionary = _queue.pop_front()
	move = frame.move
	look = frame.look
	has_look = true
	ack = frame.seq
	_pressed = frame.buttons & ~_buttons
	_released = _buttons & ~frame.buttons
	_buttons = frame.buttons
	if frame.slot != _slot and frame.slot != 0:
		_slot_edge = SLOTS[frame.slot]
	if frame.wheel != _wheel and frame.wheel != 0:
		_wheel_edge = &"weapon_next" if frame.wheel > 0 else &"weapon_prev"
	_slot = frame.slot
	_wheel = frame.wheel


func pressed(action: StringName) -> bool:
	return bool(_buttons & int(BUTTONS.get(action, 0)))


func just_pressed(action: StringName) -> bool:
	return action == _slot_edge or action == _wheel_edge or bool(_pressed & int(BUTTONS.get(action, 0)))


func just_released(action: StringName) -> bool:
	return bool(_released & int(BUTTONS.get(action, 0)))


static func number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))


static func integer(value: Variant, low: int, high: int, fallback: int) -> int:
	if number(value) and value >= low and value <= high and floorf(value) == value:
		return int(value)
	return fallback
