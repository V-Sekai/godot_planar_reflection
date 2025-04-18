# SPDX-License-Identifier: MIT
# 
# Originally from https://github.com/cheece/godot-vr-mirror-test-g4
# Adapted by V-Sekai to support portals, chirality, non-vr and more.
#
extends MeshInstance3D

var _xr_origin: XROrigin3D
var _has_warned: bool = false

@export var left_camera: Camera3D
@export var right_camera: Camera3D
@export var leftvp: SubViewport
@export var rightvp: SubViewport

# REQUIRES ENGINE PATCH TO WORK!
@export var use_screenspace: bool
@export var legacy_process_update: bool

@export var mirror_resolution_scale: float = 1.0
@export var portal_relative_node: Node3D = self
@export var portal_is_mirror: bool = true
@export var portal_relative_position := Vector3.ZERO
@export var portal_relative_rotation := Quaternion(0, 1, 0, 0) # 180 degrees
@export_custom(PROPERTY_HINT_LINK, "") var portal_relative_scale := Vector3.ONE


func _find_origin_node() -> XROrigin3D:
	var viewport: Viewport = get_viewport()
	if not viewport:
		return
		
	var camera_3d: Camera3D = viewport.get_camera_3d()
	if not camera_3d:
		return
		
	return camera_3d.get_parent() as XROrigin3D


class PreRenderHookInterface:
	extends XRInterfaceExtension

	signal pre_render()

	func _init():
		XRServer.add_interface(self)

	func _is_initialized() -> bool:
		return true

	func _pre_render() -> void:
		pre_render.emit()

static var pre_render_hook: PreRenderHookInterface = null


func _ready():
	if pre_render_hook == null:
		pre_render_hook = PreRenderHookInterface.new()

	pre_render_hook.pre_render.connect(frame_pre_draw)

	RenderingServer.connect("frame_pre_draw", frame_pre_draw)
	var m := get_surface_override_material(0)
	m.set("shader_parameter/use_screenspace", use_screenspace)
	m.set("shader_parameter/textureL", leftvp.get_texture())
	m.set("shader_parameter/textureR", rightvp.get_texture())
	set_surface_override_material(0, m)

func _process(_delta: float):
	var m := get_surface_override_material(0)
	if m != null:
		m.set("shader_parameter/use_screenspace", use_screenspace)
		m.set("shader_parameter/flip_x", portal_is_mirror)
		set_surface_override_material(0, m)
		
	_xr_origin = _find_origin_node()
	
	# if not updated from RenderingServer...
	if legacy_process_update:
		update_mirror()

func frame_pre_draw():
	if not legacy_process_update:
		update_mirror()

func get_mirror_size() -> Vector2:
	var interface = XRServer.primary_interface
	if(interface):
		return interface.get_render_target_size()
	else:
		return Vector2(get_viewport().size)

func update_mirror() -> void:
	var mirror_size: Vector2 = get_mirror_size() * mirror_resolution_scale
	# Letterbox along the bigger axis. Not sure why it's tied to the viewport size if in XR
	var aspect: float = global_transform.basis.y.length() / global_transform.basis.x.length()
	var scale_aspect: float = portal_relative_scale.y / portal_relative_scale.x
	aspect *= scale_aspect
	if aspect < mirror_size.y / mirror_size.x:
		mirror_size = Vector2(mirror_size.x / aspect, mirror_size.x)
	else:
		mirror_size = Vector2(mirror_size.x, mirror_size.x * aspect)
	leftvp.size = mirror_size
	rightvp.size = mirror_size
	
	var interface: XRInterface = XRServer.primary_interface
	if(interface and interface.get_tracking_status() != XRInterface.XR_NOT_TRACKING):
		render_view(interface, null, 0, left_camera)
		render_view(interface, null, 1, right_camera)
	else:
		var camera: Camera3D = get_viewport().get_camera_3d()
		
		render_view(null, camera, 0, left_camera)

func oblique_near_plane(clip_plane: Plane, matrix: Projection) -> Projection:
	# Based on the paper
	# Lengyel, Eric. “Oblique View Frustum Depth Projection and Clipping”.
	# Journal of Game Development, Vol. 1, No. 2 (2005), Charles River Media, pp. 5–16.

	# Calculate the clip-space corner point opposite the clipping plane
	# as (sgn(clipPlane.x), sgn(clipPlane.y), 1, 1) and
	# transform it into camera space by multiplying it
	# by the inverse of the projection matrix
	var q := Vector4(
		(signf(clip_plane.x) + matrix.z.x) / matrix.x.x,
		(signf(clip_plane.y) + matrix.z.y) / matrix.y.y,
		-1.0,
		(1.0 + matrix.z.z) / matrix.w.z)

	var clip_plane4 := Vector4(clip_plane.x, clip_plane.y, clip_plane.z, clip_plane.d)

	# Calculate the scaled plane vector
	var c: Vector4 = clip_plane4 * (2.0 / clip_plane4.dot(q))

	# Replace the third row of the projection matrix
	matrix.x.z = c.x - matrix.x.w
	matrix.y.z = c.y - matrix.y.w
	matrix.z.z = c.z - matrix.z.w
	matrix.w.z = c.w - matrix.w.w
	return matrix

func render_view(p_interface: XRInterface, p_interface_cam: Camera3D, p_view_index: int, p_cam: Camera3D) -> void:	
	var proj: Projection
	var tx: Transform3D
	if p_interface != null:
		if not _xr_origin:
			return
			
		proj = p_interface.get_projection_for_view(p_view_index, 1.0, abs(0.1), 10000)
		tx = p_interface.get_transform_for_view(p_view_index, _xr_origin.global_transform)
	else:
		proj = p_interface_cam.get_camera_projection()
		# Use the main camera's interpolated position, otherwise we may get stutter.
		if p_interface_cam.has_method(&"get_global_transform_interpolated"):
			tx = p_interface_cam.get_global_transform_interpolated()
		else:
			tx = p_interface_cam.global_transform

	var global_transform_ortho := global_transform.orthonormalized()
	var p: Vector3 = global_transform_ortho.basis.inverse() * (tx.origin- global_transform.origin)

	#var portal_relative_matrix: Transform3D
	# Examples of portals and mirror matrices.
	# portal_relative_matrix = Transform3D(Basis(Vector3(0,1,0), Time.get_ticks_msec() * 0.0001), Vector3(-0.3,0.2,-0.1)) # Spinning portal
	#portal_relative_matrix = Transform3D(Basis(Vector3(0,1,0),PI/8)) # Test portal with rotation

	# portal_relative_matrix = Transform3D(Basis.FLIP_Z * Basis.FLIP_X, Vector3(0.1,0.05,0.3)) # Flipped mirror with offset
	#portal_relative_matrix = Transform3D.FLIP_X * Transform3D.FLIP_Z # Passthrough (No effect)

	#portal_relative_matrix = Transform3D.IDENTITY # Mirrors
	var portal_relative_matrix := Transform3D(Quaternion(0,1,0,0) * portal_relative_rotation, portal_relative_position)
	if portal_relative_node != null and portal_relative_node != self:
		portal_relative_matrix = global_transform_ortho.affine_inverse() * portal_relative_node.global_transform.orthonormalized() * portal_relative_matrix

	if use_screenspace:
		var my_plane: Plane
		my_plane = Plane(Vector3(0,0,-1),-2.0 * (global_transform_ortho.affine_inverse() * tx.origin).z)
		proj = oblique_near_plane(tx.affine_inverse() * global_transform_ortho * my_plane, proj)
		proj = proj * Projection(tx.affine_inverse() * global_transform_ortho * Transform3D(Basis.from_scale(Vector3.ONE / portal_relative_scale), Vector3.ZERO) * Transform3D(Basis.IDENTITY, portal_relative_scale * p))
		if portal_is_mirror:
			proj = Projection(Transform3D.FLIP_X) * proj *  Projection(Transform3D.FLIP_X)
		if typeof(p_cam.get(&"override_projection")) != TYPE_PROJECTION and not _has_warned:
			_has_warned = true
			push_warning("Screenspace mirror requested without engine support. Requires vsk-override-projection engine patch.")
		p_cam.set("override_projection", proj)
	else:
		var px = Projection(Vector4.ZERO, Vector4.ZERO, Vector4.ZERO, Vector4.ZERO)
		p_cam.set("override_projection", px)
		_has_warned = false

	var mirrored_p := p * Vector3(1,1,-1) * portal_relative_scale
	var frustum_sign: float = -1
	var extra_matrix := Transform3D.FLIP_X
	if portal_is_mirror:
		frustum_sign = 1
		extra_matrix = Transform3D.IDENTITY
	p_cam.global_transform = global_transform_ortho * portal_relative_matrix * extra_matrix * Transform3D(Basis.FLIP_X * Basis.FLIP_Z, mirrored_p) * extra_matrix
	p_cam.set_frustum(global_transform.basis.get_scale().y * portal_relative_scale.y, Vector2(frustum_sign * mirrored_p.x,-mirrored_p.y), absf(mirrored_p.z), 10000)

	RenderingServer.camera_set_transform(p_cam.get_camera_rid(), p_cam.global_transform)
