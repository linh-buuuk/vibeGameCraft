extends SceneTree
## Renders a top-down biome/height map of the generator to a PNG.
##   godot --headless --path . -s res://tools/world_map.gd -- --out=map.png [--seed=1337] [--size=768] [--scale=3]
## Each pixel = `scale` blocks. Hill-shaded by height, water darkened by depth,
## 500-block scale bar bottom-left, origin marked with a cross.

func _initialize() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else ""
	var seed_value := int(args.get("seed", "1337"))
	var size := int(args.get("size", "768"))
	var scale := int(args.get("scale", "3"))
	var out: String = args.get("out", "user://map.png")

	var g := TerrainGen.new(seed_value)
	var t0 := Time.get_ticks_msec()
	var half := size / 2
	var samples: Array = []
	samples.resize(size * size)
	var heights := PackedInt32Array()
	heights.resize(size * size)
	for py in size:
		for px in size:
			var s := g.sample((px - half) * scale, (py - half) * scale)
			samples[px + py * size] = s
			heights[px + py * size] = s[0]

	var img := Image.create(size, size, false, Image.FORMAT_RGB8)
	for py in size:
		for px in size:
			var i := px + py * size
			var h := heights[i]
			var hl := heights[maxi(px - 1, 0) + py * size]
			var hu := heights[px + maxi(py - 1, 0) * size]
			var slope := maxi(absi(h - hl), absi(h - hu)) / scale
			var b := g.biome_of(samples[i], slope)
			var c: Color = TerrainGen.BIOME_COLORS[b]
			if h < TerrainGen.SEA:
				c = c.darkened(clampf((TerrainGen.SEA - h) / 22.0, 0.0, 0.6))
			else:
				# Hill shading from the north-west + slight brightening with altitude.
				var shade := clampf(1.0 + (h - hl + h - hu) * 0.06, 0.6, 1.35)
				c = (c * shade).lightened(clampf((h - 40) / 120.0, 0.0, 0.3))
			img.set_pixel(px, py, c)

	# Scale bar (500 blocks) and origin cross.
	var bar := 500 / scale
	img.fill_rect(Rect2i(12, size - 22, bar, 6), Color.BLACK)
	img.fill_rect(Rect2i(12, size - 21, bar, 4), Color.WHITE)
	img.fill_rect(Rect2i(half - 6, half - 1, 13, 3), Color.RED)
	img.fill_rect(Rect2i(half - 1, half - 6, 3, 13), Color.RED)
	img.save_png(out)
	print("MAP %s %dx%d px, %d blocks/px, %.1fs" % [out, size, size, scale, (Time.get_ticks_msec() - t0) / 1000.0])
	quit()
