# --- GameUI.gd ---
extends CanvasLayer

# References to the UI elements
@onready var player_hp_bar: ProgressBar = $PlayerHPBar
@onready var player_stamina_bar: ProgressBar = $PlayerStaminaBar
@onready var boss_hp_bar: ProgressBar = $BossHPBar

# References to the characters
var player_ref: Node = null
var current_boss_ref: Node = null
var player_connected: bool = false # Flag to prevent duplicate connections

func _ready() -> void:
	# Add self to the 'game_ui' group so others can find it
	add_to_group("game_ui")
	# Hide boss bar initially
	boss_hp_bar.visible = false
	# Set initial values just in case connection takes time
	if is_instance_valid(player_hp_bar): player_hp_bar.value = player_hp_bar.max_value
	if is_instance_valid(player_stamina_bar): player_stamina_bar.value = player_stamina_bar.max_value


func _process(delta: float) -> void:
	# Try connecting to player only if not already connected
	if not player_connected:
		attempt_player_connection()


# Try finding and connecting to the player node
func attempt_player_connection() -> void:
	player_ref = get_tree().get_first_node_in_group("player")
	if is_instance_valid(player_ref):
		print("GAME UI: Found player node. Attempting connections...")
		# --- Connect signals using Callable, checking if already connected ---
		if not player_ref.hp_changed.is_connected(Callable(self,"update_player_hp")):
			var err_hp = player_ref.hp_changed.connect(Callable(self, "update_player_hp"))
			if err_hp != OK: print("GAME UI ERROR: Failed to connect hp_changed signal:", err_hp)

		if not player_ref.stamina_changed.is_connected(Callable(self,"update_player_stamina")):
			var err_stamina = player_ref.stamina_changed.connect(Callable(self, "update_player_stamina"))
			if err_stamina != OK: print("GAME UI ERROR: Failed to connect stamina_changed signal:", err_stamina)

		# Initialize UI with player's starting values (ensure properties exist)
		if player_ref.has_method("get_current_hp"): # Safer check if properties aren't guaranteed
			update_player_hp(player_ref.get_current_hp(), player_ref.max_hp)
		elif "current_hp" in player_ref:
			update_player_hp(player_ref.current_hp, player_ref.max_hp)

		if player_ref.has_method("get_current_stamina"):
			update_player_stamina(player_ref.get_current_stamina(), player_ref.max_stamina)
		elif "current_stamina" in player_ref:
			update_player_stamina(player_ref.current_stamina, player_ref.max_stamina)

		print("GAME UI: Player connected and UI potentially initialized.")
		player_connected = true # Mark as connected even if init fails, stop trying


# Function called by the boss when it's ready
func register_boss(boss_node: Node) -> void:
	if not is_instance_valid(boss_node):
		print("GAME UI Error: Attempted to register invalid boss node.")
		return

	current_boss_ref = boss_node
	# Ensure boss node has the properties/methods before accessing
	if "max_hp" in boss_node and "current_hp" in boss_node:
		boss_hp_bar.max_value = boss_node.max_hp
		boss_hp_bar.value = boss_node.current_hp
		boss_hp_bar.visible = true
		print("GAME UI: Boss registered:", boss_node.name)
	else:
		print("GAME UI ERROR: Registered boss node missing hp properties!")
		return # Don't connect signals if properties missing

	# --- Connect boss signals using Callable ---
	if "hp_changed" in boss_node and not boss_node.hp_changed.is_connected(Callable(self,"update_boss_hp")):
		var err_b_hp = boss_node.hp_changed.connect(Callable(self, "update_boss_hp"))
		if err_b_hp != OK: print("GAME UI ERROR: Failed to connect boss hp_changed signal:", err_b_hp)

	if "died" in boss_node and not boss_node.died.is_connected(Callable(self,"hide_boss_hp")):
		var err_b_died = boss_node.died.connect(Callable(self, "hide_boss_hp"))
		if err_b_died != OK: print("GAME UI ERROR: Failed to connect boss died signal:", err_b_died)


func hide_boss_hp() -> void:
	boss_hp_bar.visible = false
	# print("GAME UI: Hiding boss HP bar.")
	current_boss_ref = null


# --- Update Functions (Check node validity) ---
func update_player_hp(current_value: float, max_value: float) -> void:
	if is_instance_valid(player_hp_bar):
		player_hp_bar.max_value = max_value
		player_hp_bar.value = current_value
		# print("UI Updated Player HP:", current_value, "/", max_value) # Debug if needed

func update_player_stamina(current_value: float, max_value: float) -> void:
	if is_instance_valid(player_stamina_bar):
		player_stamina_bar.max_value = max_value
		player_stamina_bar.value = current_value
		# print("UI Updated Player Stamina:", current_value, "/", max_value) # Debug if needed

func update_boss_hp(current_value: float, max_value: float) -> void:
	if is_instance_valid(boss_hp_bar) and boss_hp_bar.visible:
		boss_hp_bar.max_value = max_value
		boss_hp_bar.value = current_value
		# print("UI Updated Boss HP:", current_value, "/", max_value) # Debug if needed
