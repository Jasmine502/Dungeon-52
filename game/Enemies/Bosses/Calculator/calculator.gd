# --- calculator.gd ---
extends CharacterBody2D

# Stats & Exported Variables
@export var max_hp: int = 200
@export var speed: float = 70.0
@export var detection_radius: float = 10000.0 # Currently unused, logic uses direct player ref
@export var pencil_jab_damage: int = 15
@export var protractor_slice_damage: int = 25
# Threshold for changing damage reaction (e.g., 0.3 = 30% HP)
@export var low_health_threshold_percent: float = 0.40
# Knockback strength when hitting player
@export var knockback_strength_on_hit: float = 150.0
# Knockback strength when taking damage in ERROR state
@export var error_state_knockback_strength: float = 180.0
# Duration of stun after being parried
@export var parry_stun_duration: float = 2.5

# AI / Movement Parameters
@export var pencil_jab_range: float = 180.0
@export var protractor_slice_range: float = 30.0 # Renamed from max_x_range for clarity
@export var protractor_slice_max_y_diff: float = 50.0 # Max Y difference to allow slice
@export var protractor_slice_sound_frame: int = 5 # Frame index (0-based) for slice sound
@export var buff_chance: float = 0.2 # Chance to buff when low HP decision point occurs
@export var follow_y_speed_multiplier: float = 0.8 # Speed multiplier for vertical movement
@export var hover_deadzone: float = 10.0 # Vertical distance within which hovering stops adjusting Y
@export var ai_cooldown_base: float = 1.5 # Base time between AI decisions
@export var ai_cooldown_variation: float = 0.3 # Random variation +/-

# Buff Implementation
@export var buff_duration: float = 10.0
@export var buff_damage_multiplier: float = 1.5
var is_buffed: bool = false
var buff_timer: float = 0.0
var base_pencil_damage: int
var base_protractor_damage: int

# --- Audio Resources ---
@export_group("Audio Streams")
@export var protractor_slice_sounds: Array[AudioStream] = [] # Played on anim frame
@export var protractor_hit_sounds: Array[AudioStream] = [] # Played when slice hits player
@export var pencil_hit_sounds: Array[AudioStream] = [] # Played when jab hits player
@export var buff_sounds: Array[AudioStream] = [] # Played when buff starts
@export var damage_sounds: Array[AudioStream] = [] # Played on ALL hits taken
@export var death_sounds: Array[AudioStream] = [] # Played on death anim start
@export var error_sounds: Array[AudioStream] = [] # Played on LOW health hits (interrupt) / Parry
# @export var parried_sounds: Array[AudioStream] = [] # Optional specific sound for being parried

@export_group("Audio Settings")
@export var min_pitch: float = 0.95
@export var max_pitch: float = 1.10

# State Machine
enum State { IDLE, MOVE, PENCIL_JAB, PROTRACTOR_SLICE, MULTIPLY_BUFF, ERROR, DEAD }
var current_state: State = State.IDLE

# Internal Variables
var current_hp: int
var player_node: CharacterBody2D = null # Reference to the player character
var can_act: bool = true # Controls if AI can make a new decision/start action
var ai_timer: float = 0.0 # Timer for AI decision cooldown
var attack_hit_registered_this_action: bool = false # Prevent multi-hits per attack animation
var player_died_connected: bool = false # Track if player died signal is connected
var player_is_dead: bool = false # Track player state locally
var prioritize_vertical: bool = false # Flag for AI vertical movement focus
# Timer for parry stun duration
var parry_stun_timer: float = 0.0

# Signals for UI
signal hp_changed(current_value, max_value)
signal died # Emitted when calculator HP reaches 0

# Node References
@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var hurtbox: Area2D = $Hurtbox
@onready var main_collision_shape: CollisionShape2D = $CollisionEnvironment
@onready var hitbox_pivot: Node2D = $HitboxPivot # Used to flip hitboxes with sprite
@onready var pencil_hitbox: Area2D = $HitboxPivot/PencilHitbox
@onready var protractor_hitbox: Area2D = $HitboxPivot/ProtractorHitbox
@onready var pencil_hitbox_shape: CollisionShape2D = $HitboxPivot/PencilHitbox/CollisionShape2D
@onready var protractor_hitbox_shape: CollisionShape2D = $HitboxPivot/ProtractorHitbox/CollisionShape2D

# --- Audio Player Node References ---
@onready var attack_sfx_player: AudioStreamPlayer2D = $AttackSFXPlayer # For Slice sound on anim
@onready var hit_player_sfx_player: AudioStreamPlayer2D = $HitPlayerSFXPlayer # For Slice/Jab connect sounds
@onready var buff_sfx_player: AudioStreamPlayer2D = $BuffSFXPlayer
@onready var damage_sfx_player: AudioStreamPlayer2D = $DamageSFXPlayer # For generic hurt sound
@onready var death_sfx_player: AudioStreamPlayer2D = $DeathSFXPlayer
@onready var state_sfx_player: AudioStreamPlayer2D = $StateSFXPlayer # For error state sound (and parried)

# --- Initialization ---
func _ready() -> void:
	current_hp = max_hp
	add_to_group("enemies") # Add to group for potential targeting by others
	if is_instance_valid(hurtbox):
		hurtbox.add_to_group("enemy_hurtbox") # Add hurtbox specifically for player attacks
	else:
		printerr("ERROR (Calculator): Hurtbox node not found or invalid!")

	# Validate essential nodes
	if not is_instance_valid(animated_sprite): printerr("ERROR (Calculator): AnimatedSprite2D node missing!")
	if not is_instance_valid(main_collision_shape): printerr("ERROR (Calculator): CollisionEnvironment shape missing!")
	if not is_instance_valid(hitbox_pivot): printerr("ERROR (Calculator): HitboxPivot node missing!")
	if not is_instance_valid(pencil_hitbox): printerr("ERROR (Calculator): PencilHitbox node missing!")
	if not is_instance_valid(protractor_hitbox): printerr("ERROR (Calculator): ProtractorHitbox node missing!")
	if not is_instance_valid(pencil_hitbox_shape): printerr("ERROR (Calculator): PencilHitbox shape missing!")
	if not is_instance_valid(protractor_hitbox_shape): printerr("ERROR (Calculator): ProtractorHitbox shape missing!")

	# Store base damage for buffing
	base_pencil_damage = pencil_jab_damage
	base_protractor_damage = protractor_slice_damage

	# Disable hitboxes initially
	if is_instance_valid(pencil_hitbox_shape): pencil_hitbox_shape.disabled = true
	if is_instance_valid(protractor_hitbox_shape): protractor_hitbox_shape.disabled = true

	# Register with UI (deferred to allow UI scene to load)
	call_deferred("register_with_ui")
	emit_signal("hp_changed", current_hp, max_hp) # Initial HP update

	# Connect internal signals (animation, hitboxes)
	_connect_internal_signals()

	# Validate audio nodes (optional)
	if not is_instance_valid(attack_sfx_player): printerr("WARNING (Calculator): AttackSFXPlayer node missing!")
	if not is_instance_valid(hit_player_sfx_player): printerr("WARNING (Calculator): HitPlayerSFXPlayer node missing!")
	if not is_instance_valid(buff_sfx_player): printerr("WARNING (Calculator): BuffSFXPlayer node missing!")
	if not is_instance_valid(damage_sfx_player): printerr("WARNING (Calculator): DamageSFXPlayer node missing!")
	if not is_instance_valid(death_sfx_player): printerr("WARNING (Calculator): DeathSFXPlayer node missing!")
	if not is_instance_valid(state_sfx_player): printerr("WARNING (Calculator): StateSFXPlayer node missing!")

	print("Calculator Ready. HP=", current_hp)

# --- Audio Helper ---
# Renamed parameter 'player_node' to 'audio_player_node' to avoid shadowing class variable
func play_sound(audio_player_node: AudioStreamPlayer2D, sound_variations: Array, p_min_pitch: float = min_pitch, p_max_pitch: float = max_pitch) -> void:
	if not is_instance_valid(audio_player_node): return
	if sound_variations.is_empty(): return

	var sound_stream = sound_variations.pick_random()
	if not sound_stream is AudioStream:
		printerr("Warning (Calculator): Invalid item in sound variations array for node: ", audio_player_node.name)
		return

	audio_player_node.stream = sound_stream
	audio_player_node.pitch_scale = randf_range(p_min_pitch, p_max_pitch)
	audio_player_node.play()

# --- Setup & Connections ---
func _connect_internal_signals():
	# Connect hitbox signals
	if is_instance_valid(pencil_hitbox):
		if not pencil_hitbox.body_entered.is_connected(Callable(self, "_on_pencil_hitbox_body_entered")):
			pencil_hitbox.body_entered.connect(Callable(self, "_on_pencil_hitbox_body_entered"))
	if is_instance_valid(protractor_hitbox):
		if not protractor_hitbox.body_entered.is_connected(Callable(self, "_on_protractor_hitbox_body_entered")):
			protractor_hitbox.body_entered.connect(Callable(self, "_on_protractor_hitbox_body_entered"))

	# Connect animation signals
	if is_instance_valid(animated_sprite):
		if not animated_sprite.animation_finished.is_connected(Callable(self, "_on_animation_finished")):
			animated_sprite.animation_finished.connect(Callable(self, "_on_animation_finished"))
		if not animated_sprite.frame_changed.is_connected(Callable(self, "_on_animation_frame_changed")):
			animated_sprite.frame_changed.connect(Callable(self, "_on_animation_frame_changed"))

func register_with_ui():
	# Find GameUI node (assuming only one) and register this boss
	var game_ui_nodes = get_tree().get_nodes_in_group("game_ui")
	if game_ui_nodes.size() > 0:
		var game_ui = game_ui_nodes[0]
		# Check if the UI node is valid and has the registration method
		if is_instance_valid(game_ui) and game_ui.has_method("register_boss"):
			game_ui.register_boss(self)
		elif is_instance_valid(game_ui):
			printerr("ERROR (Calculator): Found GameUI node but it lacks 'register_boss' method.")
		else:
			printerr("ERROR (Calculator): Could not find a valid GameUI node in group 'game_ui'.")
	else:
		print("WARNING (Calculator): No GameUI node found in group 'game_ui' to register with.")


# --- Core Logic Loop ---
func _physics_process(delta: float) -> void:
	# Buff Timer Management
	if is_buffed:
		buff_timer -= delta
		if buff_timer <= 0: _expire_buff()

	# Ensure Player Reference is Valid and Connected
	if not is_instance_valid(player_node) and not player_is_dead:
		_find_player() # Try to find player if reference lost and player not confirmed dead
	elif is_instance_valid(player_node) and not player_died_connected:
		_connect_player_died_signal() # Try connecting if valid player but signal not connected

	# --- State-Based Processing ---
	match current_state:
		State.DEAD:
			velocity = Vector2.ZERO # Ensure no movement when dead
		State.PENCIL_JAB, State.PROTRACTOR_SLICE, State.MULTIPLY_BUFF:
			handle_action_state_movement(delta) # Slow down/stop during actions
		State.ERROR:
			# Handle parry stun timer
			if parry_stun_timer > 0:
				parry_stun_timer -= delta
				if parry_stun_timer <= 0:
					# Parry stun finished, allow recovery IF still in error state
					# (animation might have finished earlier)
					if current_state == State.ERROR:
						_transition_to_idle_after_action()
			handle_error_state_movement(delta) # Apply knockback fade regardless of timer
		State.IDLE, State.MOVE:
			# AI Decision Making
			if can_act:
				decide_action_or_move(delta) # Check if player exists and cooldown passed
			# Movement Execution (applies even if cannot act, e.g., during cooldown)
			handle_idle_move_state(delta)
		_: # Failsafe for any unexpected state
			print("WARN (Calculator): Reached unexpected state, defaulting to IDLE.")
			_change_state(State.IDLE)

	# Apply movement if not dead
	if current_state != State.DEAD:
		move_and_slide()


# --- Player Tracking ---
func _find_player():
	var players = get_tree().get_nodes_in_group("player")
	if players.size() > 0:
		if players[0] is CharacterBody2D:
			player_node = players[0]
			player_is_dead = false # Assume player is alive when found
			player_died_connected = false # Reset connection flag
			_connect_player_died_signal() # Attempt connection immediately
		else:
			printerr("ERROR (Calculator): Found node in 'player' group is not CharacterBody2D!")
			player_node = null
	# else: Keep player_node as null

func _connect_player_died_signal():
	if is_instance_valid(player_node) and player_node.has_signal("died"):
		if not player_node.died.is_connected(Callable(self, "_on_player_died")):
			var err = player_node.died.connect(Callable(self, "_on_player_died"))
			if err == OK:
				player_died_connected = true
			else:
				printerr("ERROR (Calculator): Failed to connect to player 'died' signal. Error code: ", err)
				player_died_connected = false
		else:
			player_died_connected = true

# --- AI & Movement ---
func decide_action_or_move(delta: float) -> void:
	# Only proceed if we have a valid, alive player reference
	if not is_instance_valid(player_node) or player_is_dead:
		if current_state != State.IDLE: _change_state(State.IDLE) # Go idle if player lost
		prioritize_vertical = false # Reset flag
		return

	# Decrement AI timer
	ai_timer -= delta
	if ai_timer <= 0:
		choose_action() # Time to make a decision
		# Reset timer with variation
		ai_timer = ai_cooldown_base + randf_range(-ai_cooldown_variation, ai_cooldown_variation)

func handle_action_state_movement(delta: float) -> void:
	# Reduce horizontal velocity during actions
	var friction = speed * delta * 3 # Friction factor
	velocity = velocity.move_toward(Vector2(0, velocity.y), friction) # Slow horizontal movement

func handle_error_state_movement(delta: float) -> void:
	# Apply friction to slow down from knockback during ERROR state
	var friction = speed * delta * 2 # Adjust friction as needed
	velocity = velocity.move_toward(Vector2.ZERO, friction)

func handle_idle_move_state(delta: float) -> void:
	var target_velocity = Vector2.ZERO
	var face_player_right = false # Direction to face

	if is_instance_valid(player_node) and not player_is_dead:
		var vector_to_player = player_node.global_position - global_position
		var y_diff = vector_to_player.y
		face_player_right = (vector_to_player.x > 0)

		# Movement logic only if in MOVE state
		if current_state == State.MOVE:
			# Vertical Movement: Adjust if further than deadzone OR prioritizing vertical
			if prioritize_vertical or abs(y_diff) > hover_deadzone:
				target_velocity.y = sign(y_diff) * speed * follow_y_speed_multiplier
			else:
				target_velocity.y = 0 # Stop vertical adjustment if close enough and not prioritizing

			# Horizontal Movement: Always move towards player X unless prioritizing vertical
			if prioritize_vertical:
				target_velocity.x = sign(vector_to_player.x) * speed * 0.3 # Reduced horizontal speed
			else:
				target_velocity.x = sign(vector_to_player.x) * speed

			# Animation for moving
			play_animation("move_loop", "move_start") # Use helper to handle start/loop

		# No movement if in IDLE state
		elif current_state == State.IDLE:
			play_animation("idle") # Ensure idle animation plays
			target_velocity = Vector2.ZERO
			prioritize_vertical = false # Ensure flag is off

	else: # No valid player or player is dead
		play_animation("idle")
		target_velocity = Vector2.ZERO
		prioritize_vertical = false # Ensure flag is off

	# Apply facing direction
	if is_instance_valid(animated_sprite): animated_sprite.flip_h = face_player_right
	if is_instance_valid(hitbox_pivot): hitbox_pivot.scale.x = -1 if face_player_right else 1

	# Apply acceleration/deceleration towards the target velocity
	var acceleration = speed * delta * 4 # Adjust acceleration factor if needed
	velocity = velocity.move_toward(target_velocity, acceleration)


# --- Action Decision Logic ---
func choose_action() -> void:
	# Pre-checks: Must have player, be able to act, and not be dead
	if not is_instance_valid(player_node) or not can_act or player_is_dead or current_state == State.DEAD:
		if current_state != State.IDLE and current_state != State.DEAD:
			_change_state(State.IDLE) # Go idle if conditions not met
		return

	var vector_to_player = player_node.global_position - global_position
	var distance_sq = vector_to_player.length_squared() # Use squared distance for efficiency
	var x_diff = abs(vector_to_player.x)
	var y_diff = abs(vector_to_player.y)
	var is_low_hp = current_hp <= max_hp * low_health_threshold_percent

	# --- Update Facing Direction Immediately ---
	var face_right = (vector_to_player.x > 0)
	if is_instance_valid(animated_sprite): animated_sprite.flip_h = face_right
	if is_instance_valid(hitbox_pivot): hitbox_pivot.scale.x = -1 if face_right else 1

	# --- Define Viability Conditions ---
	var slice_viable = (x_diff <= protractor_slice_range) and (y_diff <= protractor_slice_max_y_diff)
	var jab_viable = (distance_sq <= pencil_jab_range * pencil_jab_range)
	var should_prioritize_vertical_for_slice = (x_diff <= protractor_slice_range) and (y_diff > protractor_slice_max_y_diff)

	# Reset vertical priority flag before decision
	prioritize_vertical = false

	# --- Decision Tree ---
	if is_low_hp and not is_buffed and randf() < buff_chance:
		_initiate_action(State.MULTIPLY_BUFF, "multiplication_buff")
		play_sound(buff_sfx_player, buff_sounds)
	elif slice_viable:
		_initiate_action(State.PROTRACTOR_SLICE, "protractor_slice")
	elif should_prioritize_vertical_for_slice:
		prioritize_vertical = true # SET FLAG to adjust Y position
		if current_state != State.MOVE: _change_state(State.MOVE)
	elif jab_viable:
		_initiate_action(State.PENCIL_JAB, "pencil_jab")
	else:
		if current_state != State.MOVE: _change_state(State.MOVE)

# --- Action Initiation Helper ---
func _initiate_action(new_state: State, anim_name: String) -> void:
	if not can_act or current_state == State.DEAD: return # Double check
	can_act = false # Prevent new actions until this one finishes
	prioritize_vertical = false # Stop prioritizing vertical if attacking/buffing
	attack_hit_registered_this_action = false # Reset hit flag for the new action
	_change_state(new_state)
	play_animation(anim_name)

# --- Buff Management ---
func apply_multiplication_buff():
	if not is_buffed:
		is_buffed = true
		buff_timer = buff_duration
		pencil_jab_damage = int(base_pencil_damage * buff_damage_multiplier)
		protractor_slice_damage = int(base_protractor_damage * buff_damage_multiplier)

func _expire_buff():
	if is_buffed:
		is_buffed = false
		pencil_jab_damage = base_pencil_damage
		protractor_slice_damage = base_protractor_damage
		buff_timer = 0

# --- Damage & Death Handling ---
# Prefixed unused 'damage_source_node' parameter with underscore
func take_damage(amount: int, _damage_source_node: Node = null, damage_source_position: Vector2 = global_position) -> void:
	# --- 1. Initial Check: Ignore damage only if already DEAD ---
	if current_state == State.DEAD: return

	# Remember if currently stunned by parry BEFORE taking damage
	var was_parry_stunned = (current_state == State.ERROR and parry_stun_timer > 0)

	# --- 2. Apply Damage ---
	current_hp = max(0, current_hp - amount) # Prevent negative HP
	emit_signal("hp_changed", current_hp, max_hp)

	# Always play generic damage sound
	play_sound(damage_sfx_player, damage_sounds)

	# --- 3. Check for Death ---
	if current_hp <= 0:
		_die()
		return # Stop further processing if dead

	# --- 4. Handle Reaction (if not dead) ---
	# If hit while parry-stunned, just take damage and play sound (already done).
	# Do NOT trigger low health check or knockback again.
	if was_parry_stunned:
		# Optionally, restart the error animation briefly for visual feedback?
		if is_instance_valid(animated_sprite) and animated_sprite.animation == "error":
			# Restart animation to give visual feedback on consecutive hits during stun
			animated_sprite.play("error")
		return

	# --- 5. If NOT parry-stunned, check for standard low-health reaction ---
	var health_percentage = float(current_hp) / float(max_hp)
	if health_percentage <= low_health_threshold_percent:
		# LOW HEALTH REACTION (Interrupting)
		if is_instance_valid(pencil_hitbox_shape): pencil_hitbox_shape.set_deferred("disabled", true)
		if is_instance_valid(protractor_hitbox_shape): protractor_hitbox_shape.set_deferred("disabled", true)
		attack_hit_registered_this_action = false # Ensure hit flag reset

		_change_state(State.ERROR)
		parry_stun_timer = 0.0 # Ensure this isn't treated as parry stun
		can_act = false # Prevent acting immediately after error state
		play_animation("error")
		play_sound(state_sfx_player, error_sounds) # Play specific error sound

		# Apply knockback for low-health hit
		var knockback_direction = (global_position - damage_source_position).normalized()
		if knockback_direction == Vector2.ZERO:
			knockback_direction = Vector2.RIGHT.rotated(randf_range(0, TAU))
		velocity = knockback_direction * error_state_knockback_strength

		_expire_buff() # Taking a critical hit removes buff

	# else: HIGH HEALTH REACTION (Non-Interrupting) - Do nothing extra if not low HP and not parry stunned


# Function called by Player on successful parry
func trigger_parried_state():
	# Ignore if already dead or already in the error state from a previous parry/hit
	if current_state == State.DEAD or current_state == State.ERROR: return

	print("Calculator: Parried!") # Debug
	_expire_buff() # Remove buff if parried

	# Disable hitboxes immediately
	if is_instance_valid(pencil_hitbox_shape): pencil_hitbox_shape.set_deferred("disabled", true)
	if is_instance_valid(protractor_hitbox_shape): protractor_hitbox_shape.set_deferred("disabled", true)
	attack_hit_registered_this_action = false

	# Change state to ERROR, interrupt current action
	_change_state(State.ERROR)
	can_act = false # Prevent acting immediately after error state
	parry_stun_timer = parry_stun_duration # START the parry stun timer

	play_animation("error") # Play the visual feedback animation
	# play_sound(state_sfx_player, parried_sounds if parried_sounds.size() > 0 else error_sounds) # Use error sound as fallback
	play_sound(state_sfx_player, error_sounds) # Using error sound for parry feedback

	# Briefly halt movement before error state physics takes over (optional)
	velocity = Vector2.ZERO


func _die():
	if current_state == State.DEAD: return # Prevent multiple deaths
	_change_state(State.DEAD)
	can_act = false; prioritize_vertical = false; velocity = Vector2.ZERO; parry_stun_timer = 0.0
	print("Calculator: Defeated!")

	play_sound(death_sfx_player, death_sounds) # Play death sound

	# Disable physics interactions safely
	set_collision_layer_value(3, false) # No longer collides as enemy
	set_collision_mask(0) # Clear masks
	if is_instance_valid(hurtbox):
		hurtbox.set_deferred("collision_layer", 0)
		hurtbox.set_deferred("collision_mask", 0)
	if is_instance_valid(pencil_hitbox_shape): pencil_hitbox_shape.set_deferred("disabled", true)
	if is_instance_valid(protractor_hitbox_shape): protractor_hitbox_shape.set_deferred("disabled", true)

	play_animation("death") # Start death animation
	emit_signal("died") # Signal UI or game manager
	_expire_buff() # Remove buff on death


# --- Animation & State Helpers ---
func play_animation(anim_name: String, start_anim_name: String = "") -> void:
	# Helper to play loop animations after a start animation if provided
	if not is_instance_valid(animated_sprite): return
	# Don't change animation if dead, unless playing the 'death' animation itself
	if current_state == State.DEAD and anim_name != "death": return

	var final_anim_name = anim_name
	# Check if a start animation should be played first
	if start_anim_name != "" and animated_sprite.animation != anim_name and animated_sprite.animation != start_anim_name:
		if animated_sprite.sprite_frames.has_animation(start_anim_name):
			final_anim_name = start_anim_name

	# Play the determined animation if it exists and is different
	if animated_sprite.sprite_frames.has_animation(final_anim_name):
		if animated_sprite.animation != final_anim_name:
			animated_sprite.play(final_anim_name)
	else:
		printerr("ERROR (Calculator): Animation '", final_anim_name, "' not found!")

func _change_state(new_state: State):
	if current_state != new_state:
		# print("DEBUG: State change ", State.keys()[current_state], " -> ", State.keys()[new_state]) # Debug state changes
		current_state = new_state


# --- Signal Handlers ---
func _on_animation_frame_changed():
	if not is_instance_valid(animated_sprite) or current_state == State.DEAD: return

	var current_anim = animated_sprite.animation
	var current_frame = animated_sprite.frame

	# Sound Triggers
	if current_state == State.PROTRACTOR_SLICE and current_anim == "protractor_slice":
		if current_frame == protractor_slice_sound_frame:
			play_sound(attack_sfx_player, protractor_slice_sounds)

	# Hitbox Enabling
	if current_state == State.PENCIL_JAB and current_anim == "pencil_jab":
		handle_attack_hitbox(pencil_hitbox_shape, 6, current_frame) # Pencil jab frame 6
	elif current_state == State.PROTRACTOR_SLICE and current_anim == "protractor_slice":
		handle_attack_hitbox(protractor_hitbox_shape, 7, current_frame) # Protractor slice frame 7

	# Buff Application
	if current_state == State.MULTIPLY_BUFF and current_anim == "multiplication_buff":
		if current_frame == 17 and not is_buffed: # Buff applies on frame 17
			apply_multiplication_buff()

func handle_attack_hitbox(shape: CollisionShape2D, hit_frame: int, current_frame: int):
	# Enable hitbox on the specific frame, disable otherwise
	if not is_instance_valid(shape): return
	if current_frame == hit_frame:
		if shape.disabled: shape.disabled = false
	else:
		# Ensure hitbox is disabled if not on the active frame
		# Check shape.disabled before setting to avoid redundant calls
		if not shape.disabled: shape.disabled = true


func _on_animation_finished() -> void:
	if not is_instance_valid(animated_sprite): return
	var finished_anim = animated_sprite.animation

	# Ensure Hitboxes Disabled on Action End
	if finished_anim == "pencil_jab" and is_instance_valid(pencil_hitbox_shape):
		pencil_hitbox_shape.set_deferred("disabled", true)
	elif finished_anim == "protractor_slice" and is_instance_valid(protractor_hitbox_shape):
		protractor_hitbox_shape.set_deferred("disabled", true)

	# State Transitions Based on Finished Animation
	if current_state == State.DEAD: return # No transitions if dead

	if player_is_dead:
		# If player died during an action, default to idle once animation finishes
		if current_state != State.IDLE: _change_state(State.IDLE)
		return

	# Handle transitions for normal states
	match current_state:
		State.PENCIL_JAB:
			if finished_anim == "pencil_jab": _transition_to_idle_after_action()
		State.PROTRACTOR_SLICE:
			if finished_anim == "protractor_slice": _transition_to_idle_after_action()
		State.ERROR:
			# Only transition if parry stun is NOT active
			if finished_anim == "error" and parry_stun_timer <= 0:
				_transition_to_idle_after_action() # Recover ONLY if stun timer finished
			# If animation finished but timer still running, stay in ERROR state
		State.MULTIPLY_BUFF:
			if finished_anim == "multiplication_buff": _transition_to_idle_after_action()
		State.MOVE:
			if finished_anim == "move_start": play_animation("move_loop")
			elif finished_anim == "move_loop":
				# Only transition out of loop if state changed
				if current_state != State.MOVE: _change_state(State.IDLE)
		State.IDLE: pass
		State.DEAD:
			if finished_anim == "death": pass # Death animation finished

func _transition_to_idle_after_action():
	# Common logic for returning to idle after an action/error state finishes
	# Ensure we are not dead before enabling actions
	if current_state == State.DEAD: return

	can_act = true # Allow new decisions
	_change_state(State.IDLE)
	# Optional: Add a small delay before next AI tick?
	ai_timer = ai_cooldown_base * randf_range(0.1, 0.3) # Short delay


# --- Hitbox Collision Handlers ---
func _on_pencil_hitbox_body_entered(body: Node2D):
	if current_state == State.PENCIL_JAB and \
	   is_instance_valid(pencil_hitbox_shape) and not pencil_hitbox_shape.disabled and \
	   not attack_hit_registered_this_action and \
	   body.is_in_group("player"):

		var player = body as CharacterBody2D
		if not is_instance_valid(player): return

		if player.has_method("take_damage"):
			# Call take_damage and check its return value
			var damage_processed = player.call("take_damage", pencil_jab_damage, self, global_position)
			if damage_processed: # Only play sound if damage wasn't ignored (by roll etc.)
				play_sound(hit_player_sfx_player, pencil_hit_sounds)
			attack_hit_registered_this_action = true # Prevent multi-hit regardless of sound
			pencil_hitbox_shape.set_deferred("disabled", true) # Disable immediately

func _on_protractor_hitbox_body_entered(body: Node2D):
	if current_state == State.PROTRACTOR_SLICE and \
	   is_instance_valid(protractor_hitbox_shape) and not protractor_hitbox_shape.disabled and \
	   not attack_hit_registered_this_action and \
	   body.is_in_group("player"):

		var player = body as CharacterBody2D
		if not is_instance_valid(player): return

		if player.has_method("take_damage"):
			# Call take_damage and check its return value
			var damage_processed = player.call("take_damage", protractor_slice_damage, self, global_position)
			if damage_processed: # Only play sound if damage wasn't ignored (by roll etc.)
				play_sound(hit_player_sfx_player, protractor_hit_sounds)
			attack_hit_registered_this_action = true # Prevent multi-hit regardless of sound
			protractor_hitbox_shape.set_deferred("disabled", true) # Disable immediately


func _on_player_died():
	# print("DEBUG: Calculator received player died signal.") # Debug
	player_node = null # Clear reference
	player_died_connected = false # Reset connection flag
	player_is_dead = true # Mark player as dead
	prioritize_vertical = false # Ensure flag is off
	parry_stun_timer = 0.0 # Clear stun timer if player dies

	# If currently moving or idle, go directly to idle
	if current_state == State.IDLE or current_state == State.MOVE:
		_change_state(State.IDLE)
		velocity = Vector2.ZERO # Stop movement

	# If in an action state when player dies, finish animation then go idle
	# (handled by _on_animation_finished checking player_is_dead)

	# Disable hitboxes if they were somehow active
	if is_instance_valid(pencil_hitbox_shape): pencil_hitbox_shape.set_deferred("disabled", true)
	if is_instance_valid(protractor_hitbox_shape): protractor_hitbox_shape.set_deferred("disabled", true)
	attack_hit_registered_this_action = false

	_expire_buff() # Remove buff if player dies
