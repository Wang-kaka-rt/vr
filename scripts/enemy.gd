extends CharacterBody3D

@export var speed := 7.0
@export var jump_velocity := 6.0 # 跳跃力度
@export var gravity := 9.8
@export var rotation_speed := 5.0
@export var attack_range := 5.0 # 增大攻击范围以适配更大的模型
@export var attack_cooldown := 2.0
@export var detection_range := 40.0 # 侦测范围：进入此范围开始追击
@export var lost_range := 60.0      # 丢失范围：超出此范围停止追击
@export var wander_radius := 5.0    # 随机漫步半径
@export var avoidance_ray_length := 2.5 # 避障射线长度
@export var attack_damage := 1 # 攻击伤害

# Optimization: Cached squared ranges
var attack_range_sq: float
var detection_range_sq: float
var lost_range_sq: float

# Optimization: Throttled avoidance
var avoidance_frame_count: int = 0
var avoidance_interval: int = 4 # Every 4 frames
var cached_avoidance_dir: Vector3 = Vector3.ZERO

# Optimization: Visibility tracking
var is_visible_on_screen: bool = true
var frame_counter: int = 0
var throttle_factor: int = 4 # How many frames to skip when off-screen

enum State {
	IDLE,
	WANDER,
	CHASE
}

var current_state = State.IDLE
var player: Node3D = null
var ap: AnimationPlayer
var animation_tree: AnimationTree
var playback: AnimationNodeStateMachinePlayback
var attack_node: AnimationNodeAnimation
var hit_node: AnimationNodeAnimation

var idle_anim := ""
var walk_anim := ""
var jump_anim := "" # 跳跃动画
var attack_anim := ""
var react_anim := ""
var death_anim := ""
var is_attacking := false
var is_dying := false # Prevent double death/score
var last_attack_time := 0.0

var health := 2
var max_health := 2

var health_label: Label3D

# Jump cooldown to prevent bunny hopping
var jump_cooldown := 0.0
var jump_interval := 2.0

# Wander variables
var wander_target := Vector3.ZERO
var wander_timer := 0.0
var wander_wait_time := 2.0

func _ready():
	add_to_group("Enemies")
	# Find player
	player = get_tree().get_first_node_in_group("Player")
	
	# Model should already be added by Main script before _ready or just after instantiation
	if not has_node("Model"):
		await get_tree().process_frame
	
	var model = get_node_or_null("Model")
	if model:
		_setup_model(model)
		
	# Initialize Wander
	_pick_new_wander_target()
	
	# Create Health Label
	health_label = Label3D.new()
	health_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	health_label.text = "HP: " + str(health) + "/" + str(max_health)
	health_label.position = Vector3(0, 2.2, 0) # Above head
	health_label.modulate = Color(1, 0, 0)
	health_label.font_size = 48
	add_child(health_label)
	
	# Pre-calculate squared distances for optimization
	attack_range_sq = attack_range * attack_range
	detection_range_sq = detection_range * detection_range
	lost_range_sq = lost_range * lost_range
	
	# Randomize avoidance offset to prevent all enemies calculating on same frame
	avoidance_frame_count = randi() % avoidance_interval

func reset_state():
	current_state = State.IDLE
	velocity = Vector3.ZERO
	is_attacking = false
	wander_timer = randf_range(0.0, 1.0) # Randomize start time
	if playback:
		playback.travel("Idle")
	
	if not player:
		player = get_tree().get_first_node_in_group("Player")

func _setup_model(model: Node):
	ap = model.find_child("AnimationPlayer", true, false)
	if ap:
		var list = ap.get_animation_list()
		idle_anim = _select_anim(list, ["idle", "stand", "standing"], ["death", "die", "fall", "swim", "lie"])
		walk_anim = _select_anim(list, ["walk", "run"], ["death", "die", "fall"])
		jump_anim = _select_anim(list, ["jump", "leap", "air"], ["death", "die", "attack"])
		attack_anim = _select_anim_priority(list, ["sword", "cutlass", "blade", "slash", "attack", "punch", "hit"], ["death", "die", "hit", "react"])
		react_anim = _select_anim_priority(list, ["hit", "react", "damage", "impact", "hurt"], ["death", "die", "attack"])
		death_anim = _select_anim_priority(list, ["death", "die", "fall"], ["hit", "react"])
		
		print("Enemy Anims Found - Idle:", idle_anim, " Walk:", walk_anim, " Attack:", attack_anim, " React:", react_anim, " Death:", death_anim)
		
		# Set walk loop
		if walk_anim != "":
			var anim = ap.get_animation(walk_anim)
			if anim:
				anim.loop_mode = Animation.LOOP_LINEAR
		
		_setup_animation_tree(model)
	
	# 性能优化：当敌人不在屏幕范围内时，停止动画处理
	# 这可以显著降低大量敌人存在时的CPU消耗
	var notifier = VisibleOnScreenNotifier3D.new()
	# 设置包围盒大小，略大于敌人模型以确保进入屏幕边缘时立即激活
	notifier.aabb = AABB(Vector3(-1, 0, -1), Vector3(2, 2.5, 2))
	notifier.screen_entered.connect(func(): 
		if animation_tree:
			animation_tree.active = true
		is_visible_on_screen = true
	)
	notifier.screen_exited.connect(func(): 
		if animation_tree:
			animation_tree.active = false
		is_visible_on_screen = false
	)
	add_child(notifier)

func _physics_process(delta):
	if not is_on_floor():
		velocity.y -= gravity * delta
	# else:
	# 	velocity.y = 0

	if not player:
		# 缓存玩家引用，避免每帧查找
		player = get_tree().get_first_node_in_group("Player")
		if not player:
			move_and_slide()
			return

	var dist_to_player_sq = global_position.distance_squared_to(player.global_position)
	
	# Optimization: Off-screen throttling
	# If far away and off-screen, reduce update frequency
	if not is_visible_on_screen and dist_to_player_sq > 400.0: # 20m^2
		frame_counter += 1
		if frame_counter % throttle_factor != 0:
			return # Skip this frame
		
		# Compensate delta for logic if needed, but for move_and_slide we rely on velocity
		# However, simply skipping move_and_slide means we move slower on average.
		# To fix this, we temporarily boost velocity for this frame.
		velocity.x *= throttle_factor
		velocity.z *= throttle_factor
		
		# Run Logic
		_run_state_logic(delta * throttle_factor, dist_to_player_sq)
		move_and_slide()
		
		# Restore velocity
		velocity.x /= throttle_factor
		velocity.z /= throttle_factor
	else:
		# Normal update
		_run_state_logic(delta, dist_to_player_sq)
		move_and_slide()

func _run_state_logic(delta, dist_to_player_sq):
	# Jump Logic Cooldown
	if jump_cooldown > 0:
		jump_cooldown -= delta
	
	# State Transition Logic
	match current_state:
		State.IDLE, State.WANDER:
			if dist_to_player_sq < detection_range_sq:
				current_state = State.CHASE
				# print("Player detected! Switching to CHASE.")
		State.CHASE:
			if dist_to_player_sq > lost_range_sq:
				current_state = State.IDLE
				wander_timer = wander_wait_time # Wait a bit before wandering
				# print("Player lost. Switching to IDLE.")

	# State Execution Logic
	match current_state:
		State.IDLE:
			_process_idle(delta)
		State.WANDER:
			# 优化：漫步时降低旋转平滑度计算频率或简化逻辑（此处保持原样，主要优化在碰撞和阴影）
			_process_wander(delta)
		State.CHASE:
			_process_chase(delta, dist_to_player_sq) # Pass squared distance

func _process_idle(delta):
	velocity.x = move_toward(velocity.x, 0, speed)
	velocity.z = move_toward(velocity.z, 0, speed)
	
	if playback:
		playback.travel("Idle")
		
	wander_timer -= delta
	if wander_timer <= 0:
		_pick_new_wander_target()
		current_state = State.WANDER

func _process_wander(delta):
	var dir = (wander_target - global_position).normalized()
	dir.y = 0
	
	velocity.x = dir.x * speed * 0.5 # Wander slower
	velocity.z = dir.z * speed * 0.5
	
	# Rotate towards target
	if dir.length() > 0.01:
		var target_rotation = atan2(dir.x, dir.z) + PI # 修正朝向：+PI 使其面向目标
		rotation.y = lerp_angle(rotation.y, target_rotation, rotation_speed * delta)
	
	if playback:
		playback.travel("Walk")
		animation_tree.set("parameters/Locomotion/Walk/TimeScale/scale", 0.8) # Slower walk anim
		
	# Check if reached target
	var dist = Vector2(global_position.x, global_position.z).distance_to(Vector2(wander_target.x, wander_target.z))
	if dist < 0.5:
		current_state = State.IDLE
		wander_timer = randf_range(1.0, 3.0)

func _pick_new_wander_target():
	var angle = randf() * TAU
	var radius = randf_range(2.0, wander_radius)
	var offset = Vector3(cos(angle), 0, sin(angle)) * radius
	wander_target = global_position + offset

func _process_chase(delta, dist_to_player_sq):
	if dist_to_player_sq > attack_range_sq:
		# Chase Move
		var dir = (player.global_position - global_position).normalized()
		dir.y = 0
		
		# 智能避障：如果前方受阻，寻找绕行方向
		# Optimization: Throttled avoidance check
		avoidance_frame_count += 1
		if avoidance_frame_count >= avoidance_interval:
			avoidance_frame_count = 0
			# Only update avoidance direction every few frames
			var new_dir = _apply_obstacle_avoidance(dir)
			
			# Smoothly blend if needed, or just set it
			# If avoidance kicks in (direction changed), use it
			if new_dir != dir:
				cached_avoidance_dir = new_dir
			else:
				cached_avoidance_dir = Vector3.ZERO # No avoidance needed
		
		# If we have a cached avoidance direction, use it
		if cached_avoidance_dir != Vector3.ZERO:
			# Slowly blend back to target if cached dir is old? 
			# For now, just use it. Maybe blend with desired dir?
			# Simple approach: if cached is valid, mix it
			dir = cached_avoidance_dir
		
		velocity.x = dir.x * speed
		velocity.z = dir.z * speed
		
		# Rotate towards move direction
		if dir.length() > 0.1:
			var move_rotation = atan2(dir.x, dir.z) + PI
			rotation.y = lerp_angle(rotation.y, move_rotation, rotation_speed * delta)
		
		# Jump Check
		if is_on_floor() and jump_cooldown <= 0:
			# 如果目标比我高，或者前方有障碍物（简单高度判定）
			if player.global_position.y > global_position.y + 1.0:
				velocity.y = jump_velocity
				jump_cooldown = jump_interval
				if playback and jump_anim != "":
					playback.travel("Jump")
			else:
				# Also check for low obstacles periodically
				# Reuse avoidance counter or separate one? Use same for perf.
				if avoidance_frame_count == 0:
					if _check_jumpable_obstacle(dir):
						velocity.y = jump_velocity
						jump_cooldown = jump_interval
						if playback and jump_anim != "":
							playback.travel("Jump")
		
		if playback:
			# Don't override jump animation if we are in the air
			if is_on_floor():
				playback.travel("Walk")
				animation_tree.set("parameters/Locomotion/Walk/TimeScale/scale", 1.0)
	else:
		# Attack Stay
		velocity.x = move_toward(velocity.x, 0, speed)
		velocity.z = move_toward(velocity.z, 0, speed)
		
		# Face player even when attacking
		var dir = (player.global_position - global_position).normalized()
		var target_rotation = atan2(dir.x, dir.z) + PI # 修正朝向
		rotation.y = lerp_angle(rotation.y, target_rotation, rotation_speed * delta)
		
		if playback:
			playback.travel("Idle")
		
		var time = Time.get_ticks_msec() / 1000.0
		if time - last_attack_time > attack_cooldown and attack_anim != "":
			_perform_attack()
			last_attack_time = time

func _apply_obstacle_avoidance(desired_dir: Vector3) -> Vector3:
	var space_state = get_world_3d().direct_space_state
	# 从腰部高度发射射线，避免打到地面
	var from_pos = global_position + Vector3(0, 1.0, 0) 
	
	# 1. 检查正前方
	if not _cast_ray(space_state, from_pos, desired_dir, avoidance_ray_length):
		return desired_dir
	
	# 2. 如果受阻，尝试左右探测 (30, 60, 90度)
	# 左右交替探测
	var check_angles = [30.0, -30.0, 60.0, -60.0, 90.0, -90.0]
	
	for angle in check_angles:
		var rot_dir = desired_dir.rotated(Vector3.UP, deg_to_rad(angle))
		# 侧面探测距离可以稍微短一点
		if not _cast_ray(space_state, from_pos, rot_dir, avoidance_ray_length * 0.9): 
			return rot_dir
			
	# 如果都被堵死，保持原方向（依靠物理滑行）
	return desired_dir

func _check_jumpable_obstacle(dir: Vector3) -> bool:
	# 仅在移动时检测
	if dir.length_squared() < 0.01:
		return false
		
	var space_state = get_world_3d().direct_space_state
	var forward_dist = 1.5 # 检测前方距离
	
	# 1. 膝盖高度射线 (检测是否有障碍)
	var low_from = global_position + Vector3(0, 0.5, 0)
	var low_hit = _cast_ray(space_state, low_from, dir, forward_dist)
	
	# 2. 头部高度射线 (检测障碍是否够低，可以跳过)
	var high_from = global_position + Vector3(0, 1.8, 0) # 稍微高一点
	var high_hit = _cast_ray(space_state, high_from, dir, forward_dist)
	
	# 如果下方有障碍，但上方没有，说明是矮墙/栅栏，可以跳跃
	return low_hit and not high_hit

func _cast_ray(space_state, from, dir, length) -> bool:
	var to_pos = from + dir * length
	var query = PhysicsRayQueryParameters3D.create(from, to_pos)
	query.exclude = [self.get_rid()] 
	if player:
		query.exclude.append(player.get_rid())
		
	# 这里会检测所有 PhysicsBody (包括静态环境)，从而实现避障
	var result = space_state.intersect_ray(query)
	return result.size() > 0

func _perform_attack():
	if attack_node:
		attack_node.animation = attack_anim
		animation_tree.set("parameters/AttackShot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
		
		# 延迟造成伤害
		get_tree().create_timer(0.5).timeout.connect(func():
			if player:
				var dist = global_position.distance_to(player.global_position)
				# print("Debug: Enemy Attack Check. Dist: ", dist, " Range: ", attack_range + 1.0)
				if player.has_method("take_damage") and dist < attack_range + 1.0:
					print("Enemy hitting player with damage: ", attack_damage)
					player.take_damage(attack_damage)
		)

func take_damage(amount: int):
	if is_dying: return # Ignore damage if already dying
	
	health -= amount
	if health < 0:
		health = 0
	print(name + " took damage! Health: ", health)
	
	if health_label:
		health_label.text = "HP: " + str(health) + "/" + str(max_health)
	
	if health <= 0:
		_die()
	else:
		if react_anim != "" and hit_node:
			print("Playing React Anim: ", react_anim)
			animation_tree.set("parameters/HitShot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
		else:
			print("No react anim found or hit_node missing")

func _die():
	if is_dying: return
	is_dying = true
	
	# Add score to player
	if player and player.has_method("add_score"):
		player.add_score(50)
		print("Enemy killed! Player score +50")
	
	set_physics_process(false)
	# 禁用碰撞
	var col = get_node_or_null("CollisionShape3D")
	if col: col.disabled = true
	
	# 从敌人组移除，防止被再次搜索到
	remove_from_group("Enemies")
	
	if death_anim != "":
		animation_tree.active = false
		if ap: ap.play(death_anim)
		
	# 等待动画播放完移除
	await get_tree().create_timer(2.0).timeout
	queue_free()

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
	
	# 1. State Machine (Idle/Walk/Jump)
	var idle_node = AnimationNodeAnimation.new()
	idle_node.animation = idle_anim
	
	var walk_tree = AnimationNodeBlendTree.new()
	var walk_anim_node = AnimationNodeAnimation.new()
	walk_anim_node.animation = walk_anim
	var walk_timescale = AnimationNodeTimeScale.new()
	
	walk_tree.add_node("Anim", walk_anim_node)
	walk_tree.add_node("TimeScale", walk_timescale)
	walk_tree.connect_node("TimeScale", 0, "Anim")
	walk_tree.connect_node("output", 0, "TimeScale")
	
	sm.add_node("Idle", idle_node)
	sm.add_node("Walk", walk_tree)
	
	# Jump Node
	if jump_anim != "":
		var jump_node = AnimationNodeAnimation.new()
		jump_node.animation = jump_anim
		sm.add_node("Jump", jump_node)
		
		var tr_walk_jump = AnimationNodeStateMachineTransition.new()
		tr_walk_jump.xfade_time = 0.1
		sm.add_transition("Walk", "Jump", tr_walk_jump)
		
		var tr_jump_walk = AnimationNodeStateMachineTransition.new()
		tr_jump_walk.xfade_time = 0.2
		tr_jump_walk.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_AT_END
		sm.add_transition("Jump", "Walk", tr_jump_walk)
		
		var tr_idle_jump = AnimationNodeStateMachineTransition.new()
		tr_idle_jump.xfade_time = 0.1
		sm.add_transition("Idle", "Jump", tr_idle_jump)
		
		var tr_jump_idle = AnimationNodeStateMachineTransition.new()
		tr_jump_idle.xfade_time = 0.2
		tr_jump_idle.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_AT_END
		sm.add_transition("Jump", "Idle", tr_jump_idle)
	
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
	
	# 2. Attack OneShot
	oneshot.filter_enabled = false # 禁用过滤器，攻击时直接播放全身动画，大幅提升性能
	
	# 设置 Hit 动画
	hit_node.animation = react_anim
	hit_oneshot.filter_enabled = false # 受击全身
	
	root.add_node("Locomotion", sm)
	root.add_node("AttackShot", oneshot)
	root.add_node("AttackAnim", attack_node)
	
	root.add_node("HitShot", hit_oneshot)
	root.add_node("HitAnim", hit_node)
	
	root.connect_node("AttackShot", 0, "Locomotion")
	root.connect_node("AttackShot", 1, "AttackAnim")
	
	# 连接: HitShot -> AttackShot
	root.connect_node("HitShot", 0, "AttackShot")
	root.connect_node("HitShot", 1, "HitAnim")
	
	root.connect_node("output", 0, "HitShot")
	
	animation_tree.tree_root = root
	animation_tree.active = true
	
	playback = animation_tree.get("parameters/Locomotion/playback")


func _select_anim(list: Array, prefers: Array, avoids: Array) -> String:
	for name in list:
		var n = String(name).to_lower()
		var bad = false
		for a in avoids:
			if n.find(a) != -1:
				bad = true
				break
		if bad: continue
		for p in prefers:
			if n.find(p) != -1:
				return String(name)
	return ""

func _select_anim_priority(list: Array, prefers: Array, avoids: Array) -> String:
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
