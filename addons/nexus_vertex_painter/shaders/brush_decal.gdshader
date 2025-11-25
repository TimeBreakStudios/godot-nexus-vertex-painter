shader_type spatial;
render_mode unshaded, depth_test_disabled, cull_front, blend_mix;

uniform sampler2D depth_texture : hint_depth_texture, filter_linear_mipmap;

// Wir übergeben die aktiven Kanäle als Vektor (1.0 = an, 0.0 = aus)
uniform vec4 channel_mask = vec4(1.0, 0.0, 0.0, 0.0); 

uniform float brush_radius = 1.0; 
uniform float falloff_range : hint_range(0.0, 1.0) = 0.5;
uniform vec3 brush_pos; 

// Einstellungen für die Liniendicke (in World Units)
uniform float width_outer = 0.01; // Etwas kräftiger
uniform float width_inner = 0.005; // Sehr fein (Filigran)

void fragment() {
	// 1. Tiefenwert & Weltposition (Standard Prozedur)
	float depth = texture(depth_texture, SCREEN_UV).x;
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth);
	vec4 view = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	view.xyz /= view.w;
	vec4 world = INV_VIEW_MATRIX * vec4(view.xyz, 1.0);
	
	// 2. Distanz zur Pinselmitte
	float dist = distance(world.xyz, brush_pos);
	
	// --- FARB LOGIK ---
	// Wir mischen die Farbe basierend auf den aktiven RGB Kanälen
	vec3 final_color = vec3(0.0);
	
	// Additive Farbmischung für RGB
	if (channel_mask.r > 0.5) final_color.r += 1.0;
	if (channel_mask.g > 0.5) final_color.g += 1.0;
	if (channel_mask.b > 0.5) final_color.b += 1.0;
	
	// Fallback: Wenn nichts oder nur Alpha gewählt ist, machen wir es Grau/Weiß
	if (length(final_color) < 0.1) {
		final_color = vec3(0.5); // Neutrales Grau
	}
	
	// Normalisieren, damit Gelb (R+G) nicht heller ist als Rot
	final_color = normalize(final_color + vec3(0.001)); // +0.001 gegen div/0
	
	// --- RING LOGIK ---
	
	float alpha = 0.0;
	
	// A. Äußerer Ring (Pinselgrenze)
	float dist_delta_outer = abs(dist - brush_radius);
	// Wir nutzen hier feste Pixel-Breiten für "Crispness" wäre schwer, 
	// daher sehr kleine World-Werte für smoothstep.
	float outer_ring = 1.0 - smoothstep(width_outer, width_outer + 0.005, dist_delta_outer);
	
	// B. Innerer Ring (Falloff Start)
	float inner_radius_val = brush_radius * (1.0 - falloff_range);
	float dist_delta_inner = abs(dist - inner_radius_val);
	float inner_ring = 1.0 - smoothstep(width_inner, width_inner + 0.005, dist_delta_inner);
	
	// --- VISUALISIERUNG ZUSAMMENBAUEN ---
	
	// Wenn Alpha aktiv ist, machen wir den INNEREN Ring Weiß, sonst nimmt er die RGB Farbe
	vec3 inner_color_visual = final_color;
	if (channel_mask.a > 0.5) {
		inner_color_visual = vec3(1.0); // Weiß für Alpha
	}
	
	// Pixel Farbe entscheiden: Bin ich auf dem Außen- oder Innenring?
	vec3 out_rgb = vec3(0.0);
	
	// Einfaches Blending: Äußerer Ring gewinnt am Rand
	if (outer_ring > 0.0) {
		out_rgb = final_color;
		alpha = outer_ring;
	} 
	// Innerer Ring wird "addiert" oder überschreibt
	if (inner_ring > 0.0) {
		out_rgb = inner_color_visual;
		// Wir nehmen das Maximum an Alpha, damit sich Ringe sauber kreuzen
		alpha = max(alpha, inner_ring);
	}
	
	// C. Cull Box (Clipping)
	vec3 local_pos = (inverse(MODEL_MATRIX) * world).xyz;
	if (abs(local_pos.x) > 0.5 || abs(local_pos.z) > 0.5 || abs(local_pos.y) > 0.5) {
		alpha = 0.0;
	}

	ALBEDO = out_rgb;
	ALPHA = alpha; // Volle Deckkraft wo Ring ist, 0 woanders
}