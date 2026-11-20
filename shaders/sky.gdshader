// Cheap gradient sky with a soft sun. No textures, no radiance maps.
shader_type sky;

uniform vec3 top_color : source_color = vec3(0.36, 0.60, 0.92);
uniform vec3 horizon_color : source_color = vec3(0.70, 0.83, 0.95);
uniform vec3 sun_color : source_color = vec3(1.0, 0.95, 0.80);
uniform vec3 sun_direction = vec3(0.35, 0.55, -0.75);

void sky() {
	float h = clamp(EYEDIR.y, 0.0, 1.0);
	vec3 col = mix(horizon_color, top_color, pow(h, 0.55));
	float s = max(dot(EYEDIR, normalize(sun_direction)), 0.0);
	col += sun_color * (smoothstep(0.9975, 0.9985, s) * 0.9 + pow(s, 48.0) * 0.25);
	COLOR = col;
}
