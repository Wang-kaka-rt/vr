extends Area3D

enum Type {
	MONEY_BAG,
	COIN_PILE,
	GOLD_CHEST,
	EMERALD,
	SAPPHIRE
}

var type: int = Type.MONEY_BAG
var value: int = 0
var float_speed: float = 2.0
var float_height: float = 0.5
var initial_y: float = 0.0
var time_accum: float = 0.0
var is_floating: bool = false

func _ready():
	# Ensure we check for physics overlap
	monitorable = true
	monitoring = true
	
	# Connect signal
	body_entered.connect(_on_body_entered)
	
	# Rotate randomly for variety
	rotation.y = randf() * TAU

func start_floating():
	initial_y = position.y
	is_floating = true

func _process(delta):
	if is_floating:
		# Floating animation
		time_accum += delta * float_speed
		position.y = initial_y + sin(time_accum) * float_height * 0.5
	
	# Rotate slowly
	rotation.y += delta * 1.0

func _on_body_entered(body):
	if body.is_in_group("Player"):
		apply_effect(body)
		queue_free()

func apply_effect(player):
	match type:
		Type.MONEY_BAG:
			if player.has_method("add_score"):
				player.add_score(5)
				print("Collected Money Bag: +5 Score")
		Type.COIN_PILE:
			if player.has_method("add_score"):
				player.add_score(10)
				print("Collected Coin Pile: +10 Score")
		Type.GOLD_CHEST:
			if player.has_method("add_score"):
				player.add_score(20)
				print("Collected Gold Chest: +20 Score")
		Type.EMERALD:
			if player.has_method("heal"):
				player.heal(10)
				print("Collected Emerald: +10 Health")
		Type.SAPPHIRE:
			if player.has_method("heal"):
				player.heal(20)
				print("Collected Sapphire: +20 Health")
