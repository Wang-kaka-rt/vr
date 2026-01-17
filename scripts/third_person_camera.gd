extends Node3D

var distance := 12.0 # 增大距离以适配 3.5 倍体型
var height := 5.0    # 增高视角中心
var sens := 0.3
var yaw := 0.0
var pitch := -20.0   # 默认稍微俯视
var min_pitch := -80.0
var max_pitch := 30.0
var camera: Camera3D

@export var auto_rotate_speed := 2.0  # 自动回正速度
@export var mouse_wait_time := 2.0    # 鼠标操作后等待多久再开始自动回正
var _mouse_timer := 0.0

func _ready():
    camera = get_node_or_null("Camera3D")
    # 让 Pivot 独立于父节点（Player）的旋转和位置，防止移动逻辑死锁
    set_as_top_level(true)

func _unhandled_input(event):
	if get_viewport().use_xr:
		return
	# 移除右键限制，直接鼠标移动控制视角（更符合常规 TPS），或者保留右键取决于用户习惯
	# 这里先保留右键限制，但建议用户如果想要类似 PUBG/原神的操作可以去掉
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		yaw -= event.relative.x * sens * 0.01
        pitch -= event.relative.y * sens * 0.01
        pitch = clamp(pitch, min_pitch, max_pitch)
        rotation_degrees = Vector3(pitch, yaw, 0)
        _mouse_timer = mouse_wait_time # 重置计时器

func _physics_process(delta):
	if get_viewport().use_xr:
		return
	if not camera:
		return
	var target := get_parent()
	if not target or not (target is Node3D):
        return
    
    # 手动跟随目标位置
    global_position = target.global_position
    
    # --- 自动回正逻辑 ---
    if _mouse_timer > 0:
        _mouse_timer -= delta
    elif "velocity" in target:
        # 获取角色水平速度
        var vel = target.velocity
        vel.y = 0
        
        # 只有当角色移动速度足够快时才回正，防止原地抖动
        # 并且只有当移动方向与当前镜头朝向大致一致（向前跑）时才回正
        # 防止倒退（S键）时镜头猛烈旋转180度
        var cam_forward = -global_transform.basis.z
        cam_forward.y = 0
        cam_forward = cam_forward.normalized()
        
        var is_moving_forward = vel.normalized().dot(cam_forward) > -0.1
        
        if vel.length() > 0.5 and is_moving_forward:
            var target_yaw = atan2(-vel.x, -vel.z) # 计算背后角度
            # 平滑插值
            yaw = lerp_angle(yaw, target_yaw, auto_rotate_speed * delta)
            rotation_degrees = Vector3(pitch, rad_to_deg(yaw), 0)
    # ------------------

    var target_pos = target.global_transform.origin + Vector3(0, height, 0)
    # 使用 Pivot 自身的朝向（完全由鼠标控制）
    var dir = -global_transform.basis.z
    var desired = target_pos - dir * distance
    var space = get_world_3d().direct_space_state
    var params = PhysicsRayQueryParameters3D.create(target_pos, desired)
    params.exclude = [target, camera]
    params.collide_with_bodies = true
    params.collide_with_areas = false # 禁用 Area 检测，防止被触发器或检测范围遮挡
    var hit = space.intersect_ray(params)
    var cam_pos = desired
    if hit.has("position"):
        var margin = 0.5 # 稍微加大边距，防止穿模
        var vec = hit["position"] - target_pos
        var len = vec.length()
        if len > margin:
            cam_pos = target_pos + vec.normalized() * (len - margin)
        else:
            cam_pos = target_pos + dir * 0.1
            
    # 平滑相机移动，避免瞬间跳变
    # 拉近速度快(20)，推远速度慢(5)
    var current_pos = camera.global_transform.origin
    var dist_to_target = current_pos.distance_to(target_pos)
    var new_dist = cam_pos.distance_to(target_pos)
    
    var lerp_speed = 5.0
    if new_dist < dist_to_target: # 需要拉近，速度要快
        lerp_speed = 20.0
        
    camera.global_transform.origin = current_pos.lerp(cam_pos, lerp_speed * delta)
    camera.look_at(target_pos, Vector3.UP)
