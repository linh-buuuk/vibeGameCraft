// Translucent water: one atlas fetch, baked face shade, per-vertex fog and a
// cheap per-vertex shimmer. No screen/depth texture reads (mobile friendly).
shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, skip_vertex_transform;

uniform sampler2D atlas : source_color, filter_nearest, repeat_disable;
uniform vec3 fog_color : source_color = vec3(0.70, 0.83, 0.95);
uniform float fog_start = 30.0;
uniform float fog_end = 62.0;
uniform float opacity = 0.72;

varying float fog;
varying float shimmer;

void vertex() {
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	shimmer = 0.94 + 0.06 * sin(TIME * 1.6 + world.x * 0.9 + world.z * 0.7);
	VERTEX = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	fog = smoothstep(fog_start, fog_end, length(VERTEX));
}

void fragment() {
	vec3 light = COLOR.rgb * COLOR.rgb * shimmer;
	vec3 c = texture(atlas, UV).rgb * light;
	ALBEDO = mix(c, fog_color, fog);
	ALPHA = mix(opacity, 1.0, fog);
}
