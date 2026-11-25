extends RefCounted
## Lossless Variant <-> JSON conversion and Godot encode_var helpers for the
## Open Protocol Full tier.
##
## Tagged JSON objects use {"_t": <tag>, "v": <value>} for Godot types that do
## not have a native JSON representation (Vector3, Transform3D, Color,
## Packed*Array, StringName, NodePath, non-string-keyed Dictionary, etc.).
## Objects, RIDs, Callables, and Signals encode as null (SceneMultiplayer
## disallows object decoding by default).

const SAFE_INT_MAX := 9007199254740991
## Deepest client JSON nesting decoded; anything deeper becomes null. Game RPCs
## nest a few levels at most, and each level costs two GDScript frames here.
const MAX_DEPTH := 32


static func to_json(val: Variant) -> Variant:
	match typeof(val):
		TYPE_NIL:
			return null
		TYPE_BOOL:
			return val
		TYPE_INT:
			var n: int = val
			if n >= -SAFE_INT_MAX and n <= SAFE_INT_MAX:
				return n
			return {"_t": "i64", "v": str(n)}
		TYPE_FLOAT:
			var f: float = val
			if is_nan(f):
				return {"_t": "f", "v": "NaN"}
			if is_inf(f):
				return {"_t": "f", "v": "Inf" if f > 0.0 else "-Inf"}
			return f
		TYPE_STRING:
			return val
		TYPE_VECTOR2:
			var v: Vector2 = val
			return {"_t": "v2", "v": [v.x, v.y]}
		TYPE_VECTOR2I:
			var v: Vector2i = val
			return {"_t": "v2i", "v": [v.x, v.y]}
		TYPE_RECT2:
			var r: Rect2 = val
			return {"_t": "rect2", "v": [r.position.x, r.position.y, r.size.x, r.size.y]}
		TYPE_RECT2I:
			var r: Rect2i = val
			return {"_t": "rect2i", "v": [r.position.x, r.position.y, r.size.x, r.size.y]}
		TYPE_VECTOR3:
			var v: Vector3 = val
			return {"_t": "v3", "v": [v.x, v.y, v.z]}
		TYPE_VECTOR3I:
			var v: Vector3i = val
			return {"_t": "v3i", "v": [v.x, v.y, v.z]}
		TYPE_TRANSFORM2D:
			var t: Transform2D = val
			return {"_t": "xform2d", "v": [[t.x.x, t.x.y], [t.y.x, t.y.y], [t.origin.x, t.origin.y]]}
		TYPE_VECTOR4:
			var v: Vector4 = val
			return {"_t": "v4", "v": [v.x, v.y, v.z, v.w]}
		TYPE_VECTOR4I:
			var v: Vector4i = val
			return {"_t": "v4i", "v": [v.x, v.y, v.z, v.w]}
		TYPE_PLANE:
			var p: Plane = val
			return {"_t": "plane", "v": [p.normal.x, p.normal.y, p.normal.z, p.d]}
		TYPE_QUATERNION:
			var q: Quaternion = val
			return {"_t": "quat", "v": [q.x, q.y, q.z, q.w]}
		TYPE_AABB:
			var a: AABB = val
			return {"_t": "aabb", "v": [[a.position.x, a.position.y, a.position.z], [a.size.x, a.size.y, a.size.z]]}
		TYPE_BASIS:
			var b: Basis = val
			return {"_t": "basis", "v": [
				[b.x.x, b.x.y, b.x.z],
				[b.y.x, b.y.y, b.y.z],
				[b.z.x, b.z.y, b.z.z],
			]}
		TYPE_TRANSFORM3D:
			var t: Transform3D = val
			return {"_t": "xform3d", "v": [
				[t.basis.x.x, t.basis.x.y, t.basis.x.z],
				[t.basis.y.x, t.basis.y.y, t.basis.y.z],
				[t.basis.z.x, t.basis.z.y, t.basis.z.z],
				[t.origin.x, t.origin.y, t.origin.z],
			]}
		TYPE_PROJECTION:
			var p: Projection = val
			return {"_t": "proj", "v": [
				[p.x.x, p.x.y, p.x.z, p.x.w],
				[p.y.x, p.y.y, p.y.z, p.y.w],
				[p.z.x, p.z.y, p.z.z, p.z.w],
				[p.w.x, p.w.y, p.w.z, p.w.w],
			]}
		TYPE_COLOR:
			var c: Color = val
			return {"_t": "color", "v": [c.r, c.g, c.b, c.a]}
		TYPE_STRING_NAME:
			return {"_t": "sn", "v": String(val)}
		TYPE_NODE_PATH:
			return {"_t": "np", "v": String(val)}
		TYPE_DICTIONARY:
			var d: Dictionary = val
			var plain := true
			for k: Variant in d.keys():
				if typeof(k) != TYPE_STRING or k == "_t":
					plain = false
					break
			if plain:
				var out := {}
				for k: String in d.keys():
					out[k] = to_json(d[k])
				return out
			var pairs := []
			for k: Variant in d.keys():
				pairs.append([to_json(k), to_json(d[k])])
			return {"_t": "dict", "v": pairs}
		TYPE_ARRAY:
			var out := []
			for item: Variant in val:
				out.append(to_json(item))
			return out
		TYPE_PACKED_BYTE_ARRAY:
			return {"_t": "bytes", "v": Marshalls.raw_to_base64(val)}
		TYPE_PACKED_INT32_ARRAY:
			var out := []
			for n: int in val:
				out.append(n)
			return {"_t": "pi32", "v": out}
		TYPE_PACKED_INT64_ARRAY:
			var out := []
			for n: int in val:
				out.append(to_json(n))
			return {"_t": "pi64", "v": out}
		TYPE_PACKED_FLOAT32_ARRAY:
			var out := []
			for f: float in val:
				out.append(to_json(f))
			return {"_t": "pf32", "v": out}
		TYPE_PACKED_FLOAT64_ARRAY:
			var out := []
			for f: float in val:
				out.append(to_json(f))
			return {"_t": "pf64", "v": out}
		TYPE_PACKED_STRING_ARRAY:
			var out := []
			for s: String in val:
				out.append(s)
			return {"_t": "pstr", "v": out}
		TYPE_PACKED_VECTOR2_ARRAY:
			var out := []
			for p: Vector2 in val:
				out.append([p.x, p.y])
			return {"_t": "pv2", "v": out}
		TYPE_PACKED_VECTOR3_ARRAY:
			var out := []
			for p: Vector3 in val:
				out.append([p.x, p.y, p.z])
			return {"_t": "pv3", "v": out}
		TYPE_PACKED_COLOR_ARRAY:
			var out := []
			for c: Color in val:
				out.append([c.r, c.g, c.b, c.a])
			return {"_t": "pcol", "v": out}
		TYPE_PACKED_VECTOR4_ARRAY:
			var out := []
			for p: Vector4 in val:
				out.append([p.x, p.y, p.z, p.w])
			return {"_t": "pv4", "v": out}
		_:
			# Object, RID, Callable, Signal cannot cross SceneMultiplayer safely.
			return null


static func from_json(val: Variant, type_hint: int = TYPE_NIL, depth := 0) -> Variant:
	if val == null or depth > MAX_DEPTH:
		return null
	if val is bool:
		return val
	if val is int or val is float:
		match type_hint:
			TYPE_INT:
				return int(val)
			TYPE_FLOAT:
				return float(val)
			TYPE_BOOL:
				return val != 0
			_:
				return val
	if val is String:
		match type_hint:
			TYPE_NODE_PATH:
				return NodePath(val)
			TYPE_STRING_NAME:
				return StringName(val)
			_:
				return val
	if val is Dictionary:
		var d: Dictionary = val
		if d.has("_t") and d["_t"] is String and d.has("v"):
			return _decode_tagged(d["_t"], d["v"], depth)
		var out := {}
		for k: Variant in d.keys():
			out[str(k)] = from_json(d[k], TYPE_NIL, depth + 1)
		return out
	if val is Array:
		return _decode_array(val, type_hint, depth)
	return val


static func _decode_tagged(tag: String, v: Variant, depth := 0) -> Variant:
	match tag:
		"i":
			return int(v) if (v is int or v is float or v is String) else 0
		"i64":
			return int(v) if (v is int or v is float or v is String) else 0
		"f":
			if v is String:
				match v:
					"NaN":
						return NAN
					"Inf":
						return INF
					"-Inf":
						return -INF
				return float(v)
			return float(v) if (v is int or v is float) else 0.0
		"v2":
			if v is Array and v.size() == 2:
				return Vector2(float(v[0]), float(v[1]))
			return Vector2.ZERO
		"v2i":
			if v is Array and v.size() == 2:
				return Vector2i(int(v[0]), int(v[1]))
			return Vector2i.ZERO
		"rect2":
			if v is Array and v.size() == 4:
				return Rect2(float(v[0]), float(v[1]), float(v[2]), float(v[3]))
			return Rect2()
		"rect2i":
			if v is Array and v.size() == 4:
				return Rect2i(int(v[0]), int(v[1]), int(v[2]), int(v[3]))
			return Rect2i()
		"v3":
			if v is Array and v.size() == 3:
				return Vector3(float(v[0]), float(v[1]), float(v[2]))
			return Vector3.ZERO
		"v3i":
			if v is Array and v.size() == 3:
				return Vector3i(int(v[0]), int(v[1]), int(v[2]))
			return Vector3i.ZERO
		"xform2d":
			if v is Array and v.size() == 3:
				return Transform2D(
					Vector2(float(v[0][0]), float(v[0][1])),
					Vector2(float(v[1][0]), float(v[1][1])),
					Vector2(float(v[2][0]), float(v[2][1]))
				)
			return Transform2D.IDENTITY
		"v4":
			if v is Array and v.size() == 4:
				return Vector4(float(v[0]), float(v[1]), float(v[2]), float(v[3]))
			return Vector4.ZERO
		"v4i":
			if v is Array and v.size() == 4:
				return Vector4i(int(v[0]), int(v[1]), int(v[2]), int(v[3]))
			return Vector4i.ZERO
		"plane":
			if v is Array and v.size() == 4:
				return Plane(Vector3(float(v[0]), float(v[1]), float(v[2])), float(v[3]))
			return Plane()
		"quat":
			if v is Array and v.size() == 4:
				return Quaternion(float(v[0]), float(v[1]), float(v[2]), float(v[3]))
			return Quaternion.IDENTITY
		"aabb":
			if v is Array and v.size() == 2:
				return AABB(
					Vector3(float(v[0][0]), float(v[0][1]), float(v[0][2])),
					Vector3(float(v[1][0]), float(v[1][1]), float(v[1][2]))
				)
			return AABB()
		"basis":
			if v is Array and v.size() == 3:
				return Basis(
					Vector3(float(v[0][0]), float(v[0][1]), float(v[0][2])),
					Vector3(float(v[1][0]), float(v[1][1]), float(v[1][2])),
					Vector3(float(v[2][0]), float(v[2][1]), float(v[2][2]))
				)
			return Basis.IDENTITY
		"xform3d":
			if v is Array and v.size() == 4:
				var b := Basis(
					Vector3(float(v[0][0]), float(v[0][1]), float(v[0][2])),
					Vector3(float(v[1][0]), float(v[1][1]), float(v[1][2])),
					Vector3(float(v[2][0]), float(v[2][1]), float(v[2][2]))
				)
				var o := Vector3(float(v[3][0]), float(v[3][1]), float(v[3][2]))
				return Transform3D(b, o)
			return Transform3D.IDENTITY
		"proj":
			if v is Array and v.size() == 4:
				return Projection(
					Vector4(float(v[0][0]), float(v[0][1]), float(v[0][2]), float(v[0][3])),
					Vector4(float(v[1][0]), float(v[1][1]), float(v[1][2]), float(v[1][3])),
					Vector4(float(v[2][0]), float(v[2][1]), float(v[2][2]), float(v[2][3])),
					Vector4(float(v[3][0]), float(v[3][1]), float(v[3][2]), float(v[3][3]))
				)
			return Projection.IDENTITY
		"color":
			if v is Array and v.size() >= 3:
				return Color(float(v[0]), float(v[1]), float(v[2]), float(v[3]) if v.size() >= 4 else 1.0)
			return Color.WHITE
		"sn":
			return StringName(str(v))
		"np":
			return NodePath(str(v))
		"dict":
			var out := {}
			if v is Array:
				for pair: Variant in v:
					if pair is Array and pair.size() == 2:
						var key: Variant = from_json(pair[0], TYPE_NIL, depth + 1)
						if key is float and is_finite(key) and floor(key) == key:
							key = int(key)
						out[key] = from_json(pair[1], TYPE_NIL, depth + 1)
			return out
		"bytes":
			return Marshalls.base64_to_raw(str(v))
		"pi32":
			return _to_packed_int32(v)
		"pi64":
			return _to_packed_int64(v)
		"pf32":
			return _to_packed_float32(v)
		"pf64":
			return _to_packed_float64(v)
		"pstr":
			return _to_packed_string(v)
		"pv2":
			return _to_packed_vector2(v)
		"pv3":
			return _to_packed_vector3(v)
		"pcol":
			return _to_packed_color(v)
		"pv4":
			return _to_packed_vector4(v)
		_:
			return null


static func _decode_array(arr: Array, type_hint: int, depth := 0) -> Variant:
	match type_hint:
		TYPE_PACKED_INT32_ARRAY:
			return _to_packed_int32(arr)
		TYPE_PACKED_INT64_ARRAY:
			return _to_packed_int64(arr)
		TYPE_PACKED_FLOAT32_ARRAY:
			return _to_packed_float32(arr)
		TYPE_PACKED_FLOAT64_ARRAY:
			return _to_packed_float64(arr)
		TYPE_PACKED_STRING_ARRAY:
			return _to_packed_string(arr)
		TYPE_PACKED_VECTOR2_ARRAY:
			return _to_packed_vector2(arr)
		TYPE_PACKED_VECTOR3_ARRAY:
			return _to_packed_vector3(arr)
		TYPE_PACKED_COLOR_ARRAY:
			return _to_packed_color(arr)
		TYPE_PACKED_VECTOR4_ARRAY:
			return _to_packed_vector4(arr)
		TYPE_PACKED_BYTE_ARRAY:
			var pb := PackedByteArray()
			pb.resize(arr.size())
			for i in arr.size():
				pb[i] = int(arr[i]) & 0xFF
			return pb
		_:
			var out := []
			for item: Variant in arr:
				out.append(from_json(item, TYPE_NIL, depth + 1))
			return out


static func _to_packed_int32(v: Variant) -> PackedInt32Array:
	var out := PackedInt32Array()
	if v is Array:
		out.resize(v.size())
		for i in v.size():
			out[i] = int(v[i])
	return out


static func _to_packed_int64(v: Variant) -> PackedInt64Array:
	var out := PackedInt64Array()
	if v is Array:
		out.resize(v.size())
		for i in v.size():
			out[i] = int(from_json(v[i], TYPE_INT))
	return out


static func _to_packed_float32(v: Variant) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if v is Array:
		out.resize(v.size())
		for i in v.size():
			out[i] = float(from_json(v[i], TYPE_FLOAT))
	return out


static func _to_packed_float64(v: Variant) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	if v is Array:
		out.resize(v.size())
		for i in v.size():
			out[i] = float(from_json(v[i], TYPE_FLOAT))
	return out


static func _to_packed_string(v: Variant) -> PackedStringArray:
	var out := PackedStringArray()
	if v is Array:
		out.resize(v.size())
		for i in v.size():
			out[i] = str(v[i])
	return out


static func _to_packed_vector2(v: Variant) -> PackedVector2Array:
	var out := PackedVector2Array()
	if v is Array:
		out.resize(v.size())
		for i in v.size():
			var p: Variant = v[i]
			if p is Array and p.size() == 2:
				out[i] = Vector2(float(p[0]), float(p[1]))
	return out


static func _to_packed_vector3(v: Variant) -> PackedVector3Array:
	var out := PackedVector3Array()
	if v is Array:
		out.resize(v.size())
		for i in v.size():
			var p: Variant = v[i]
			if p is Array and p.size() == 3:
				out[i] = Vector3(float(p[0]), float(p[1]), float(p[2]))
	return out


static func _to_packed_color(v: Variant) -> PackedColorArray:
	var out := PackedColorArray()
	if v is Array:
		out.resize(v.size())
		for i in v.size():
			var c: Variant = v[i]
			if c is Array and c.size() >= 3:
				out[i] = Color(float(c[0]), float(c[1]), float(c[2]), float(c[3]) if c.size() >= 4 else 1.0)
	return out


static func _to_packed_vector4(v: Variant) -> PackedVector4Array:
	var out := PackedVector4Array()
	if v is Array:
		out.resize(v.size())
		for i in v.size():
			var p: Variant = v[i]
			if p is Array and p.size() == 4:
				out[i] = Vector4(float(p[0]), float(p[1]), float(p[2]), float(p[3]))
	return out


## Coerce a Variant (e.g. from JSON or binary) to match a target GDScript arg type
## when safe and unambiguous (e.g. float->int, int->float, String->NodePath).
static func coerce_type(val: Variant, type_hint: int) -> Variant:
	if type_hint == TYPE_NIL or typeof(val) == type_hint:
		return val
	match type_hint:
		TYPE_INT:
			if val is float:
				return int(val)
		TYPE_FLOAT:
			if val is int:
				return float(val)
		TYPE_NODE_PATH:
			if val is String:
				return NodePath(val)
		TYPE_STRING_NAME:
			if val is String:
				return StringName(val)
	return val


## Encode an Array of Variants as back-to-back Godot encode_var (var_to_bytes,
## allow_objects = false) payloads for the Full-tier binary protocol.
static func encode_args_bin(args: Array) -> PackedByteArray:
	var out := PackedByteArray()
	for arg: Variant in args:
		var safe: Variant = null if typeof(arg) in [TYPE_OBJECT, TYPE_RID, TYPE_CALLABLE, TYPE_SIGNAL] else arg
		out.append_array(var_to_bytes(safe))
	return out


## Decode `argc` back-to-back Godot encode_var payloads starting at `offset`.
static func decode_args_bin(buf: PackedByteArray, offset: int, argc: int, type_hints: Array = []) -> Dictionary:
	var args := []
	var ofs := offset
	for i in argc:
		if ofs + 4 > buf.size():
			return {"ok": false, "error": "Truncated binary variant arg %d" % i}
		var vlen := buf.decode_var_size(ofs, false)
		if vlen <= 0 or ofs + vlen > buf.size():
			return {"ok": false, "error": "Invalid binary variant arg %d" % i}
		var val: Variant = buf.decode_var(ofs, false)
		var hint: int = type_hints[i] if i < type_hints.size() else TYPE_NIL
		args.append(coerce_type(val, hint))
		ofs += vlen
	return {"ok": true, "args": args, "offset": ofs}
