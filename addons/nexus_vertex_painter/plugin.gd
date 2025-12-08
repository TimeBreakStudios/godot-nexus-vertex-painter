@tool
extends EditorPlugin

const DOCK_SCENE = preload("res://addons/nexus_vertex_painter/painter_dock.tscn")

# --- UI & REFERENCES ---
var dock_instance: Control
var btn_mode: Button
var shared_brush_material: ShaderMaterial 

# --- DATA ---
var selected_meshes: Array[MeshInstance3D] = []
var temp_colliders: Array[Node] = [] 
var locked_nodes: Array[MeshInstance3D] = [] 

var is_painting: bool = false
var paint_mode_active: bool = false 

# Shortcut State
var is_adjusting_brush: bool = false
var adjust_mode: int = 0 # 0=None, 1=Size/Strength (Ctrl), 2=Falloff (Shift)

func _enter_tree():
	dock_instance = DOCK_SCENE.instantiate()
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, dock_instance)
	dock_instance.fill_requested.connect(_on_fill_requested)
	dock_instance.clear_requested.connect(_on_clear_requested)
	dock_instance.settings_changed.connect(_on_settings_changed)
	dock_instance.procedural_requested.connect(_on_procedural_requested)
	dock_instance.set_ui_active(false)
	
	btn_mode = Button.new()
	btn_mode.text = "Vertex Paint"
	btn_mode.tooltip_text = "Toggle Vertex Paint Mode"
	btn_mode.toggle_mode = true
	btn_mode.toggled.connect(_on_mode_toggled)
	
	var editor_base = get_editor_interface().get_base_control()
	if editor_base.has_theme_icon("Edit", "EditorIcons"):
		btn_mode.icon = editor_base.get_theme_icon("Edit", "EditorIcons")
	
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, btn_mode)
	
	_init_shared_brush_material()
	get_editor_interface().get_selection().selection_changed.connect(_on_selection_changed)

func _exit_tree():
	if dock_instance:
		remove_control_from_docks(dock_instance)
		dock_instance.free()
	
	if btn_mode:
		remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, btn_mode)
		btn_mode.free()
	
	_clear_all_locks()
	_clear_all_colliders()

func _on_mode_toggled(pressed: bool):
	paint_mode_active = pressed
	dock_instance.set_ui_active(pressed)
	
	if not pressed:
		_clear_all_locks()
		_clear_all_colliders()
		is_painting = false
	else:
		_refresh_selection_and_colliders()

func _handles(object):
	return object is MeshInstance3D

func _edit(object):
	pass 

func _on_selection_changed():
	if paint_mode_active:
		_refresh_selection_and_colliders()
		_update_shader_debug_view()

# --- SELECTION & LOCKING ---

func _refresh_selection_and_colliders():
	var selection = get_editor_interface().get_selection().get_selected_nodes()
	var new_mesh_list: Array[MeshInstance3D] = []
	
	for node in selection:
		if node is MeshInstance3D:
			new_mesh_list.append(node)
	
	if paint_mode_active:
		for mesh in new_mesh_list:
			if not mesh.has_meta("_edit_lock_"):
				mesh.set_meta("_edit_lock_", true)
				locked_nodes.append(mesh)
				mesh.notify_property_list_changed() 
				mesh.update_gizmos()

		for i in range(locked_nodes.size() - 1, -1, -1):
			var mesh = locked_nodes[i]
			if is_instance_valid(mesh) and not (mesh in new_mesh_list):
				if mesh.has_meta("_edit_lock_"):
					mesh.remove_meta("_edit_lock_")
					mesh.notify_property_list_changed()
					mesh.update_gizmos()
				locked_nodes.remove_at(i)
			elif not is_instance_valid(mesh):
				locked_nodes.remove_at(i)

	for mesh in new_mesh_list:
		if not _has_internal_collider(mesh):
			_create_collider_for(mesh)
	
	for i in range(temp_colliders.size() - 1, -1, -1):
		var node = temp_colliders[i]
		if not is_instance_valid(node.get_parent()) or node.get_parent() not in new_mesh_list:
			node.queue_free()
			temp_colliders.remove_at(i)
	
	selected_meshes = new_mesh_list

func _clear_all_locks():
	for mesh in locked_nodes:
		if is_instance_valid(mesh):
			if mesh.has_meta("_edit_lock_"):
				mesh.remove_meta("_edit_lock_")
				mesh.notify_property_list_changed()
				mesh.update_gizmos()
	locked_nodes.clear()

func _has_internal_collider(mesh: MeshInstance3D) -> bool:
	for child in mesh.get_children():
		if child in temp_colliders:
			return true
	return false

func _create_collider_for(mesh_instance: MeshInstance3D):
	if not mesh_instance.mesh: return
	
	# 1. Physics Collider
	var sb = StaticBody3D.new()
	var col = CollisionShape3D.new()
	col.shape = mesh_instance.mesh.create_trimesh_shape()
	sb.add_child(col)
	sb.collision_layer = 1 
	sb.collision_mask = 0 
	
	mesh_instance.add_child(sb)
	temp_colliders.append(sb)
	
	# 2. Phantom Mesh (Visuals)
	var phantom = MeshInstance3D.new()
	phantom.mesh = mesh_instance.mesh
	phantom.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	phantom.material_override = shared_brush_material
	
	mesh_instance.add_child(phantom)
	temp_colliders.append(phantom)

func _clear_all_colliders():
	for node in temp_colliders:
		if is_instance_valid(node):
			node.queue_free()
	temp_colliders.clear()

func _get_or_create_data_node(mesh_instance: MeshInstance3D) -> VertexColorData:
	for child in mesh_instance.get_children():
		if child is VertexColorData:
			return child
	
	var node = VertexColorData.new()
	node.name = "VertexColorData"
	mesh_instance.add_child(node)
	
	var scene_root = get_editor_interface().get_edited_scene_root()
	if scene_root:
		node.owner = scene_root
		
	return node

# --- INPUT ---

func _forward_3d_gui_input(camera: Camera3D, event: InputEvent) -> int:
	if not paint_mode_active: return AFTER_GUI_INPUT_PASS
	
	# --- 1. KEYBOARD SHORTCUTS ---
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_X:
			dock_instance.toggle_add_subtract()
			return AFTER_GUI_INPUT_STOP
		if event.keycode == KEY_1:
			dock_instance.toggle_channel_by_index(0)
			return AFTER_GUI_INPUT_STOP
		if event.keycode == KEY_2:
			dock_instance.toggle_channel_by_index(1)
			return AFTER_GUI_INPUT_STOP
		if event.keycode == KEY_3:
			dock_instance.toggle_channel_by_index(2)
			return AFTER_GUI_INPUT_STOP
		if event.keycode == KEY_4:
			dock_instance.toggle_channel_by_index(3)
			return AFTER_GUI_INPUT_STOP
	
	# --- 2. MOUSE SHORTCUTS (Size/Strength/Falloff) ---
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			if event.pressed:
				# Start Adjusting
				if event.ctrl_pressed:
					is_adjusting_brush = true
					adjust_mode = 1 # Size / Strength
					return AFTER_GUI_INPUT_STOP
				elif event.shift_pressed:
					is_adjusting_brush = true
					adjust_mode = 2 # Falloff
					return AFTER_GUI_INPUT_STOP
			else:
				# Stop Adjusting (Release RMB)
				if is_adjusting_brush:
					is_adjusting_brush = false
					adjust_mode = 0
					return AFTER_GUI_INPUT_STOP
	
	if event is InputEventMouseMotion and is_adjusting_brush:
		var settings = dock_instance.get_settings()
		var relative = event.relative
		
		# Sensitivity
		var speed_size = 0.01
		var speed_strength = 0.005
		var speed_falloff = 0.005
		
		if adjust_mode == 1: # Ctrl + RMB
			# Vertical = Size (-Y to increase)
			if relative.y != 0:
				var new_size = settings.size + (-relative.y * speed_size)
				dock_instance.set_brush_size(clamp(new_size, 0.01, 10.0))
			
			# Horizontal = Strength
			if relative.x != 0:
				var new_str = settings.strength + (relative.x * speed_strength)
				dock_instance.set_brush_strength(clamp(new_str, 0.0, 1.0))
				
		elif adjust_mode == 2: # Shift + RMB
			# Vertical = Falloff
			if relative.y != 0:
				var new_fall = settings.falloff + (-relative.y * speed_falloff)
				dock_instance.set_brush_falloff(clamp(new_fall, 0.0, 1.0))
		
		# Force visual update immediately on the shared material
		var new_settings = dock_instance.get_settings()
		shared_brush_material.set_shader_parameter("brush_radius", new_settings.size)
		shared_brush_material.set_shader_parameter("falloff_range", new_settings.falloff)
		shared_brush_material.set_shader_parameter("brush_strength", new_settings.strength)
		
		return AFTER_GUI_INPUT_STOP

	# --- 3. STANDARD TOOLS ---
	
	if selected_meshes.is_empty(): 
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			return AFTER_GUI_INPUT_STOP
		return AFTER_GUI_INPUT_PASS

	if not (event is InputEventMouse): return AFTER_GUI_INPUT_PASS

	# Raycast
	var mouse_pos = event.position
	var ray_origin = camera.project_ray_origin(mouse_pos)
	var ray_normal = camera.project_ray_normal(mouse_pos)
	var ray_length = 4000.0
	
	var space_state = selected_meshes[0].get_world_3d().direct_space_state
	var query = PhysicsRayQueryParameters3D.create(ray_origin, ray_origin + ray_normal * ray_length)
	query.collide_with_bodies = true
	
	var result = space_state.intersect_ray(query)
	var hit_pos = Vector3.ZERO
	var hit_mesh_instance: MeshInstance3D = null
	var hit_something = false
	
	if result and result.collider:
		hit_something = true
		var collider = result.collider
		
		# Identify which mesh was hit
		if collider in temp_colliders:
			hit_mesh_instance = collider.get_parent()
		else:
			for mesh in selected_meshes:
				if collider == mesh or collider == mesh.get_parent():
					hit_mesh_instance = mesh
					break

		if hit_mesh_instance:
			hit_pos = result.position

	# Update Brush Visuals (Global)
	if hit_something and not is_adjusting_brush:
		var settings = dock_instance.get_settings()
		
		if hit_mesh_instance:
			shared_brush_material.set_shader_parameter("brush_pos", hit_pos)
			shared_brush_material.set_shader_parameter("brush_radius", settings.size)
			shared_brush_material.set_shader_parameter("falloff_range", settings.falloff)
			shared_brush_material.set_shader_parameter("channel_mask", settings.channels)
			shared_brush_material.set_shader_parameter("brush_strength", settings.strength)
		else:
			shared_brush_material.set_shader_parameter("brush_radius", 0.0)
	elif not is_adjusting_brush:
		shared_brush_material.set_shader_parameter("brush_radius", 0.0)

	# Painting Action
	if hit_mesh_instance and not is_adjusting_brush:
		var settings = dock_instance.get_settings()
		
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				is_painting = true
				paint_mesh(hit_mesh_instance, hit_pos, settings)
				return AFTER_GUI_INPUT_STOP
			else:
				is_painting = false
				return AFTER_GUI_INPUT_STOP
		
		elif event is InputEventMouseMotion and is_painting:
			paint_mesh(hit_mesh_instance, hit_pos, settings)
			return AFTER_GUI_INPUT_STOP
			
	else:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			is_painting = false
			return AFTER_GUI_INPUT_STOP 
		
		if is_painting and event is InputEventMouseMotion:
			return AFTER_GUI_INPUT_STOP

	return AFTER_GUI_INPUT_PASS

# --- PAINTING LOGIC (Multi-Surface) ---

func paint_mesh(mesh_instance: MeshInstance3D, global_hit_pos: Vector3, settings: Dictionary):
	if not mesh_instance.mesh: return
	
	var data_node = _get_or_create_data_node(mesh_instance)
	var mesh = mesh_instance.mesh as ArrayMesh
	
	var local_hit_pos = mesh_instance.to_local(global_hit_pos)
	var radius_sq = settings.size * settings.size
	
	# Iterate over ALL surfaces
	for surf_idx in range(mesh.get_surface_count()):
		
		var mdt = MeshDataTool.new()
		if mdt.create_from_surface(mesh, surf_idx) != OK: continue
		
		var vertex_count = mdt.get_vertex_count()
		
		# Get existing colors or create new array
		var colors: PackedColorArray
		if data_node.surface_data.has(surf_idx):
			colors = data_node.surface_data[surf_idx]
		else:
			colors = PackedColorArray()
			colors.resize(vertex_count)
			colors.fill(Color.BLACK)
		
		if colors.size() != vertex_count: colors.resize(vertex_count)
		
		var surface_modified = false
		
		for i in range(vertex_count):
			var v_pos = mdt.get_vertex(i)
			var dist_sq = v_pos.distance_squared_to(local_hit_pos)
			
			if dist_sq < radius_sq:
				var color = colors[i]
				
				var dist = sqrt(dist_sq)
				var hard_limit = 1.0 - settings.falloff
				var actual_falloff = 1.0
				if dist / settings.size > hard_limit:
					actual_falloff = 1.0 - ((dist / settings.size) - hard_limit) / (1.0 - hard_limit)
				
				# --- NEW BLEND LOGIC ---
				if settings.mode == 2: # SET MODE
					var target_val = settings.strength
					var alpha = actual_falloff 
					if settings.channels.x > 0: color.r = lerp(color.r, target_val, alpha)
					if settings.channels.y > 0: color.g = lerp(color.g, target_val, alpha)
					if settings.channels.z > 0: color.b = lerp(color.b, target_val, alpha)
					if settings.channels.w > 0: color.a = lerp(color.a, target_val, alpha)
					
				else: # ADD (0) / SUBTRACT (1) MODE
					var strength = settings.strength * actual_falloff
					var blend_op = 1.0 if settings.mode == 0 else -1.0
					
					if settings.channels.x > 0: color.r = clamp(color.r + (strength * blend_op), 0.0, 1.0)
					if settings.channels.y > 0: color.g = clamp(color.g + (strength * blend_op), 0.0, 1.0)
					if settings.channels.z > 0: color.b = clamp(color.b + (strength * blend_op), 0.0, 1.0)
					if settings.channels.w > 0: color.a = clamp(color.a + (strength * blend_op), 0.0, 1.0)
				
				colors[i] = color
				surface_modified = true
		
		if surface_modified:
			data_node.update_surface_colors(surf_idx, colors)

# --- PROCEDURAL LOGIC (Multi-Surface) ---

func _on_procedural_requested(type: String, settings: Dictionary):
	if selected_meshes.is_empty(): return
	for mesh_instance in selected_meshes:
		_apply_procedural_to_mesh(mesh_instance, type, settings)

func _apply_procedural_to_mesh(mesh_instance: MeshInstance3D, type: String, settings: Dictionary):
	if not mesh_instance.mesh: return
	
	var data_node = _get_or_create_data_node(mesh_instance)
	var mesh = mesh_instance.mesh as ArrayMesh
	if not mesh: return
	
	# Noise Setup
	var noise = FastNoiseLite.new()
	if type == "noise":
		noise.seed = randi()
		noise.frequency = 0.05 / max(settings.size, 0.01)
		noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	
	var min_y = 10000.0
	var max_y = -10000.0
	if type == "bottom_up":
		for surf_idx in range(mesh.get_surface_count()):
			var mdt = MeshDataTool.new()
			if mdt.create_from_surface(mesh, surf_idx) == OK:
				for i in range(mdt.get_vertex_count()):
					var v = mdt.get_vertex(i)
					if v.y < min_y: min_y = v.y
					if v.y > max_y: max_y = v.y
		if is_equal_approx(min_y, max_y): max_y += 1.0

	var blend_mode = settings.mode
	var channels = settings.channels
	var sharpness = settings.falloff
	
	# Iterate ALL surfaces
	for surf_idx in range(mesh.get_surface_count()):
		var mdt = MeshDataTool.new()
		if mdt.create_from_surface(mesh, surf_idx) != OK: continue
		
		var vertex_count = mdt.get_vertex_count()
		
		var colors: PackedColorArray
		if data_node.surface_data.has(surf_idx):
			colors = data_node.surface_data[surf_idx]
		else:
			colors = PackedColorArray()
			colors.resize(vertex_count)
			colors.fill(Color.BLACK)
			
		if colors.size() != vertex_count: colors.resize(vertex_count)
		
		var surface_modified = false
		
		for i in range(vertex_count):
			var current_color = colors[i]
			
			var v_pos = mdt.get_vertex(i)
			var normal = mdt.get_vertex_normal(i)
			var world_normal = (mesh_instance.global_transform.basis * normal).normalized()
			var world_pos = mesh_instance.to_global(v_pos)
			
			var weight = 0.0
			
			if type == "top_down":
				var dot = world_normal.dot(Vector3.UP)
				var threshold = 1.0 - sharpness
				if dot > (threshold * 2.0 - 1.0):
					weight = (dot - (threshold * 2.0 - 1.0))
					weight = clamp(weight * 2.0, 0.0, 1.0) 
			elif type == "slope":
				var dot = abs(world_normal.dot(Vector3.UP))
				var wall_factor = 1.0 - dot
				if wall_factor > sharpness:
					weight = (wall_factor - sharpness) / (1.0 - sharpness)
			elif type == "bottom_up":
				var h = (v_pos.y - min_y) / (max_y - min_y)
				weight = 1.0 - smoothstep(sharpness - 0.1, sharpness + 0.1, h)
			elif type == "noise":
				var n = noise.get_noise_3dv(world_pos)
				weight = (n + 1.0) * 0.5
				if sharpness > 0.0:
					weight = smoothstep(0.5 - sharpness/2.0, 0.5 + sharpness/2.0, weight)
			
			weight = clamp(weight, 0.0, 1.0)
			
			if settings.mode == 2: # SET MODE
				var target_val = settings.strength
				var alpha = weight 
				if channels.x > 0: current_color.r = lerp(current_color.r, target_val, alpha)
				if channels.y > 0: current_color.g = lerp(current_color.g, target_val, alpha)
				if channels.z > 0: current_color.b = lerp(current_color.b, target_val, alpha)
				if channels.w > 0: current_color.a = lerp(current_color.a, target_val, alpha)
			else: # ADD/SUB
				var apply_amount = weight * settings.strength
				var blend_op = 1.0 if blend_mode == 0 else -1.0
				
				if channels.x > 0: current_color.r = clamp(current_color.r + (apply_amount * blend_op), 0.0, 1.0)
				if channels.y > 0: current_color.g = clamp(current_color.g + (apply_amount * blend_op), 0.0, 1.0)
				if channels.z > 0: current_color.b = clamp(current_color.b + (apply_amount * blend_op), 0.0, 1.0)
				if channels.w > 0: current_color.a = clamp(current_color.a + (apply_amount * blend_op), 0.0, 1.0)
				
			colors[i] = current_color
			surface_modified = true
		
		if surface_modified:
			data_node.update_surface_colors(surf_idx, colors)

# --- FILL / CLEAR (Multi-Surface) ---

func _on_fill_requested(channels: Vector4, value: float):
	if selected_meshes.is_empty(): return
	for mesh in selected_meshes:
		_apply_global_color(mesh, channels, value, true)

func _on_clear_requested(channels: Vector4):
	if selected_meshes.is_empty(): return
	for mesh in selected_meshes:
		_apply_global_color(mesh, channels, 0.0, false)

func _apply_global_color(mesh_instance: MeshInstance3D, channels: Vector4, value: float, is_fill: bool):
	if not mesh_instance.mesh: return
	
	var data_node = _get_or_create_data_node(mesh_instance)
	var mesh = mesh_instance.mesh as ArrayMesh
	
	for surf_idx in range(mesh.get_surface_count()):
		var arrays = mesh.surface_get_arrays(surf_idx)
		var vertex_count = arrays[Mesh.ARRAY_VERTEX].size()
		
		var colors: PackedColorArray
		if data_node.surface_data.has(surf_idx):
			colors = data_node.surface_data[surf_idx]
		else:
			colors = PackedColorArray()
			colors.resize(vertex_count)
			colors.fill(Color.BLACK)
			
		if colors.size() != vertex_count: colors.resize(vertex_count)
		
		var surface_modified = false
		
		for i in range(vertex_count):
			var color = colors[i]
			if is_fill:
				if channels.x > 0: color.r = 1.0
				if channels.y > 0: color.g = 1.0
				if channels.z > 0: color.b = 1.0
				if channels.w > 0: color.a = 1.0
			else:
				if channels.x > 0: color.r = 0.0
				if channels.y > 0: color.g = 0.0
				if channels.z > 0: color.b = 0.0
				if channels.w > 0: color.a = 0.0
			colors[i] = color
			surface_modified = true
			
		if surface_modified:
			data_node.update_surface_colors(surf_idx, colors)

# --- HELPERS ---

func _init_shared_brush_material():
	var shader = preload("res://addons/nexus_vertex_painter/shaders/brush_decal.gdshader")
	shared_brush_material = ShaderMaterial.new()
	shared_brush_material.shader = shader
	shared_brush_material.set_shader_parameter("color", Color(1.0, 0.5, 0.0, 0.8))
	shared_brush_material.render_priority = 100 

func _on_settings_changed():
	_update_shader_debug_view()

func _update_shader_debug_view():
	for mesh in selected_meshes:
		var mat = mesh.get_active_material(0) as ShaderMaterial
		if mat:
			mat.set_shader_parameter("active_layer_view", 0)
