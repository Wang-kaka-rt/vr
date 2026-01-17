@tool
extends EditorPlugin

const DEFAULT_PORT := 9080

var _panel: Control
var _port: SpinBox
var _allow_remote: CheckBox
var _start_button: Button
var _stop_button: Button
var _status: Label
var _log: TextEdit

var _server: TCPServer
var _clients: Dictionary = {}
var _next_client_id := 1
var _running := false


func _enter_tree() -> void:
	_build_ui()
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, _panel)
	_start(DEFAULT_PORT, false)
	set_process(true)


func _exit_tree() -> void:
	_stop()
	remove_control_from_docks(_panel)
	_panel.queue_free()
	set_process(false)


func _process(_delta: float) -> void:
	if !_running or _server == null:
		return
	while _server.is_connection_available():
		var stream := _server.take_connection()
		if stream == null:
			break
		var socket := WebSocketPeer.new()
		socket.supported_protocols = PackedStringArray(["json"])
		var accept_err := socket.accept_stream(stream)
		if accept_err != OK:
			_append_log("Handshake failed (%s)" % str(accept_err))
			continue
		var id := _next_client_id
		_next_client_id += 1
		_clients[id] = socket
		_append_log("Client connected: %s" % id)

	var disconnected: Array = []
	for id in _clients.keys():
		var socket := _clients[id] as WebSocketPeer
		if socket == null:
			disconnected.append(id)
			continue
		socket.poll()
		var state := socket.get_ready_state()
		if state == WebSocketPeer.STATE_OPEN:
			while socket.get_available_packet_count() > 0:
				var packet := socket.get_packet()
				var text := packet.get_string_from_utf8()
				_handle_text(int(id), text)
		elif state == WebSocketPeer.STATE_CLOSED:
			disconnected.append(id)

	for id in disconnected:
		_clients.erase(id)
		_append_log("Client disconnected: %s" % id)


func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.name = "Godot MCP"

	var row := HBoxContainer.new()
	var port_label := Label.new()
	port_label.text = "Port"
	row.add_child(port_label)

	_port = SpinBox.new()
	_port.min_value = 1
	_port.max_value = 65535
	_port.step = 1
	_port.value = DEFAULT_PORT
	_port.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_port)

	_allow_remote = CheckBox.new()
	_allow_remote.text = "Allow Remote"
	row.add_child(_allow_remote)
	root.add_child(row)

	var buttons := HBoxContainer.new()
	_start_button = Button.new()
	_start_button.text = "Start"
	_start_button.pressed.connect(func():
		_start(int(_port.value), _allow_remote.button_pressed)
	)
	buttons.add_child(_start_button)

	_stop_button = Button.new()
	_stop_button.text = "Stop"
	_stop_button.disabled = true
	_stop_button.pressed.connect(func():
		_stop()
	)
	buttons.add_child(_stop_button)
	root.add_child(buttons)

	_status = Label.new()
	_status.text = "Stopped"
	root.add_child(_status)

	_log = TextEdit.new()
	_log.readonly = true
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log.custom_minimum_size = Vector2(0, 220)
	root.add_child(_log)

	_panel = root


func _start(port: int, allow_remote: bool) -> void:
	_stop()
	_server = TCPServer.new()
	_clients.clear()
	_next_client_id = 1

	var bind_address := "*" if allow_remote else "127.0.0.1"
	var err := _server.listen(port, bind_address)
	if err != OK:
		_server = null
		_running = false
		_status.text = "Failed to listen (%s)" % str(err)
		_append_log("Failed to listen on %s:%s (%s)" % [bind_address, port, str(err)])
		_start_button.disabled = false
		_stop_button.disabled = true
		return

	_running = true
	_status.text = "Listening on %s:%s" % [bind_address, port]
	_append_log("Listening on %s:%s" % [bind_address, port])
	_start_button.disabled = true
	_stop_button.disabled = false


func _stop() -> void:
	_running = false
	for id in _clients.keys():
		var socket := _clients[id] as WebSocketPeer
		if socket != null:
			socket.close()
	_clients.clear()
	if _server != null:
		_server.stop()
		_server = null
	_status.text = "Stopped"
	if _start_button != null:
		_start_button.disabled = false
	if _stop_button != null:
		_stop_button.disabled = true


func _handle_text(sender_id: int, text: String) -> void:
	var parsed := JSON.parse_string(text)
	if parsed == null or typeof(parsed) != TYPE_DICTIONARY:
		_send_error(sender_id, "", "Invalid JSON")
		return

	var msg: Dictionary = parsed
	var cmd_type := str(msg.get("type", ""))
	var params := msg.get("params", {})
	var command_id := str(msg.get("commandId", ""))
	if cmd_type == "":
		_send_error(sender_id, command_id, "Missing command type")
		return

	var result := _dispatch(cmd_type, params)
	if result is Dictionary and result.has("__error"):
		_send_error(sender_id, command_id, str(result["__error"]))
		return

	_send_success(sender_id, command_id, result)


func _dispatch(cmd_type: String, params: Variant) -> Variant:
	match cmd_type:
		"ping":
			return {"pong": true}
		"get_project_info":
			return _get_project_info()
		"get_editor_state":
			return _get_editor_state()
		"get_selected_node":
			return _get_selected_node()
		"get_current_script":
			return _get_current_script()
		_:
			return {"__error": "Unsupported command: %s" % cmd_type}


func _get_project_info() -> Dictionary:
	var version_info := Engine.get_version_info()
	var edited_root := get_editor_interface().get_edited_scene_root()
	var current_scene := ""
	if edited_root != null:
		current_scene = str(edited_root.scene_file_path)

	return {
		"project_name": str(ProjectSettings.get_setting("application/config/name", "")),
		"project_version": str(ProjectSettings.get_setting("application/config/version", "")),
		"project_path": ProjectSettings.globalize_path("res://"),
		"godot_version": {
			"major": int(version_info.get("major", 0)),
			"minor": int(version_info.get("minor", 0)),
			"patch": int(version_info.get("patch", 0)),
		},
		"current_scene": current_scene if current_scene != "" else null,
	}


func _get_editor_state() -> Dictionary:
	var edited_root := get_editor_interface().get_edited_scene_root()
	var selection := get_editor_interface().get_selection()
	var selected_paths: Array = []
	if selection != null:
		for n in selection.get_selected_nodes():
			if n != null:
				selected_paths.append(str(n.get_path()))

	return {
		"scene_file_path": str(edited_root.scene_file_path) if edited_root != null else "",
		"selected_nodes": selected_paths,
	}


func _get_selected_node() -> Dictionary:
	var selection := get_editor_interface().get_selection()
	if selection == null:
		return {"selected": false}
	var nodes := selection.get_selected_nodes()
	if nodes.is_empty() or nodes[0] == null:
		return {"selected": false}
	var node: Node = nodes[0]
	return {
		"selected": true,
		"path": str(node.get_path()),
		"name": str(node.name),
		"type": str(node.get_class()),
	}


func _get_current_script() -> Dictionary:
	var selection := get_editor_interface().get_selection()
	if selection == null:
		return {"script_found": false}

	var nodes := selection.get_selected_nodes()
	for n in nodes:
		if n == null:
			continue
		if "script" in n and n.script != null:
			var script: Script = n.script
			var script_path := str(script.resource_path)
			var content := ""
			if script_path.begins_with("res://") and FileAccess.file_exists(script_path):
				var f := FileAccess.open(script_path, FileAccess.READ)
				if f != null:
					content = f.get_as_text()
			return {
				"script_found": true,
				"script_path": script_path,
				"content": content,
			}

	return {"script_found": false}


func _send_success(peer_id: int, command_id: String, result: Variant) -> void:
	var payload := {
		"status": "success",
		"result": result,
		"commandId": command_id,
	}
	_send(peer_id, payload)


func _send_error(peer_id: int, command_id: String, message: String) -> void:
	var payload := {
		"status": "error",
		"message": message,
		"commandId": command_id,
	}
	_send(peer_id, payload)


func _send(peer_id: int, payload: Dictionary) -> void:
	if _server == null:
		return
	var socket := _clients.get(peer_id, null) as WebSocketPeer
	if socket == null:
		return
	socket.send_text(JSON.stringify(payload))


func _append_log(line: String) -> void:
	if _log == null:
		return
	_log.text += line + "\n"
	_log.scroll_vertical = _log.get_line_count()
