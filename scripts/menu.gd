extends Control

@onready var start_screen = $StartScreen
@onready var selection_screen = $SelectionScreen

func _ready():
	start_screen.visible = true
	selection_screen.visible = false

func _on_start_button_pressed():
	start_screen.visible = false
	selection_screen.visible = true

func _on_character_selected(character_name):
	if Global.CHARACTERS.has(character_name):
		Global.selected_character_path = Global.CHARACTERS[character_name]
		get_tree().change_scene_to_file("res://scenes/Main.tscn")

func _on_henry_pressed():
	_on_character_selected("Henry")

func _on_anne_pressed():
	_on_character_selected("Anne")

func _on_barbarossa_pressed():
	_on_character_selected("CaptainBarbarossa")
