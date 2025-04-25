# --- GameUI.gd ---
extends CanvasLayer

# References to the UI elements (Ensure these paths are correct in your scene)
@onready var player_hp_bar: ProgressBar = $PlayerHPBar
@onready var player_stamina_bar: ProgressBar = $PlayerStaminaBar
@onready var boss_hp_bar: ProgressBar = $BossHPBar

# Internal state
var player_ref: Node = null
var current_boss_ref: Node = null
var player_signals_connected: bool = false # Flag to track player signal connection status
var boss_signals_connected: bool = false # Flag for boss signal connection

func _ready() -> void:
	# Add self to the 'game_ui' group so others can find it
	add_to_group("game_ui")

	# Validate UI element references
	if not is_instance_valid(player_hp_bar): printerr("ERROR (GameUI): PlayerHPBar node not found!")
	if not is_instance_valid(player_stamina_bar): printerr("ERROR (GameUI): PlayerStaminaBar node not found!")
	if not is_instance_valid(boss_hp_bar):
		printerr("ERROR (GameUI): BossHPBar node not found!")
	else:
		boss_hp_bar.visible = false # Hide boss bar initially

	# Set initial values to prevent empty bars at start
	if is_instance_valid(player_hp_bar): player_hp_bar.value = player_hp_bar.max_value
	if is_instance_valid(player_stamina_bar): player_stamina_bar.value = player_stamina_bar.max_value

	# Start trying to find the player immediately
	attempt_player_connection()

func _process(_delta: float) -> void:
	# Continuously try connecting to the player if not already connected
	# This handles cases where the player might spawn later
	if not player_signals_connected:
		attempt_player_connection()

# Try finding and connecting to the player node
func attempt_player_connection() -> void:
	# Avoid searching if already connected
	if player_signals_connected: return

	player_ref = get_tree().get_first_node_in_group("player")

	if is_instance_valid(player_ref):
		# print("DEBUG (GameUI): Found player node. Attempting connections...") # Debug

		# --- Connect Signals Safely ---
		var hp_connected = false
		var stamina_connected = false

		if player_ref.has_signal("hp_changed"):
			if not player_ref.hp_changed.is_connected(Callable(self,"update_player_hp")):
				var err_hp = player_ref.hp_changed.connect(Callable(self, "update_player_hp"))
				if err_hp == OK: hp_connected = true
				else: printerr("ERROR (GameUI): Failed to connect player hp_changed signal:", err_hp)
			else: hp_connected = true # Already connected
		else: printerr("ERROR (GameUI): Player node missing 'hp_changed' signal!")


		if player_ref.has_signal("stamina_changed"):
			if not player_ref.stamina_changed.is_connected(Callable(self,"update_player_stamina")):
				var err_stamina = player_ref.stamina_changed.connect(Callable(self, "update_player_stamina"))
				if err_stamina == OK: stamina_connected = true
				else: printerr("ERROR (GameUI): Failed to connect player stamina_changed signal:", err_stamina)
			else: stamina_connected = true # Already connected
		else: printerr("ERROR (GameUI): Player node missing 'stamina_changed' signal!")

		# If both signals connected successfully, mark as connected and initialize UI
		if hp_connected and stamina_connected:
			player_signals_connected = true
			# print("DEBUG (GameUI): Player signals connected.") # Debug
			# Initialize UI with player's starting values using safe checks
			initialize_player_ui()
		else:
			# print("DEBUG (GameUI): Failed to connect all required player signals.") # Debug
			player_ref = null # Clear ref if connections failed

	# else: Player node not found yet, will try again in _process


# Initialize UI elements with player's current stats
func initialize_player_ui() -> void:
	if not is_instance_valid(player_ref): return

	# Use getters if available, otherwise access properties directly (less safe)
	var initial_hp = 0
	var initial_max_hp = 100
	var initial_stamina = 0.0
	var initial_max_stamina = 100.0

	if player_ref.has_method("get_current_hp") and "max_hp" in player_ref:
		initial_hp = player_ref.get_current_hp()
		initial_max_hp = player_ref.max_hp
	elif "current_hp" in player_ref and "max_hp" in player_ref:
		initial_hp = player_ref.current_hp
		initial_max_hp = player_ref.max_hp
	else: printerr("WARNING (GameUI): Could not get initial HP values from player.")

	if player_ref.has_method("get_current_stamina") and "max_stamina" in player_ref:
		initial_stamina = player_ref.get_current_stamina()
		initial_max_stamina = float(player_ref.max_stamina)
	elif "current_stamina" in player_ref and "max_stamina" in player_ref:
		initial_stamina = player_ref.current_stamina
		initial_max_stamina = float(player_ref.max_stamina)
	else: printerr("WARNING (GameUI): Could not get initial Stamina values from player.")

	update_player_hp(initial_hp, initial_max_hp)
	update_player_stamina(initial_stamina, initial_max_stamina)
	# print("DEBUG (GameUI): Initialized player UI.") # Debug


# Function called by the boss when it's ready (e.g., in its _ready function)
func register_boss(boss_node: Node) -> void:
	# Disconnect from previous boss if any
	if is_instance_valid(current_boss_ref):
		_disconnect_boss_signals()

	# Validate the new boss node
	if not is_instance_valid(boss_node):
		print("ERROR (GameUI): Attempted to register invalid boss node.")
		current_boss_ref = null
		boss_signals_connected = false
		if is_instance_valid(boss_hp_bar): boss_hp_bar.visible = false
		return

	current_boss_ref = boss_node
	boss_signals_connected = false # Reset connection flag for new boss
	print("INFO (GameUI): Boss registered:", boss_node.name)

	# --- Connect boss signals using Callable and safety checks ---
	var boss_hp_connected = false
	var boss_died_connected = false

	if current_boss_ref.has_signal("hp_changed"):
		if not current_boss_ref.hp_changed.is_connected(Callable(self,"update_boss_hp")):
			var err_b_hp = current_boss_ref.hp_changed.connect(Callable(self, "update_boss_hp"))
			if err_b_hp == OK: boss_hp_connected = true
			else: printerr("ERROR (GameUI): Failed to connect boss hp_changed signal:", err_b_hp)
		else: boss_hp_connected = true # Already connected
	else: printerr("ERROR (GameUI): Registered boss missing 'hp_changed' signal!")

	if current_boss_ref.has_signal("died"):
		if not current_boss_ref.died.is_connected(Callable(self,"_on_boss_died")): # Connect to internal handler
			var err_b_died = current_boss_ref.died.connect(Callable(self, "_on_boss_died"))
			if err_b_died == OK: boss_died_connected = true
			else: printerr("ERROR (GameUI): Failed to connect boss died signal:", err_b_died)
		else: boss_died_connected = true # Already connected
	else: printerr("ERROR (GameUI): Registered boss missing 'died' signal!")

	# If signals connected, initialize and show bar
	if boss_hp_connected and boss_died_connected:
		boss_signals_connected = true
		# print("DEBUG (GameUI): Boss signals connected.") # Debug
		initialize_boss_ui() # Initialize UI with boss stats
		if is_instance_valid(boss_hp_bar): boss_hp_bar.visible = true
	else:
		# print("DEBUG (GameUI): Failed to connect all required boss signals.") # Debug
		current_boss_ref = null # Clear ref if connections failed
		if is_instance_valid(boss_hp_bar): boss_hp_bar.visible = false


func initialize_boss_ui():
	if not is_instance_valid(current_boss_ref): return
	if not is_instance_valid(boss_hp_bar): return

	var initial_boss_hp = 0
	var initial_boss_max_hp = 100

	# Safely get initial values
	if "current_hp" in current_boss_ref and "max_hp" in current_boss_ref:
		initial_boss_hp = current_boss_ref.current_hp
		initial_boss_max_hp = current_boss_ref.max_hp
		update_boss_hp(initial_boss_hp, initial_boss_max_hp)
		# print("DEBUG (GameUI): Initialized boss UI.") # Debug
	else:
		printerr("WARNING (GameUI): Registered boss missing hp properties for UI initialization!")
		boss_hp_bar.visible = false # Hide bar if stats are missing


# Internal handler for when the boss 'died' signal is received
func _on_boss_died() -> void:
	print("INFO (GameUI): Boss died signal received.")
	if is_instance_valid(boss_hp_bar):
		boss_hp_bar.visible = false
	_disconnect_boss_signals() # Disconnect signals from the dead boss
	current_boss_ref = null
	boss_signals_connected = false

# Helper to disconnect signals from the current boss
func _disconnect_boss_signals() -> void:
	if is_instance_valid(current_boss_ref):
		if current_boss_ref.has_signal("hp_changed") and current_boss_ref.hp_changed.is_connected(Callable(self,"update_boss_hp")):
			current_boss_ref.hp_changed.disconnect(Callable(self, "update_boss_hp"))
		if current_boss_ref.has_signal("died") and current_boss_ref.died.is_connected(Callable(self,"_on_boss_died")):
			current_boss_ref.died.disconnect(Callable(self, "_on_boss_died"))
		# print("DEBUG (GameUI): Disconnected signals from previous boss.") # Debug

# --- Update Functions (Check node validity before updating) ---
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
	# Only update if the bar is valid and meant to be visible (i.e., boss is registered)
	if is_instance_valid(boss_hp_bar) and is_instance_valid(current_boss_ref):
		boss_hp_bar.max_value = max_value
		boss_hp_bar.value = current_value
		# Make sure bar is visible if it wasn't already
		if not boss_hp_bar.visible: boss_hp_bar.visible = true
		# print("UI Updated Boss HP:", current_value, "/", max_value) # Debug if needed
