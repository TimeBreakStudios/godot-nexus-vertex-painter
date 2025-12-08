shader_type spatial;
render_mode unshaded, depth_draw_never, cull_back, blend_mix;

uniform sampler2D depth_texture : hint_depth_texture, filter_linear_mipmap;

uniform vec4 channel_mask = vec4(1.0, 0.0, 0.0, 0.0); 

uniform float brush_radius = 1.0; 
uniform float falloff_range : hint_range(0.0, 1.0) = 0.5;
uniform float brush_strength : hint_range(0.0, 1.0) = 1.0;
uniform vec3 brush_pos; 

// Line settings
uniform float width_outer = 0.008; 
uniform float width_inner = 0.002; 
uniform float softness = 0.002;
uniform float thickness_scale = 0.015;
uniform float min_thickness = 0.002;

varying vec3 world_pos;

void vertex() {
	// Physical Overlay
	VERTEX += NORMAL * 0.005;
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float dist = distance(world_pos, brush_pos);
	
	// --- DYNAMIC WIDTHS ---
	float w_outer = max(min_thickness, brush_radius * thickness_scale);
	float w_inner = max(min_thickness * 0.5, w_outer * 0.25);
	float dyn_softness = w_outer * 0.5;
	
	// --- COLOR LOGIC ---
	vec3 final_color = vec3(0.0);
	if (channel_mask.r > 0.5) final_color.r += 1.0;
	if (channel_mask.g > 0.5) final_color.g += 1.0;
	if (channel_mask.b > 0.5) final_color.b += 1.0;
	
	if (length(final_color) < 0.1) final_color = vec3(0.5); 
	final_color = normalize(final_color + vec3(0.001));
	
	// --- RING LOGIC ---
	float alpha = 0.0;
	
	// 1. Main Brush Ring
	float dist_delta_outer = abs(dist - brush_radius);
	float outer_ring = 1.0 - smoothstep(w_outer, w_outer + dyn_softness, dist_delta_outer);
	
	// 2. Falloff Ring
	float inner_radius_val = brush_radius * (1.0 - falloff_range);
	float dist_delta_inner = abs(dist - inner_radius_val);
	float inner_ring = 1.0 - smoothstep(w_inner, w_inner + dyn_softness, dist_delta_inner);
	
	// 3. STRENGTH ARC METER (NEW)
	// Place it slightly outside the main ring (with some padding)
	float meter_radius = brush_radius + w_outer + (brush_radius * 0.05) + 0.02;
	float dist_delta_meter = abs(dist - meter_radius);
	
	// Base track (faint)
	float meter_track_alpha = 1.0 - smoothstep(w_inner, w_inner + dyn_softness, dist_delta_meter);
	
	// Calculate Angle for the Fill
	vec3 dir = world_pos - brush_pos;
	// atan(x, z) gives an angle around the Y axis (Terrain/Floor projection)
	float angle = atan(dir.x, dir.z); 
	// Normalize angle from -PI..PI to 0..1
	float meter_percent = (angle / 3.14159) * 0.5 + 0.5;
	
	// Fill logic
	float meter_fill_alpha = 0.0;
	if (meter_percent < brush_strength) {
		meter_fill_alpha = meter_track_alpha;
	}
	
	// --- ASSEMBLY ---
	
	vec3 out_rgb = vec3(0.0);
	float combined_alpha = 0.0;
	
	// Layer 1: Main Ring
	if (outer_ring > 0.0) {
		out_rgb = final_color;
		combined_alpha = outer_ring;
	}
	
	// Layer 2: Falloff Ring (Inner) - White if Alpha Mode
	vec3 inner_col = final_color;
	if (channel_mask.a > 0.5) inner_col = vec3(1.0);
	
	if (inner_ring > 0.0) {
		out_rgb = inner_col;
		combined_alpha = max(combined_alpha, inner_ring);
	}
	
	// Layer 3: Strength Meter (Outer)
	if (meter_track_alpha > 0.0) {
		// Draw Track (Faint)
		float track_vis = meter_track_alpha * 0.3; // 30% opacity for track
		// Draw Fill (Solid)
		float fill_vis = meter_fill_alpha; 
		
		float meter_final = max(track_vis, fill_vis);
		
		// If we are over existing rings, blend? 
		// Actually just taking the max is fine for a UI overlay feel.
		if (meter_final > combined_alpha) {
			combined_alpha = meter_final;
			out_rgb = final_color; // Use channel color for the meter too
		}
	}

	// Clipping
	// Increase cull radius to include the new meter ring
	if (dist > meter_radius + w_outer + 0.1) {
		combined_alpha = 0.0;
		discard;
	}

	ALBEDO = out_rgb;
	ALPHA = combined_alpha; 
}