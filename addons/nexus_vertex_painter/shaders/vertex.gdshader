shader_type spatial;

// Textur-Uniforms
uniform sampler2D base_texture : source_color;
uniform sampler2D r_texture : source_color;
uniform sampler2D g_texture : source_color;
uniform sampler2D b_texture : source_color;
uniform sampler2D a_texture : source_color;

uniform float uv_scale = 10.0;

// NEU: Debug / Visualisierung
// 0 = Normal (Texture Splatting), 1 = Custom0, 2 = Custom1, ...
uniform int active_layer_view : hint_range(0, 4) = 0;

// NEU: Varyings, um Daten vom Vertex- zum Fragment-Shader zu senden
varying vec4 v_custom0;
varying vec4 v_custom1;
varying vec4 v_custom2;
varying vec4 v_custom3;

void vertex() {
	// Wir müssen die Custom-Daten hier abgreifen und weiterreichen
	v_custom0 = CUSTOM0;
	v_custom1 = CUSTOM1;
	v_custom2 = CUSTOM2;
	v_custom3 = CUSTOM3;
}

void fragment() {
	vec2 uv = UV * uv_scale;
	
	// --- STANDARD LOGIK (Texture Splatting) ---
	vec3 base_col = texture(base_texture, uv).rgb;
	vec3 r_col = texture(r_texture, uv).rgb;
	vec3 g_col = texture(g_texture, uv).rgb;
	vec3 b_col = texture(b_texture, uv).rgb;
	vec3 a_col = texture(a_texture, uv).rgb;
	
	// Vertex Colors (COLOR ist im Fragment Shader verfügbar)
	float r_mask = COLOR.r;
	float g_mask = COLOR.g;
	float b_mask = COLOR.b;
	float a_mask = COLOR.a;
	
	vec3 mixed_color = base_col;
	mixed_color = mix(mixed_color, r_col, r_mask);
	mixed_color = mix(mixed_color, g_col, g_mask);
	mixed_color = mix(mixed_color, b_col, b_mask);
	mixed_color = mix(mixed_color, a_col, a_mask);
	
	// --- VISUALISIERUNGS-LOGIK ---
	vec3 final_albedo = mixed_color;
	
	// Wenn wir Custom Data bearbeiten, zeigen wir die Rohdaten an
	if (active_layer_view == 1) final_albedo = v_custom0.rgb;
	else if (active_layer_view == 2) final_albedo = v_custom1.rgb;
	else if (active_layer_view == 3) final_albedo = v_custom2.rgb;
	else if (active_layer_view == 4) final_albedo = v_custom3.rgb;
	
	ALBEDO = final_albedo;
	
	// Optional: Roughness reduzieren im Debug Modus, damit es glänzt (bessere Lesbarkeit)
	if (active_layer_view > 0) {
		ROUGHNESS = 0.4;
		METALLIC = 0.0;
	} else {
		ROUGHNESS = 0.8;
	}
}