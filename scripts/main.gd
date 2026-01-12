extends Node3D

const EnemyScript = preload("res://scripts/enemy.gd")
const TARGET_ENEMY_COUNT = 5
const SPAWN_CHECK_INTERVAL = 2.0
const DESPAWN_RANGE = 100.0 # 增大移除距离，防止频繁生成销毁

# Collectible Settings
const MAX_COLLECTIBLES = 20
const COLLECTIBLE_SPAWN_INTERVAL = 3.0
const CollectibleScript = preload("res://scripts/collectible.gd")
var collectible_count = 0
var score_label: Label
var level_label: Label
var current_level = 1
var level_popup_label: Label
var level_overlay: Control

var available_enemy_paths = []
var enemy_scenes = {} # 预加载的场景资源
var enemy_pool = [] # 敌人对象池
var active_enemy_count = 0 # 缓存当前敌人数量，减少遍历开销
var spawn_timer: Timer
var collectible_timer: Timer
var health_bar: ProgressBar
var game_over_ui: Control

func _ready():
	_try_enable_openxr()
	# _create_debug_ui() # Removed per user request
	_create_player_health_ui()
	_create_score_ui()
	_create_level_ui()
	_create_game_over_ui() # 预先创建但不显示
	
	# 性能优化：强制关闭阴影，极大减少GPU开销
	var light = get_node_or_null("DirectionalLight3D")
	if light:
		light.shadow_enabled = false
		light.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL # 使用最便宜的阴影模式
		light.light_cull_mask = 0xFFFFFFFF # 确保照亮所有层
		print("Shadows disabled for performance.")
	
	print("Current Rendering Driver: ", RenderingServer.get_video_adapter_name())
	print("Rendering Method: ", ProjectSettings.get_setting("rendering/renderer/rendering_method"))

	var env = get_node_or_null("ImportedScene")
	if env:
		# 延迟一帧处理碰撞，避免阻塞启动，并统计数量
		await get_tree().process_frame
		var count = _create_env_collision(env)
		print("Generated Collision Shapes: ", count)
		
		# Update debug label with collision count
		var debug_label = get_node_or_null("DebugCanvas/DebugLabel")
		if debug_label:
			debug_label.set_meta("collision_count", count)
	
	# Spawn Houses
	_spawn_houses()
	
	# Randomize Player Spawn Position
	var player = get_node_or_null("Player")
	if player:
		# Connect health signal
		if player.has_signal("health_changed"):
			player.health_changed.connect(_on_player_health_changed)
			# Initial update
			_on_player_health_changed(player.health, player.max_health)
			
		# Connect death signal
		if player.has_signal("player_died"):
			player.player_died.connect(_on_player_died)
			
		# Connect score signal
		if player.has_signal("score_changed"):
			player.score_changed.connect(_on_score_changed)
			
		# 确保玩家模型不会因为阴影设置导致性能问题
		var player_mesh = player.find_child("Model", true, false)
		if player_mesh:
			_optimize_mesh_shadows(player_mesh)

		var angle = randf() * TAU
		var radius = randf_range(0.0, 30.0)
		var offset = Vector3(cos(angle), 0, sin(angle)) * radius
		
		# Set initial position roughly
		player.global_position = Vector3(0, 10, 0) + offset 
		
		# Wait for physics to update collision shapes
		await get_tree().physics_frame
		await get_tree().physics_frame
		
		# Snap to ground
		_place_on_ground(player)
	
	# Prepare list of enemy models (exclude player)
	var new_enemies = [
		"res://scenes/Enemies/Mako.tscn",
		"res://scenes/Enemies/Skeleton.tscn",
		"res://scenes/Enemies/SkeletonHeadless.tscn"
	]
	
	for path in new_enemies:
		available_enemy_paths.append(path)
		if not enemy_scenes.has(path):
			enemy_scenes[path] = load(path)
			
	# for char_name in Global.CHARACTERS:
	# 	var path = Global.CHARACTERS[char_name]
	# 	# 确保玩家选择的角色不作为敌人出现
	# 	if path != Global.selected_character_path:
	# 		available_enemy_paths.append(path)
	# 		# 预加载资源，避免游戏过程中卡顿
	# 		if not enemy_scenes.has(path):
	# 			enemy_scenes[path] = load(path)
	
	# 启动预加载流程
	_prepopulate_pool()
	
	collectible_timer = Timer.new()
	collectible_timer.wait_time = COLLECTIBLE_SPAWN_INTERVAL
	collectible_timer.autostart = true
	collectible_timer.timeout.connect(_on_collectible_timer_timeout)
	add_child(collectible_timer)

func _try_enable_openxr() -> bool:
	if not (OS.has_feature("android") or OS.has_feature("xr")):
		return false
	
	var openxr_interface = XRServer.find_interface("OpenXR")
	if not openxr_interface:
		return false
	
	var ok = openxr_interface.initialize()
	if not ok:
		return false
	
	get_viewport().use_xr = true
	
	var xr_camera: Camera3D = get_node_or_null("Player/XROrigin3D/XRCamera3D")
	if xr_camera:
		xr_camera.current = true
	
	var third_person_camera: Camera3D = get_node_or_null("Player/Pivot/Camera3D")
	if third_person_camera:
		third_person_camera.current = false
	
	var root_camera: Camera3D = get_node_or_null("Camera3D")
	if root_camera:
		root_camera.current = false
	
	return true

func _spawn_houses():
	var house_configs = [
		{"path": "res://assets/人物/glTF/Environment_House1.gltf", "pos": Vector3(35, 0, -20), "rot": 0.0},
		{"path": "res://assets/人物/glTF/Environment_House2.gltf", "pos": Vector3(-30, 0, 45), "rot": PI/4},
		{"path": "res://assets/人物/glTF/Environment_House3.gltf", "pos": Vector3(-25, 0, -40), "rot": -PI/3}
	]
	
	print("Spawning houses...")
	for config in house_configs:
		var scene = load(config.path)
		if scene:
			var house = scene.instantiate()
			add_child(house)
			house.global_position = config.pos
			house.rotation.y = config.rot
			# Scale up houses to be larger than player
			house.scale = Vector3(3.0, 3.0, 3.0)
			
			# Generate collision (reuse env collision logic for optimization)
			_create_env_collision(house)
			
			# Snap to ground
			# Note: We need to wait a physics frame if we just added collision, 
			# but since we rely on existing terrain collision, it should be fine.
			# However, if the house itself has a floor that we just added collision to, 
			# _place_on_ground excludes 'house' so it won't hit itself.
			_place_on_ground(house)
		else:
			print("Failed to load house: ", config.path)

func _prepopulate_pool():
	print("Pre-populating enemy pool...")
	# 预生成比目标数量多一点，以备不时之需
	for i in range(TARGET_ENEMY_COUNT + 2):
		_create_enemy_to_pool()
		# 每生成一个暂停一帧，避免启动时卡死
		await get_tree().process_frame
	print("Enemy pool ready. Size: ", enemy_pool.size())
	
	# Setup Timer for continuous spawning
	spawn_timer = Timer.new()
	spawn_timer.wait_time = SPAWN_CHECK_INTERVAL
	spawn_timer.autostart = true
	spawn_timer.timeout.connect(_check_and_spawn_enemies)
	add_child(spawn_timer)
	
	# Initial spawn
	_check_and_spawn_enemies()

func _create_enemy_to_pool():
	if available_enemy_paths.is_empty():
		return
		
	var path = available_enemy_paths.pick_random()
	var enemy
	
	if path.ends_with(".tscn"):
		if enemy_scenes.has(path):
			enemy = enemy_scenes[path].instantiate()
			enemy.name = "Enemy_" + str(randi())
			var scale_factor = 3.5
			enemy.scale = Vector3.ONE * scale_factor
			enemy.add_to_group("Enemies")
			add_child(enemy)
	else:
		# Fallback for GLTF
		enemy = CharacterBody3D.new()
		enemy.name = "Enemy_" + str(randi())
		enemy.set_script(EnemyScript)
		enemy.add_to_group("Enemies")
		add_child(enemy)
		
		var col = CollisionShape3D.new()
		var shape = CapsuleShape3D.new()
		var scale_factor = 3.5
		shape.radius = 0.35 * scale_factor
		shape.height = 1.4 * scale_factor
		col.shape = shape
		col.position.y = 0.7 * scale_factor
		enemy.add_child(col)
		
		if enemy_scenes.has(path):
			var model = enemy_scenes[path].instantiate()
			model.name = "Model"
			model.scale = Vector3.ONE * scale_factor
			enemy.add_child(model)
			
	if enemy:
		var model = enemy.get_node_or_null("Model")
		if model:
			_optimize_mesh_shadows(model)
		
		# 将新生成的敌人直接放入对象池
		_despawn_enemy(enemy)

func _create_env_collision(root: Node) -> int:
	var count = 0
	# 获取所有子节点（副本），避免遍历时修改树结构导致问题
	var children = root.get_children()
	for child in children:
		# 1. 优先检查是否为花草/忽略物体
		var name_lower = child.name.to_lower()
		
		# 安全检查：如果名字包含地形关键词，强制保留碰撞
		var is_terrain = "terrain" in name_lower or "ground" in name_lower or "floor" in name_lower or "base" in name_lower
		
		# 移除 'meadow' 以防止误删地形
		var is_ignored = not is_terrain and ("grass" in name_lower or "flower" in name_lower or "plant" in name_lower or "fern" in name_lower or "bush" in name_lower or "leaf" in name_lower or "leaves" in name_lower or "foliage" in name_lower or "vegetation" in name_lower or "shrub" in name_lower or "weed" in name_lower or "detail" in name_lower or "decor" in name_lower or "mushroom" in name_lower or "daffodil" in name_lower or "sunflower" in name_lower or "hyacinth" in name_lower)
		
		if is_ignored:
			# 彻底清除已有的碰撞，并关闭阴影
			_clear_collision_recursive(child)
			continue

		# 2. 处理 MeshInstance3D
		if child is MeshInstance3D:
			# 优化：关闭阴影投射和接收
			child.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			
			var aabb = child.get_aabb()
			var size = aabb.get_longest_axis_size() * child.scale.length()
			
			# 极度激进优化：直接删除其他微小物体（非花草），减少 Draw Calls
			if size < 3.0:
				child.queue_free()
				continue
			
			# 对于剩余的大型物体，统一使用 Trimesh 碰撞
			# 优化：仅对真正需要阻挡的物体创建碰撞
			# 如果物体不是特别巨大（如地形），尝试使用凸包碰撞以提升性能
			if size < 20.0:
				child.create_convex_collision()
			else:
				child.create_trimesh_collision()
			
			# 优化碰撞层级，避免不必要的物理检测
			var static_body = child.get_child(child.get_child_count() - 1)
			if static_body is StaticBody3D:
				static_body.collision_layer = 1 # 仅在第1层
				static_body.collision_mask = 0  # 不检测任何东西
				# 凸包碰撞有时会生成多个 CollisionShape3D，这里假设 create_xxx_collision 只生成了一个 body 作为最后一个子节点
				
			count += 1
			
		# 3. 递归其他节点
		if child.get_child_count() > 0:
			count += _create_env_collision(child)
	return count

func _clear_collision_recursive(node: Node):
	# 如果是几何实例，关闭阴影
	if node is GeometryInstance3D:
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	# 如果是碰撞对象（如 StaticBody3D），禁用层级
	if node is CollisionObject3D:
		node.collision_layer = 0
		node.collision_mask = 0
	
	# 如果是碰撞形状，直接删除
	if node is CollisionShape3D or node is CollisionPolygon3D:
		node.queue_free()
	
	# 递归处理所有子节点
	for child in node.get_children():
		_clear_collision_recursive(child)

func _create_player_health_ui():
	var canvas = get_node_or_null("DebugCanvas")
	if not canvas:
		canvas = CanvasLayer.new()
		canvas.name = "DebugCanvas"
		add_child(canvas)
		
	var bar = ProgressBar.new()
	bar.name = "HealthBar"
	bar.min_value = 0
	bar.max_value = 10
	bar.value = 10
	bar.step = 1
	bar.show_percentage = true
	
	# Position top-left
	bar.position = Vector2(20, 20)
	bar.size = Vector2(200, 30)
	
	# Style
	var style_box = StyleBoxFlat.new()
	style_box.bg_color = Color(0.8, 0.1, 0.1) # Red
	bar.add_theme_stylebox_override("fill", style_box)
	
	canvas.add_child(bar)
	health_bar = bar

func _on_player_health_changed(current, max_val):
	if health_bar:
		health_bar.max_value = max_val
		health_bar.value = current
		# Change color if low
		if current < max_val * 0.3:
			var style = health_bar.get_theme_stylebox("fill")
			if style is StyleBoxFlat:
				style.bg_color = Color(1, 0, 0) # Bright Red
		else:
			var style = health_bar.get_theme_stylebox("fill")
			if style is StyleBoxFlat:
				style.bg_color = Color(0.2, 0.8, 0.2) # Green

func _create_score_ui():
	var canvas = get_node_or_null("DebugCanvas")
	if not canvas: return
	
	score_label = Label.new()
	score_label.name = "ScoreLabel"
	score_label.text = "Score: 0"
	score_label.position = Vector2(20, 60)
	score_label.add_theme_font_size_override("font_size", 24)
	score_label.add_theme_color_override("font_color", Color.GOLD)
	canvas.add_child(score_label)

func _on_score_changed(new_score):
	if score_label:
		score_label.text = "Score: " + str(new_score)
	_check_level_progression(new_score)

func _check_level_progression(score):
	var previous_level = current_level
	
	if current_level == 1 and score >= 100:
		current_level = 2
		_show_level_popup("LEVEL 2\nTarget: 200")
	elif current_level == 2 and score >= 200:
		current_level = 3
		_show_level_popup("LEVEL 3\nTarget: 500\nWARNING: Enemies Stronger!")
		_update_enemy_difficulty()
	elif current_level == 3 and score >= 500:
		_game_clear()
		
	if current_level != previous_level:
		_update_level_ui()

func _update_enemy_difficulty():
	# Level 3: Increase enemy damage to 40
	if current_level >= 3:
		print("Level 3 reached! Increasing enemy damage to 40.")
		get_tree().call_group("Enemies", "set", "attack_damage", 40)

func _game_clear():
	print("Game Clear!")
	if game_over_ui:
		var label = game_over_ui.find_child("TitleLabel", true, false)
		if label:
			label.text = "YOU WIN!"
			label.add_theme_color_override("font_color", Color.GREEN)
		
		var btn = game_over_ui.find_child("RestartButton", true, false)
		if btn:
			btn.text = "Returning to Menu..."
			btn.disabled = true
		
		game_over_ui.visible = true
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		get_tree().paused = true # Pause game on win
		
		# Return to Menu after 3 seconds (process_always=true to run while paused)
		await get_tree().create_timer(3.0, true).timeout
		get_tree().paused = false # Unpause before changing scene
		get_tree().change_scene_to_file("res://scenes/Menu.tscn")

func _create_level_ui():
	var canvas = get_node_or_null("DebugCanvas")
	if not canvas: return
	
	level_label = Label.new()
	level_label.name = "LevelLabel"
	level_label.position = Vector2(20, 100)
	level_label.add_theme_font_size_override("font_size", 24)
	level_label.add_theme_color_override("font_color", Color.CYAN)
	canvas.add_child(level_label)
	
	# Level Transition Overlay (Mask)
	level_overlay = Panel.new()
	level_overlay.name = "LevelOverlay"
	level_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	level_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.85) # Dark semi-transparent mask
	level_overlay.add_theme_stylebox_override("panel", style)
	level_overlay.modulate.a = 0 # Hidden by default
	canvas.add_child(level_overlay)
	
	# Level Popup Label (centered in overlay)
	level_popup_label = Label.new()
	level_popup_label.name = "LevelPopupLabel"
	# Center in overlay
	level_popup_label.anchor_left = 0.5
	level_popup_label.anchor_top = 0.5
	level_popup_label.anchor_right = 0.5
	level_popup_label.anchor_bottom = 0.5
	level_popup_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	level_popup_label.grow_vertical = Control.GROW_DIRECTION_BOTH
	
	level_popup_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	level_popup_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	level_popup_label.add_theme_font_size_override("font_size", 64)
	level_popup_label.add_theme_color_override("font_color", Color.GOLD)
	level_overlay.add_child(level_popup_label)
	
	_update_level_ui()

func _update_level_ui():
	if level_label:
		var target = 0
		if current_level == 1: target = 100
		elif current_level == 2: target = 200
		elif current_level == 3: target = 500
		
		level_label.text = "Level: %d | Target: %d" % [current_level, target]

func _show_level_popup(text):
	if level_overlay and level_popup_label:
		level_popup_label.text = text
		
		# Animation
		var tween = create_tween()
		tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
		
		# Fade In
		tween.tween_property(level_overlay, "modulate:a", 1.0, 0.5)
		tween.tween_interval(2.5) # Show for 2.5 seconds
		# Fade Out
		tween.tween_property(level_overlay, "modulate:a", 0.0, 0.5)


func _create_game_over_ui():
	var canvas = get_node_or_null("DebugCanvas")
	if not canvas: return
	
	var panel = Panel.new()
	panel.name = "GameOverPanel"
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.visible = false
	
	# 半透明黑色背景
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.7)
	panel.add_theme_stylebox_override("panel", style)
	
	# Use a CenterContainer to center content
	var center_container = CenterContainer.new()
	center_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.add_child(center_container)
	
	# Use a VBoxContainer for vertical layout
	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 40) # Space between label and button
	center_container.add_child(vbox)
	
	# 标题
	var label = Label.new()
	label.name = "TitleLabel"
	label.text = "GAME OVER"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 64)
	label.add_theme_color_override("font_color", Color.RED)
	vbox.add_child(label)
	
	# 重新开始按钮
	var btn = Button.new()
	btn.text = "Restart Game"
	btn.custom_minimum_size = Vector2(200, 60)
	btn.add_theme_font_size_override("font_size", 32)
	btn.pressed.connect(_restart_game)
	vbox.add_child(btn)
	
	canvas.add_child(panel)
	game_over_ui = panel

func _on_player_died():
	print("Main: Player died signal received.")
	
	# Wait for death animation to finish (approx 2.5 seconds)
	await get_tree().create_timer(2.5).timeout
	
	if game_over_ui:
		game_over_ui.visible = true
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE) # 释放鼠标
		# 暂停游戏逻辑？或者只是显示 UI
		# get_tree().paused = true # 如果需要暂停整个游戏

func _restart_game():
	get_tree().reload_current_scene()

func _create_debug_ui():
	var canvas = CanvasLayer.new()
	canvas.name = "DebugCanvas"
	add_child(canvas)
	
	var label = Label.new()
	label.name = "DebugLabel"
	label.position = Vector2(20, 20)
	label.modulate = Color(0, 1, 0) # Green text
	canvas.add_child(label)
	
	# Create a timer to update UI
	var timer = Timer.new()
	timer.wait_time = 0.5
	timer.autostart = true
	timer.timeout.connect(func():
		var adapter = RenderingServer.get_video_adapter_name()
		var fps = Engine.get_frames_per_second()
		var count = active_enemy_count
		var driver = ProjectSettings.get_setting("rendering/renderer/rendering_method")
		var col_count = label.get_meta("collision_count", 0)
		var node_count = get_tree().get_node_count()
		label.text = "FPS: %d\nGPU: %s\nDriver: %s\nEnemies: %d\nColliders: %d\nTotal Nodes: %d" % [fps, adapter, driver, count, col_count, node_count]
	)
	add_child(timer)

func _check_and_spawn_enemies():
	var player = get_node_or_null("Player")
	var player_pos = Vector3.ZERO
	
	if player:
		if not player.is_in_group("Player"):
			player.add_to_group("Player")
		player_pos = player.global_position
	
	var current_enemies = get_tree().get_nodes_in_group("Enemies")
	active_enemy_count = current_enemies.size() # 更新计数
	
	# Check for despawn (too far from player)
	for enemy in current_enemies:
		if player and enemy.global_position.distance_to(player_pos) > DESPAWN_RANGE:
			_despawn_enemy(enemy)
	
	if active_enemy_count < TARGET_ENEMY_COUNT:
		var needed = TARGET_ENEMY_COUNT - active_enemy_count
		for i in range(needed):
			_spawn_single_enemy()
			# 分帧生成，避免瞬间卡顿
			await get_tree().process_frame

func _despawn_enemy(enemy):
	enemy.remove_from_group("Enemies")
	enemy.process_mode = Node.PROCESS_MODE_DISABLED
	enemy.visible = false
	enemy.global_position = Vector3(0, -500, 0) # Move far away
	# 重置状态，防止保留之前的仇恨等
	if enemy.has_method("reset_state"):
		enemy.reset_state()
	enemy_pool.append(enemy)
	active_enemy_count -= 1

func _spawn_single_enemy():
	if available_enemy_paths.is_empty():
		return
		
	var player = get_node_or_null("Player")
	var player_pos = Vector3.ZERO
	if player:
		player_pos = player.global_position
		
	# Random position around player
	var angle = randf() * TAU
	# 增大生成半径，避免生成在玩家脸上或过于拥挤
	var radius = randf_range(30.0, 60.0)
	var offset = Vector3(cos(angle), 0, sin(angle)) * radius
	var spawn_pos = player_pos + offset
	
	# Optimization: Removed O(N) overlap check. Physics will handle separation naturally.
	
	var enemy
	
	# Try to reuse from pool
	if not enemy_pool.is_empty():
		enemy = enemy_pool.pop_back()
	else:
		# Pool empty, create new one
		_create_enemy_to_pool()
		if not enemy_pool.is_empty():
			enemy = enemy_pool.pop_back()
			
	if enemy:
		enemy.process_mode = Node.PROCESS_MODE_INHERIT
		enemy.visible = true
		if not enemy.is_in_group("Enemies"):
			enemy.add_to_group("Enemies")
			
		# Set difficulty based on level
		var dmg = 10
		if current_level >= 3:
			dmg = 30
		enemy.set("attack_damage", dmg)
		
		active_enemy_count += 1
		
		# Set position
		enemy.global_position = spawn_pos
		_place_on_ground(enemy)

func _optimize_mesh_shadows(node: Node):
	if node is GeometryInstance3D:
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	
	for child in node.get_children():
		_optimize_mesh_shadows(child)

func _place_on_ground(node: Node3D):
	var space_state = get_world_3d().direct_space_state
	var from = node.global_position + Vector3(0, 10, 0)
	var to = node.global_position + Vector3(0, -100, 0)
	var params = PhysicsRayQueryParameters3D.create(from, to)
	params.exclude = [node]
	params.collide_with_bodies = true
	params.collide_with_areas = true
	
	var result = space_state.intersect_ray(params)
	if result.has("position"):
		# 稍微抬高一点，防止碰撞体嵌入地面导致物理抖动
		node.global_position = result["position"] + Vector3(0, 0.1, 0)

func _on_collectible_timer_timeout():
	# print("Collectible timer timeout. Count: ", collectible_count, "/", MAX_COLLECTIBLES)
	if collectible_count < MAX_COLLECTIBLES:
		_spawn_collectible()

func _spawn_collectible():
	var rand = randf()
	var type = 0
	var path = ""
	var scale_val = 2.0
	
	# Probability Distribution
	if rand < 0.30: # 30% Money Bag (+5 Score)
		type = 0
		path = "res://assets/人物/glTF/Prop_GoldBag.gltf"
		scale_val = 5.0
	elif rand < 0.55: # 25% Coin Pile (+10 Score)
		type = 1
		path = "res://assets/人物/glTF/Prop_Coins.gltf"
		scale_val = 5.0
	elif rand < 0.70: # 15% Gold Chest (+20 Score)
		type = 2
		path = "res://assets/人物/glTF/Prop_Chest_Gold.gltf"
		scale_val = 4.0
	elif rand < 0.90: # 20% Emerald (+10 HP)
		type = 3
		path = "res://assets/人物/glTF/UI_Gem_Green.gltf"
		scale_val = 8.0 # Gems are likely small
	else: # 10% Sapphire (+20 HP)
		type = 4
		path = "res://assets/人物/glTF/UI_Gem_Blue.gltf"
		scale_val = 8.0
	
	var scene = load(path)
	if not scene:
		print("Failed to load collectible: ", path)
		return

	var col = Area3D.new()
	col.name = "Collectible_" + str(randi())
	col.set_script(CollectibleScript)
	col.set("type", type)
	add_child(col)
	
	# Add Model
	var model = scene.instantiate()
	model.scale = Vector3.ONE * scale_val
	col.add_child(model)
	
	# Add Collision Shape
	var shape = CollisionShape3D.new()
	shape.shape = SphereShape3D.new()
	shape.shape.radius = 2.0 # Generous hit radius
	col.add_child(shape)
	
	# Random Position
	var player = get_node_or_null("Player")
	var center = Vector3.ZERO
	if player: center = player.global_position
	
	var angle = randf() * TAU
	var radius = randf_range(5.0, 15.0) # Reduce radius to make them easier to find for testing
	col.global_position = center + Vector3(cos(angle), 0, sin(angle)) * radius
	
	# Snap to ground then float
	_place_on_ground(col)
	col.position.y += 0.5 # Lower floating height per user request (was 1.5)
	
	# Initialize floating
	col.start_floating()
	
	print("Spawned collectible: ", path, " at ", col.global_position)
	
	collectible_count += 1
	col.tree_exited.connect(func(): collectible_count -= 1)
