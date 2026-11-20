class_name ChunkMesher
## Pure, thread-safe chunk mesher.
##
## Input: a "padded" voxel array of size P*P*H (P = CS + 2) holding the chunk
## plus a one-block border copied from its four neighbours. Index layout:
## i = x + z * P + y * P * P with x, z in [0, P) (local -1..CS shifted by +1).
##
## Lighting is baked into vertex colours (face shade * vertex AO * sky
## exposure), so the material can be fully unshaded: no lights, no shadows.
## Water is emitted into a separate mesh (translucent material).

const CS := 16
const H := 96
const P := CS + 2
const PP := P * P
const WATER := 11 # Blocks.WATER (kept local: hot loop)

const FACE_NORMALS: Array[Vector3i] = [
	Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]

## Corners per face, ordered clockwise when seen from outside (Godot's front face).
const FACE_CORNERS := [
	[Vector3i(0, 1, 0), Vector3i(1, 1, 0), Vector3i(1, 1, 1), Vector3i(0, 1, 1)], # +Y
	[Vector3i(0, 0, 1), Vector3i(1, 0, 1), Vector3i(1, 0, 0), Vector3i(0, 0, 0)], # -Y
	[Vector3i(1, 0, 1), Vector3i(1, 1, 1), Vector3i(1, 1, 0), Vector3i(1, 0, 0)], # +X
	[Vector3i(0, 0, 0), Vector3i(0, 1, 0), Vector3i(0, 1, 1), Vector3i(0, 0, 1)], # -X
	[Vector3i(0, 1, 1), Vector3i(1, 1, 1), Vector3i(1, 0, 1), Vector3i(0, 0, 1)], # +Z
	[Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(1, 1, 0), Vector3i(0, 1, 0)], # -Z
]

## Directional shade per face: fakes a sun from above-ish for free.
const FACE_SHADE: Array[float] = [1.0, 0.62, 0.86, 0.86, 0.76, 0.76]
## Brightness for 0..3 un-occluded neighbours around a vertex.
const AO_LEVEL: Array[float] = [0.5, 0.68, 0.84, 1.0]
## Multiplier for faces whose air cell has no open sky above (caves, overhangs).
const CAVE_LIGHT := 0.68
const UV_INSET := 0.01
## Water surface sits a little below the block top.
const WATER_DROP := 0.125


static func index(x: int, y: int, z: int) -> int:
	return x + z * P + y * PP


static func _opaque(data: PackedByteArray, x: int, y: int, z: int) -> bool:
	if y < 0:
		return true
	if y >= H:
		return false
	var id := data[x + z * P + y * PP]
	return id != 0 and id != WATER


static func _id(data: PackedByteArray, x: int, y: int, z: int) -> int:
	if y < 0:
		return 1
	if y >= H:
		return 0
	return data[x + z * P + y * PP]


static func _new_arrays() -> Dictionary:
	return {"vertices": PackedVector3Array(), "uvs": PackedVector2Array(),
		"colors": PackedColorArray(), "indices": PackedInt32Array()}


## Returns {} when the chunk has no visible faces, otherwise
## {"opaque": arrays-or-{}, "water": arrays-or-{}} where arrays is a Dictionary
## with "vertices", "uvs", "colors", "indices".
## `top` (optional) is the highest non-air y in the 3x3 neighbourhood.
static func build(data: PackedByteArray, top: int = H - 1) -> Dictionary:
	# Highest opaque block per padded column: sky exposure. Water lets light through.
	var col_top := PackedInt32Array()
	col_top.resize(PP)
	var max_y := -1
	var start_y := mini(top, H - 1)
	for z in P:
		for x in P:
			var t := -1
			var any := -1
			for y in range(start_y, -1, -1):
				var id := data[x + z * P + y * PP]
				if id == 0:
					continue
				if any < 0:
					any = y
				if id != WATER:
					t = y
					break
			col_top[x + z * P] = t
			if x >= 1 and x <= CS and z >= 1 and z <= CS:
				max_y = maxi(max_y, any)
	if max_y < 0:
		return {}

	var solid := _new_arrays()
	var water := _new_arrays()
	# Neighbour index offsets in FACE_NORMALS order (+Y, -Y, +X, -X, +Z, -Z).
	var offs := PackedInt32Array([PP, -PP, 1, -1, P, -P])
	for y in range(0, max_y + 1):
		for z in range(1, CS + 1):
			var row := z * P + y * PP
			for x in range(1, CS + 1):
				var i := row + x
				var id := data[i]
				if id == 0:
					continue
				if id == WATER:
					_emit_water(data, x, y, z, water)
					continue
				# Fast path: buried blocks (all 6 neighbours opaque) are the common case.
				for f in 6:
					if f == 0 and y == H - 1:
						pass # nothing above the world: face visible
					elif f == 1 and y == 0:
						continue # world bottom is never visible
					else:
						var nid := data[i + offs[f]]
						if nid != 0 and nid != WATER:
							continue
					var n := FACE_NORMALS[f]
					_emit_face(data, col_top, id, f, x, y, z, x + n.x, y + n.y, z + n.z, solid)

	var out := {
		"opaque": solid if not solid.indices.is_empty() else {},
		"water": water if not water.indices.is_empty() else {},
	}
	if out.opaque.is_empty() and out.water.is_empty():
		return {}
	return out


static func _emit_face(data: PackedByteArray, col_top: PackedInt32Array, id: int, f: int,
		x: int, y: int, z: int, ax: int, ay: int, az: int, arr: Dictionary) -> void:
	var verts: PackedVector3Array = arr.vertices
	var uvs: PackedVector2Array = arr.uvs
	var colors: PackedColorArray = arr.colors
	var indices: PackedInt32Array = arr.indices
	var face_kind := 0 if f == 0 else (2 if f == 1 else 1)
	var rect := Blocks.tile_uv_rect(Blocks.tile_for(id, face_kind))
	var light: float = FACE_SHADE[f]
	if ay <= H - 1 and ay <= col_top[ax + az * P]:
		light *= CAVE_LIGHT

	# Tangent axes (the two axes that are not the face normal's axis).
	var normal_axis := 1 if f < 2 else (0 if f < 4 else 2)
	var t1 := 0 if normal_axis != 0 else 1
	var t2 := 2 if normal_axis != 2 else 1

	var base := verts.size()
	var ao: Array[int] = [0, 0, 0, 0]
	var corners: Array = FACE_CORNERS[f]
	for c in 4:
		var co: Vector3i = corners[c]
		var d1 := Vector3i.ZERO
		var d2 := Vector3i.ZERO
		d1[t1] = 1 if co[t1] == 1 else -1
		d2[t2] = 1 if co[t2] == 1 else -1
		var s1 := _opaque(data, ax + d1.x, ay + d1.y, az + d1.z)
		var s2 := _opaque(data, ax + d2.x, ay + d2.y, az + d2.z)
		var cc := _opaque(data, ax + d1.x + d2.x, ay + d1.y + d2.y, az + d1.z + d2.z)
		var level := 0 if (s1 and s2) else 3 - (int(s1) + int(s2) + int(cc))
		ao[c] = level

		verts.append(Vector3(x - 1 + co.x, y + co.y, z - 1 + co.z))
		uvs.append(_uv(rect, f, co))
		var b: float = light * AO_LEVEL[level]
		colors.append(Color(b, b, b, 1.0))

	# Flip the quad diagonal so AO interpolates smoothly (no streaky corners).
	if ao[0] + ao[2] >= ao[1] + ao[3]:
		indices.append_array([base, base + 1, base + 2, base, base + 2, base + 3])
	else:
		indices.append_array([base + 1, base + 2, base + 3, base + 1, base + 3, base])


static func _uv(rect: Rect2, f: int, co: Vector3i) -> Vector2:
	var local: Vector2
	if f < 2:
		local = Vector2(co.x, co.z)
	elif f < 4:
		local = Vector2(co.z, 1 - co.y)
	else:
		local = Vector2(co.x, 1 - co.y)
	local = local.clamp(Vector2(UV_INSET, UV_INSET), Vector2(1 - UV_INSET, 1 - UV_INSET))
	return rect.position + local * rect.size


## Water: faces only towards air (never towards solid blocks or other water).
## The surface block is lowered by WATER_DROP so shores read as a waterline.
static func _emit_water(data: PackedByteArray, x: int, y: int, z: int, arr: Dictionary) -> void:
	var surface := _id(data, x, y + 1, z) != WATER
	var rect := Blocks.tile_uv_rect(Blocks.Tile.WATER)
	for f in 6:
		var n := FACE_NORMALS[f]
		if _id(data, x + n.x, y + n.y, z + n.z) != 0:
			continue
		var verts: PackedVector3Array = arr.vertices
		var base := verts.size()
		var corners: Array = FACE_CORNERS[f]
		var b: float = FACE_SHADE[f]
		for c in 4:
			var co: Vector3i = corners[c]
			var vy := float(y + co.y)
			if surface and co.y == 1:
				vy -= WATER_DROP
			verts.append(Vector3(x - 1 + co.x, vy, z - 1 + co.z))
			arr.uvs.append(_uv(rect, f, co))
			arr.colors.append(Color(b, b, b, 1.0))
		arr.indices.append_array([base, base + 1, base + 2, base, base + 2, base + 3])
