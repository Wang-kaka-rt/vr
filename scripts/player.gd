extends CharacterBody3D

signal health_changed(current, max)
signal score_changed(new_score)
signal player_died

@export var speed := 10.0
@export var backward_speed_multiplier := 0.5 # 倒退时的速度倍率
@export var jump_velocity := 8.0
@export var gravity := 9.8
@export var rotation_speed := 10.0

var ap: AnimationPlayer
var animation_tree: AnimationTree
var playback: AnimationNodeStateMachinePlayback
var attack_node: AnimationNodeAnimation
var hit_node: AnimationNodeAnimation

var idle_anim := ""
var walk_anim := ""
var jump_anim := "" # 跳跃动画
var attack_anim := "" # 主攻击 (挥剑)
var punch_anim := "" # 副攻击 (拳击)
var react_anim := "" # 受击动画
var death_anim := "" # 死亡动画
var is_attacking := false

var health := 100
var max_health := 100
var score := 0

func _ready():
	add_to_group("Player")
	# 动态加载选择的角色模型
	var old_model = get_node_or_null("Model")
	if old_model:
		old_model.name = "OldModel"
		old_model.queue_free()
	
	var model_scene = load(Global.selected_character_path)
	if model_scene:
		var model = model_scene.instantiate()
		model.name = "Model"
		add_child(model)
		# 确保模型在角色中心
		model.position = Vector3.ZERO
		
		# 增大人物模型和碰撞体
		var scale_factor = 3.5
		model.scale = Vector3.ONE * scale_factor
		
		var col = get_node_or_null("CollisionShape3D")
		if col and col.shape is CapsuleShape3D:
			col.shape.radius = 0.35 * scale_factor
			col.shape.height = 1.4 * scale_factor
			col.position.y = 0.7 * scale_factor
		
		ap = model.find_child("AnimationPlayer", true, false)
		if ap:
			var list = ap.get_animation_list()
			print("DEBUG: All available animations: ", list)
			idle_anim = _select_anim(list, ["idle", "stand", "standing"], ["death", "die", "fall", "swim", "lie"])
			walk_anim = _select_anim(list, ["walk", "run"], ["death", "die", "fall"])
			jump_anim = _select_anim(list, ["jump", "leap", "air"], ["death", "die", "attack"])
			
			# 分别寻找挥剑和拳击动画
			attack_anim = _select_anim_priority(list, ["sword", "cutlass", "blade", "slash", "attack"], ["death", "die", "hit", "react", "punch"])
			punch_anim = _select_anim_priority(list, ["punch", "hit", "fight", "unarmed"], ["death", "die", "react", "sword"])
			
			react_anim = _select_anim_priority(list, ["hit", "react", "damage", "impact", "hurt"], ["death", "die", "attack"])
			death_anim = _select_anim_priority(list, ["death", "die", "fall"], ["hit", "react"])
			
			print("Animations Found - Idle: ", idle_anim, ", Walk: ", walk_anim, ", Jump: ", jump_anim, ", Sword: ", attack_anim, ", Punch: ", punch_anim, ", React: ", react_anim, ", Death: ", death_anim)
			
			ap.animation_finished.connect(_on_animation_finished)
			
			# 设置行走动画循环
			if walk_anim != "":
				var anim = ap.get_animation(walk_anim)
				if anim:
					anim.loop_mode = Animation.LOOP_LINEAR

			# 动态创建 AnimationTree 以支持移动攻击混合
			_setup_animation_tree(model)

func _setup_animation_tree(model: Node):
	animation_tree = AnimationTree.new()
	add_child(animation_tree)
	animation_tree.anim_player = animation_tree.get_path_to(ap)
	
	var root = AnimationNodeBlendTree.new()
	var sm = AnimationNodeStateMachine.new()
	var oneshot = AnimationNodeOneShot.new()
	var hit_oneshot = AnimationNodeOneShot.new()
	attack_node = AnimationNodeAnimation.new()
	hit_node = AnimationNodeAnimation.new()
	
	# 1. 设置状态机 (Idle/Walk/Jump)
	var idle_node = AnimationNodeAnimation.new()
	idle_node.animation = idle_anim
	sm.add_node("Idle", idle_node)
	
	# 改用 BlendTree 包装 Walk 动画以支持倒放 (TimeScale)
	var walk_tree = AnimationNodeBlendTree.new()
	var walk_anim_node = AnimationNodeAnimation.new()
	walk_anim_node.animation = walk_anim
	var walk_timescale = AnimationNodeTimeScale.new()
	
	walk_tree.add_node("Anim", walk_anim_node)
	walk_tree.add_node("TimeScale", walk_timescale)
	walk_tree.connect_node("TimeScale", 0, "Anim")
	walk_tree.connect_node("output", 0, "TimeScale")
	
	sm.add_node("Walk", walk_tree)
	
	# 设置 Jump 节点
	if jump_anim != "":
		var jump_node = AnimationNodeAnimation.new()
		jump_node.animation = jump_anim
		sm.add_node("Jump", jump_node)
		
		# Jump 转换
		var tr_idle_jump = AnimationNodeStateMachineTransition.new()
		tr_idle_jump.xfade_time = 0.1
		sm.add_transition("Idle", "Jump", tr_idle_jump)
		
		var tr_walk_jump = AnimationNodeStateMachineTransition.new()
		tr_walk_jump.xfade_time = 0.1
		sm.add_transition("Walk", "Jump", tr_walk_jump)
		
		var tr_jump_idle = AnimationNodeStateMachineTransition.new()
		tr_jump_idle.xfade_time = 0.2
		sm.add_transition("Jump", "Idle", tr_jump_idle)
		
		var tr_jump_walk = AnimationNodeStateMachineTransition.new()
		tr_jump_walk.xfade_time = 0.2
		sm.add_transition("Jump", "Walk", tr_jump_walk)

	# 兼容 Godot 4.x: set_start_node 改为属性赋值
	var has_start_node_prop = "start_node" in sm
	if has_start_node_prop:
		sm.start_node = "Idle"
	else:
		var tr_start = AnimationNodeStateMachineTransition.new()
		tr_start.xfade_time = 0.0
		sm.add_transition("Start", "Idle", tr_start)
	
	var tr_idle_walk = AnimationNodeStateMachineTransition.new()
	tr_idle_walk.xfade_time = 0.2
	sm.add_transition("Idle", "Walk", tr_idle_walk)
	
	var tr_walk_idle = AnimationNodeStateMachineTransition.new()
	tr_walk_idle.xfade_time = 0.2
	sm.add_transition("Walk", "Idle", tr_walk_idle)
	
	# 2. 设置攻击 OneShot 和过滤器
	oneshot.filter_enabled = true # 重新启用过滤器
	
	# 自动查找骨骼并设置上半身过滤
	var skeleton = model.find_child("Skeleton3D", true, false)
	if skeleton:
		# 1. 寻找关键骨骼
		var hips_idx = skeleton.find_bone("Hips")
		if hips_idx == -1: hips_idx = skeleton.find_bone("Pelvis")
		
		# 优先寻找 Torso/Chest (KayKit 风格), 然后是 Spine (标准风格)
		var upper_root_idx = -1
		for name in ["Torso", "Chest", "Spine", "Spine1", "Abdomen"]:
			upper_root_idx = skeleton.find_bone(name)
			if upper_root_idx != -1: break
			
		if upper_root_idx != -1:
			var bones = _get_recursive_filter_bones(skeleton, upper_root_idx, hips_idx)
			
			# 智能获取路径前缀：直接从现有动画中读取轨道路径格式
			var path_prefix = ""
			var found_prefix = false
			
			# 尝试从攻击动画或行走动画中提取路径前缀
			var check_anims = [attack_anim, walk_anim, idle_anim]
			for anim_name in check_anims:
				if anim_name == "": continue
				var a = ap.get_animation(anim_name)
				if a and a.get_track_count() > 0:
					var track_path = str(a.track_get_path(0)) # 例如 "Skeleton3D:Hips"
					var colon_index = track_path.find(":")
					if colon_index != -1:
						path_prefix = track_path.substr(0, colon_index + 1) # 提取 "Skeleton3D:"
						# print("Debug: Extracted path prefix from ", anim_name, ": ", path_prefix)
						found_prefix = true
						break
			
			# 如果没找到前缀，回退到默认猜测
			if not found_prefix:
				var skel_path = ap.get_path_to(skeleton)
				path_prefix = str(skel_path) + ":"
				# print("Debug: Could not extract prefix from anims, using calculated: ", path_prefix)
			
			var filter_count = 0
			for b_name in bones:
				var full_path = path_prefix + b_name
				oneshot.set_filter_path(full_path, true)
				filter_count += 1
			
			print("Upper body filter set with ", filter_count, " bones using prefix '", path_prefix, "'. Root: ", skeleton.get_bone_name(upper_root_idx))
			
			if filter_count == 0:
				print("Warning: No upper body bones found for filtering. Disabling filter.")
				oneshot.filter_enabled = false
	
	# 3. 组装 BlendTree
	# 结构: Root -> HitShot -> AttackShot -> Locomotion
	
	# 设置 Hit 动画
	hit_node.animation = react_anim
	hit_oneshot.filter_enabled = false # 受击通常是全身
	
	root.add_node("Locomotion", sm)
	root.add_node("AttackShot", oneshot)
	root.add_node("AttackAnim", attack_node)
	
	root.add_node("HitShot", hit_oneshot)
	root.add_node("HitAnim", hit_node)
	
	# 连接: AttackShot -> Locomotion
	root.connect_node("AttackShot", 0, "Locomotion")
	root.connect_node("AttackShot", 1, "AttackAnim")
	
	# 连接: HitShot -> AttackShot
	root.connect_node("HitShot", 0, "AttackShot")
	root.connect_node("HitShot", 1, "HitAnim")
	
	root.connect_node("output", 0, "HitShot")
	
	animation_tree.tree_root = root
	animation_tree.active = true
	
	playback = animation_tree.get("parameters/Locomotion/playback")

func _get_recursive_filter_bones(skel: Skeleton3D, bone_idx: int, stop_bone_idx: int) -> Array:
	var result = []
	result.append(skel.get_bone_name(bone_idx))
	
	var children = skel.get_bone_children(bone_idx)
	for child in children:
		if child == stop_bone_idx:
			continue
			
		var leads_to_stop = false
		if stop_bone_idx != -1:
			leads_to_stop = _is_bone_ancestor_of(skel, child, stop_bone_idx)
			
		if leads_to_stop:
			# 如果这条分支通向需要排除的骨骼 (Hips)，则继续递归筛选
			result.append_array(_get_recursive_filter_bones(skel, child, stop_bone_idx))
		else:
			# 否则这条分支是安全的 (如手臂、头部)，包含所有子骨骼
			result.append(skel.get_bone_name(child))
			result.append_array(_get_all_children_bones(skel, child))
			
	return result

func _is_bone_ancestor_of(skel: Skeleton3D, ancestor: int, descendant: int) -> bool:
	var curr = descendant
	while curr != -1:
		if curr == ancestor:
			return true
		curr = skel.get_bone_parent(curr)
	return false

func _get_all_children_bones(skel: Skeleton3D, bone_idx: int) -> Array:
	var children = []
	var bones = skel.get_bone_children(bone_idx)
	for b in bones:
		children.append(skel.get_bone_name(b))
		children.append_array(_get_all_children_bones(skel, b))
	return children

func _on_animation_finished(anim_name):
	# AnimationTree 模式下，finished 信号可能不再可靠或不需要，状态由 Tree 管理
	pass

func _deal_damage():
	# 扇形攻击判定
	var enemies = get_tree().get_nodes_in_group("Enemies")
	var hit_range = 10.0 # 攻击距离 (Increased for debugging)
	var hit_angle = 360.0 # 扇形角度 (Increased for debugging)
	
	var forward = -global_transform.basis.z.normalized()
	
	print("Debug: _deal_damage called. Enemies count: ", enemies.size())
	
	for enemy in enemies:
		if not is_instance_valid(enemy): continue
		
		# Calculate distance ignoring Y axis (height)
		var flat_pos = Vector3(global_position.x, 0, global_position.z)
		var flat_enemy_pos = Vector3(enemy.global_position.x, 0, enemy.global_position.z)
		var dist = flat_pos.distance_to(flat_enemy_pos)
		
		print("Debug: Checking enemy ", enemy.name, " Dist: ", dist)
		
		if dist < hit_range:
			var dir_to_enemy = (enemy.global_position - global_position).normalized()
			var angle = rad_to_deg(forward.angle_to(dir_to_enemy))
			
			# Check angle (360 covers everything nearby)
			if angle < hit_angle / 2.0:
				if enemy.has_method("take_damage"):
					print("Hit enemy: ", enemy.name)
					enemy.take_damage(1)

func _physics_process(delta):
	var input_dir = Vector2.ZERO
	if Input.is_key_pressed(KEY_W): input_dir.y += 1
	if Input.is_key_pressed(KEY_S): input_dir.y -= 1
	if Input.is_key_pressed(KEY_A): input_dir.x -= 1
	if Input.is_key_pressed(KEY_D): input_dir.x += 1
	
	# 攻击输入检测
	var attack_requested = false
	var target_anim = ""
	
	if (Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) or Input.is_key_pressed(KEY_J)):
		if attack_anim != "":
			target_anim = attack_anim
			attack_requested = true
		else:
			print("Error: No attack animation found!")
			
	elif (Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT) or Input.is_key_pressed(KEY_K)):
		if punch_anim != "":
			target_anim = punch_anim
			attack_requested = true
		
	if attack_requested and not is_attacking:
		print("Attack initiated! Anim: ", target_anim)
		is_attacking = true # 简单防抖，实际动画由 OneShot 管理
		if attack_node:
			attack_node.animation = target_anim
			animation_tree.set("parameters/AttackShot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
			
			# 延迟造成伤害，模拟挥刀时间
			get_tree().create_timer(0.3).timeout.connect(_deal_damage)
			
			# 这里的 is_attacking 标记主要用于防止连续触发
			get_tree().create_timer(0.5).timeout.connect(func(): is_attacking = false)

	var cam = get_viewport().get_camera_3d()
	var forward := Vector3(0,0,-1)
	var right := Vector3(1,0,0)
	
	if cam:
		forward = -cam.global_transform.basis.z
		forward.y = 0
		forward = forward.normalized()
		
		right = cam.global_transform.basis.x
		right.y = 0
		right = right.normalized()
		
	var dir := Vector3.ZERO
	if input_dir.length() > 0:
		dir = (forward * input_dir.y + right * input_dir.x).normalized()

	var anim_speed = 1.0

	if dir != Vector3.ZERO:
		var current_speed = speed
		var is_moving_backward = input_dir.y < 0
		var target_rotation = rotation.y
		
		if is_moving_backward:
			target_rotation = atan2(forward.x, forward.z)
			anim_speed = -1.0
			current_speed *= backward_speed_multiplier
		else:
			target_rotation = atan2(dir.x, dir.z)
			anim_speed = 1.0
		
		velocity.x = dir.x * current_speed
		velocity.z = dir.z * current_speed
			
		rotation.y = lerp_angle(rotation.y, target_rotation, rotation_speed * delta)
	else:
		velocity.x = move_toward(velocity.x, 0, speed)
		velocity.z = move_toward(velocity.z, 0, speed)
		
	if is_on_floor():
		if Input.is_key_pressed(KEY_SPACE):
			velocity.y = jump_velocity
		else:
			# 保持贴地
			velocity.y = -0.1
	else:
		velocity.y -= gravity * delta
		
	move_and_slide()

	# 动画控制
	if playback:
		if not is_on_floor() and jump_anim != "":
			playback.travel("Jump")
		elif dir != Vector3.ZERO:
			playback.travel("Walk")
			animation_tree.set("parameters/Locomotion/Walk/TimeScale/scale", anim_speed)
		else:
			playback.travel("Idle")

func _select_anim(list: Array, prefers: Array, avoids: Array) -> String:

	for name in list:
		var n = String(name).to_lower()
		var bad = false
		for a in avoids:
			if n.find(a) != -1:
				bad = true
				break
		if bad:
			continue
		for p in prefers:
			if n.find(p) != -1:
				return String(name)
	return ""

func _select_anim_priority(list: Array, prefers: Array, avoids: Array) -> String:
	# 优先匹配 prefers 列表中的顺序
	for p in prefers:
		for name in list:
			var n = String(name).to_lower()
			var bad = false
			for a in avoids:
				if n.find(a) != -1:
					bad = true
					break
			if bad: continue
			
			if n.find(p) != -1:
				return String(name)
	return ""

func add_score(amount: int):
	score += amount
	emit_signal("score_changed", score)
	print("Score updated: ", score)

func heal(amount: int):
	if health <= 0: return # Dead players can't be healed
	health += amount
	if health > max_health:
		health = max_health
	emit_signal("health_changed", health, max_health)
	print("Healed! HP: ", health)

func take_damage(amount: int):
	health -= amount
	if health < 0:
		health = 0
	print("Player took damage! Health: ", health, " Anim: ", react_anim)
	emit_signal("health_changed", health, max_health)
	
	if health <= 0:
		_die()
	else:
		if react_anim != "" and hit_node:
			print("Player playing hit animation")
			animation_tree.set("parameters/HitShot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
		else:
			print("Player hit anim failed. react_anim: ", react_anim, " hit_node: ", hit_node)

func _die():
	set_physics_process(false)
	emit_signal("player_died")
	
	if death_anim != "" and ap:
		animation_tree.active = false
		ap.play(death_anim)
	
	# 原来的自动重开逻辑现在交由 UI 控制
	# await get_tree().create_timer(3.0).timeout
	# get_tree().reload_current_scene()
