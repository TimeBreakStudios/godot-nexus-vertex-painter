@tool
extends Node
class_name VertexColorData

# Storage for colors per surface.
# Format: { surface_index (int) : colors (PackedColorArray) }
@export var surface_data: Dictionary = {}

# Runtime cache
var _runtime_mesh: ArrayMesh
var _source_arrays_cache: Dictionary = {} # Maps surface_index -> Array
var _source_materials_cache: Dictionary = {} # Maps surface_index -> Material

func _ready():
	request_ready()

func _enter_tree():
	call_deferred("_apply_colors")

# --- NEW: IMPORT LOGIC ---

func initialize_from_mesh():
	# This function is called once when the node is created.
	# It checks if the parent mesh already has vertex colors (e.g. from a bake)
	# and imports them into our storage so we don't start with black.
	var parent = get_parent() as MeshInstance3D
	if not parent or not parent.mesh: return
	
	var mesh = parent.mesh
	
	# Iterate over all surfaces to find existing colors
	for i in range(mesh.get_surface_count()):
		var arrays = mesh.surface_get_arrays(i)
		
		# Check if Color Array exists and has data
		if arrays[Mesh.ARRAY_COLOR] != null and arrays[Mesh.ARRAY_COLOR].size() > 0:
			var colors = arrays[Mesh.ARRAY_COLOR]
			
			# Ensure it is a PackedColorArray (conversion if necessary)
			if colors is PackedColorArray:
				surface_data[i] = colors
			elif colors is PackedByteArray:
				# Convert Byte Colors to Color Array if needed (rare case for runtime meshes)
				# usually surface_get_arrays returns Objects/Floats, so PackedColorArray is expected.
				pass 

# Public API to update a specific surface
func update_surface_colors(surface_idx: int, new_colors: PackedColorArray):
	surface_data[surface_idx] = new_colors
	_apply_colors()

func _apply_colors():
	var parent = get_parent() as MeshInstance3D
	if not parent: return
	
	var current_mesh = parent.mesh
	
	# --- 1. INITIALIZATION & CACHING ---
	if current_mesh != _runtime_mesh:
		# If we have a valid mesh that isn't our runtime mesh yet, cache it.
		if current_mesh and current_mesh.get_surface_count() > 0:
			_source_arrays_cache.clear()
			_source_materials_cache.clear()
			
			for i in range(current_mesh.get_surface_count()):
				_source_arrays_cache[i] = current_mesh.surface_get_arrays(i)
				_source_materials_cache[i] = current_mesh.surface_get_material(i)
			
			if not _runtime_mesh:
				_runtime_mesh = ArrayMesh.new()
				_runtime_mesh.resource_name = current_mesh.resource_name
			
			# We will assign it later to ensure a clean state switch
	
	if _source_arrays_cache.is_empty(): return

	# --- 2. RESCUE INSTANCE OVERRIDES ---
	# Capture current overrides before we detach the mesh
	var instance_overrides = {}
	var override_count = parent.get_surface_override_material_count()
	for idx in range(override_count):
		var mat = parent.get_surface_override_material(idx)
		if mat:
			instance_overrides[idx] = mat

	# --- 3. DETACH MESH (FIX) ---
	# We temporarily remove the mesh from the instance.
	# This prevents the MeshInstance from reacting to every single step of the rebuild (clearing/adding).
	# It avoids the "Index out of bounds" error because we only re-assign the mesh when it's fully built.
	parent.mesh = null

	# --- 4. REBUILD MESH ---
	_runtime_mesh.clear_surfaces()
	
	var surface_indices = _source_arrays_cache.keys()
	surface_indices.sort()
	
	for surf_idx in surface_indices:
		var arrays = _source_arrays_cache[surf_idx].duplicate(true)
		var vertex_count = arrays[Mesh.ARRAY_VERTEX].size()
		
		if surface_data.has(surf_idx):
			var stored_colors = surface_data[surf_idx] as PackedColorArray
			if stored_colors.size() != vertex_count:
				stored_colors.resize(vertex_count)
				surface_data[surf_idx] = stored_colors
			
			arrays[Mesh.ARRAY_COLOR] = stored_colors
		
		_runtime_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		
		# Restore original resource material
		if _source_materials_cache.has(surf_idx) and _source_materials_cache[surf_idx] != null:
			_runtime_mesh.surface_set_material(surf_idx, _source_materials_cache[surf_idx])

	# --- 5. REATTACH MESH & RESTORE OVERRIDES ---
	# Now that the mesh is valid and has surfaces, we assign it back.
	parent.mesh = _runtime_mesh
	
	for idx in instance_overrides:
		# Safety check: Ensure the new mesh actually has this surface index
		if idx < parent.get_surface_override_material_count():
			parent.set_surface_override_material(idx, instance_overrides[idx])

# --- UNDO / REDO API ---

func get_data_snapshot() -> Dictionary:
	var snapshot = {}
	for surface_idx in surface_data:
		snapshot[surface_idx] = surface_data[surface_idx].duplicate()
	return snapshot

func apply_data_snapshot(snapshot: Dictionary):
	surface_data = snapshot.duplicate(true)
	_apply_colors()
