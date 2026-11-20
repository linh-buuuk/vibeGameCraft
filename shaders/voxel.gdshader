// Voxel terrain: unshaded. Lighting (face shade, AO, cave darkness) is baked
// into vertex colours by ChunkMesher, so per-pixel cost is one texture fetch
// plus a fog mix. Fog is computed per vertex.
shader_type spatial;
render_mode unshaded, cull_back, depth_draw_opaque, skip_vertex_transform;

uniform sampler2D atlas : source_color, filter_nearest, repeat_disable;
uniform vec3 fog_color : source_color = vec3(0.70, 0.83, 0.95);
uniform float fog_start = 30.0;
uniform float fog_end = 62.0;

varying float fog;

void vertex() {
	VERTEX = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	fog = smoothstep(fog_start, fog_end, length(VERTEX));
}

void fragment() {
	// Square the baked light: values are authored perceptually, output is linear.
	vec3 light = COLOR.rgb * COLOR.rgb;
	vec3 c = texture(atlas, UV).rgb * light;
	ALBEDO = mix(c, fog_color, fog);
}
