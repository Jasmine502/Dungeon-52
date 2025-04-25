# --- calculator.gd ---
extends CharacterBody2D

# Stats & Exported Variables
@export var max_hp: int = 200
@export var speed: float = 70.0
@export var detection_radius: float = 400.0
@export var pencil_jab_damage: int = 15
@export var protractor_slice_damage: int = 25
# Threshold for changing damage reaction (e.g., 0.3 = 30% HP)
@export var low_health_threshold: float = 0.3

# AI / Movement Parameters
@export var pencil_jab_range: float = 220.0
@export var protractor_slice_range: float = 30.0
@export var protractor_slice_max_x_range: float = 50.0
@export var protractor_slice_max_y_prefer: float = 100.0
@export var protractor_slice_sound_frame: int = 5 # Frame index (0-based) for slice sound
@export var too_close_distance: float = 50.0 # Currently unused
@export var back_off_chance: float = 0.3 # Currently unused
@export var buff_chance: float = 0.2
@export var follow_y_speed_multiplier: float = 0.8 # Increased for faster vertical adjustment
@export var hover_deadzone: float = 10.0

# Buff Implementation
@export var buff_duration: float = 10.0
@export var buff_multiplier: float = 1.5
var is_buffed: bool = false
var buff_timer: float = 0.0
var base_pencil_damage: int
var base_protractor_damage: int

# --- Audio Resources ---
@export_group("Audio Streams")
@export var protractor_slice_sounds: Array[AudioStream] = []
@export var protractor_hit_sounds: Array[AudioStream] = []
@export var pencil_hit_sounds: Array[AudioStream] = []
@export var buff_sounds: Array[AudioStream] = []
@export var damage_sounds: Array[AudioStream] = [] # Played on ALL hits
@export var death_sound: Array[AudioStream] = []
@export var error_sounds: Array[AudioStream] = [] # Played only on LOW health hits (interrupt)
# @export var move_sounds: Array[AudioStream] = []

@export_group("Audio Settings")
@export var min_pitch: float = 0.95
@export var max_pitch: float = 1.10

# State Machine
enum State { IDLE, MOVE, PENCIL_JAB, PROTRACTOR_SLICE, MULTIPLY_BUFF, ERROR, DEAD }
var current_state: State = State.IDLE

# Internal Variables
var current_hp: int
var player_node: CharacterBody2D = null
var can_act: bool = true
var ai_timer: float = 0.0
var ai_cooldown: float = 1.5 # Time between AI decisions
var attack_hit_registered: bool = false
var moving_away: bool = false # Currently unused
var player_died_connected: bool = false
var player_is_dead: bool = false
var prioritize_vertical: bool = false # NEW: Flag for AI vertical movement focus

# Signals for UI
signal hp_changed(current_value, max_value)
signal died

# Node References
@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var hurtbox: Area2D = $Hurtbox
@onready var main_collision_shape: CollisionShape2D = $CollisionEnvironment
@onready var hitbox_pivot: Node2D = $HitboxPivot
@onready var pencil_hitbox: Area2D = $HitboxPivot/PencilHitbox
@onready var protractor_hitbox: Area2D = $HitboxPivot/ProtractorHitbox
@onready var pencil_hitbox_shape: CollisionShape2D = $HitboxPivot/PencilHitbox/CollisionShape2D
@onready var protractor_hitbox_shape: CollisionShape2D = $HitboxPivot/ProtractorHitbox/CollisionShape2D

# --- Audio Player Node References ---
@onready var slice_attack_sfx_player: AudioStreamPlayer2D = $SliceAttackSFXPlayer
@onready var hit_player_sfx_player: AudioStreamPlayer2D = $HitPlayerSFXPlayer
@onready var buff_sfx_player: AudioStreamPlayer2D = $BuffSFXPlayer
@onready var damage_sfx_player: AudioStreamPlayer2D = $DamageSFXPlayer # For generic hurt sound
@onready var death_sfx_player: AudioStreamPlayer2D = $DeathSFXPlayer
@onready var state_sfx_player: AudioStreamPlayer2D = $StateSFXPlayer # For error state sound

# --- Initialization ---
func _ready() -> void:
	current_hp = max_hp
	add_to_group("enemies")
	if is_instance_valid(hurtbox): hurtbox.add_to_group("enemy_hurtbox")
	else: printerr("ERROR (Calculator): Hurtbox node not found or invalid!")
	if not is_instance_valid(hitbox_pivot):
		printerr("ERROR (Calculator): HitboxPivot node not found! Make sure it exists.")
		return

	base_pencil_damage = pencil_jab_damage
	base_protractor_damage = protractor_slice_damage

	call_deferred("register_with_ui")
	emit_signal("hp_changed", current_hp, max_hp)

	_connect_internal_signals()

	if is_instance_valid(pencil_hitbox_shape): pencil_hitbox_shape.disabled = true
	if is_instance_valid(protractor_hitbox_shape): protractor_hitbox_shape.disabled = true

	if not is_instance_valid(slice_attack_sfx_player): printerr("ERROR (Calculator): SliceAttackSFXPlayer node not found!")
	if not is_instance_valid(hit_player_sfx_player): printerr("ERROR (Calculator): HitPlayerSFXPlayer node not found!")
	if not is_instance_valid(buff_sfx_player): printerr("ERROR (Calculator): BuffSFXPlayer node not found!")
	if not is_instance_valid(damage_sfx_player): printerr("ERROR (Calculator): DamageSFXPlayer node not found!")
	if not is_instance_valid(death_sfx_player): printerr("ERROR (Calculator): DeathSFXPlayer node not found!")
	if not is_instance_valid(state_sfx_player): printerr("ERROR (Calculator): StateSFXPlayer node not found!")

	print("Calculator Ready. HP=", current_hp)

# --- Audio Helper ---
func play_sound(player_node: AudioStreamPlayer2D, sound_variations: Array, p_min_pitch: float = min_pitch, p_max_pitch: float = max_pitch) -> void:
	if not is_instance_valid(player_node): return
	if sound_variations.is_empty(): return

	var sound_stream = sound_variations.pick_random()
	if not sound_stream is AudioStream:
		printerr("Warning (Calculator): Invalid item in sound variations array.")
		return

	player_node.stream = sound_stream
	player_node.pitch_scale = randf_range(p_min_pitch, p_max_pitch)
	player_node.play()

func _connect_internal_signals():
	if is_instance_valid(pencil_hitbox):
		if not pencil_hitbox.body_entered.is_connected(Callable(self, "_on_pencil_hitbox_body_entered")):
			pencil_hitbox.body_entered.connect(Callable(self, "_on_pencil_hitbox_body_entered"))
	else: printerr("ERROR (Calculator): PencilHitbox node invalid/missing under HitboxPivot!")

	if is_instance_valid(protractor_hitbox):
		if not protractor_hitbox.body_entered.is_connected(Callable(self, "_on_protractor_hitbox_body_entered")):
			protractor_hitbox.body_entered.connect(Callable(self, "_on_protractor_hitbox_body_entered"))
	else: printerr("ERROR (Calculator): ProtractorHitbox node invalid/missing under HitboxPivot!")

	if is_instance_valid(animated_sprite):
		if not animated_sprite.animation_finished.is_connected(Callable(self, "_on_animation_finished")):
			animated_sprite.animation_finished.connect(Callable(self, "_on_animation_finished"))
		if not animated_sprite.frame_changed.is_connected(Callable(self, "_on_animation_frame_changed")):
			animated_sprite.frame_changed.connect(Callable(self, "_on_animation_frame_changed"))
	else: printerr("ERROR (Calculator): AnimatedSprite2D node invalid/missing!")

func register_with_ui():
	var game_ui_nodes = get_tree().get_nodes_in_group("game_ui")
	if game_ui_nodes.size() > 0:
		var game_ui = game_ui_nodes[0]
		if is_instance_valid(game_ui) and game_ui.has_method("register_boss"): game_ui.register_boss(self)

# --- Core Logic ---
func _process(_delta: float) -> void: pass # Keep empty unless needed

func _physics_process(delta: float) -> void:
	# --- Buff Timer ---
	if is_buffed:
		buff_timer -= delta
		if buff_timer <= 0: _expire_buff()

	# --- Player Check ---
	if not is_instance_valid(player_node) and not player_is_dead:
		_find_player()
	elif is_instance_valid(player_node) and not player_died_connected:
		_connect_player_died_signal() # Attempt connection if player found but not connected

	# --- State-Based Processing ---
	match current_state:
		State.DEAD:
			velocity = Vector2.ZERO # Ensure no movement when dead
		State.PENCIL_JAB, State.PROTRACTOR_SLICE, State.MULTIPLY_BUFF:
			handle_action_state_movement(delta) # Slow down/stop during actions
		State.ERROR:
			handle_error_state_movement(delta) # Apply knockback fade
		State.IDLE, State.MOVE:
			if can_act: find_player_and_decide_action(delta) # Check if action needed
			handle_idle_move_state(delta) # Handle regular movement/hovering
		_: # Failsafe for any unexpected state
			_go_to_idle_state()

	# Apply movement if not dead
	if current_state != State.DEAD:
		move_and_slide()


func _find_player():
	var players = get_tree().get_nodes_in_group("player")
	if players.size() > 0:
		if players[0] is CharacterBody2D:
			player_node = players[0]
			player_died_connected = false # Reset connection flag on finding new player instance
			player_is_dead = false
			# print("DEBUG: Calculator found player.")
			_connect_player_died_signal() # Connect immediately
		else:
			printerr("ERROR (Calculator): Found node in 'player' group is not CharacterBody2D!")
			player_node = null

func _connect_player_died_signal():
	if is_instance_valid(player_node) and player_node.has_signal("died"):
		if not player_node.died.is_connected(Callable(self, "_on_player_died")):
			var err = player_node.died.connect(Callable(self, "_on_player_died"))
			if err == OK:
				player_died_connected = true
				# print("DEBUG: Calculator connected to player 'died' signal.")
			else:
				printerr("ERROR (Calculator): Failed to connect to player 'died' signal. Error code: ", err)
				player_died_connected = false # Ensure flag is false if connection fails
		else:
			player_died_connected = true # Already connected

func find_player_and_decide_action(delta: float):
	# Prevent AI decisions if not IDLE or MOVE, or if cannot act
	if current_state != State.IDLE and current_state != State.MOVE: return
	if not can_act: return

	if is_instance_valid(player_node) and not player_is_dead:
		ai_timer -= delta
		if ai_timer <= 0:
			choose_action()
			ai_timer = ai_cooldown * randf_range(0.8, 1.2) # Reset AI cooldown timer
	elif not player_is_dead: # If player is invalid but not dead, try finding again
		_find_player()


func handle_action_state_movement(delta: float) -> void:
	# Movement logic specific to ongoing attacks/buffs (usually stopping)
	var friction = speed * delta * 3 # Friction factor to slow down
	velocity = velocity.move_toward(Vector2.ZERO, friction) # Gradually stop

	# Handle enabling/disabling hitboxes based on animation frame
	match current_state:
		State.PENCIL_JAB:
			handle_attack_hitbox(pencil_hitbox_shape, "pencil_jab", 6) # Frame 6 is jab hitbox active
		State.PROTRACTOR_SLICE:
			handle_attack_hitbox(protractor_hitbox_shape, "protractor_slice", 7) # Frame 7 is slice hitbox active
		State.MULTIPLY_BUFF:
			# Check for buff application frame (adjust frame index if needed)
			if animated_sprite.animation == "multiplication_buff" and animated_sprite.frame == 17 and not is_buffed:
				apply_multiplication_buff()
		_: pass # No specific hitbox logic for other action states


func handle_error_state_movement(delta: float) -> void:
	# Apply friction to slow down from knockback during ERROR state
	var friction = speed * delta * 2 # Adjust friction for error state if needed
	velocity = velocity.move_toward(Vector2.ZERO, friction)

# MODIFIED: handle_idle_move_state now uses prioritize_vertical flag
func handle_idle_move_state(delta: float) -> void:
	var target_velocity = Vector2.ZERO
	var face_right = false

	if is_instance_valid(player_node) and not player_is_dead:
		var vector_to_player = player_node.global_position - global_position
		var y_diff = vector_to_player.y
		face_right = (vector_to_player.x > 0)

		# Only move if in MOVE state
		if current_state == State.MOVE:
			# Vertical movement check FIRST
			if abs(y_diff) > hover_deadzone:
				target_velocity.y = sign(y_diff) * speed * follow_y_speed_multiplier
				# If prioritizing vertical, potentially reduce horizontal speed
				if prioritize_vertical:
					target_velocity.x = sign(vector_to_player.x) * speed * 0.3 # Reduce horizontal speed significantly
				else:
					target_velocity.x = sign(vector_to_player.x) * speed
			else:
				# Reached vertical alignment, stop prioritizing vertical
				target_velocity.y = 0
				prioritize_vertical = false # Turn off flag
				# Normal horizontal movement now
				target_velocity.x = sign(vector_to_player.x) * speed

			# Play move animation if not already playing
			if is_instance_valid(animated_sprite):
				if animated_sprite.animation != "move_loop" and animated_sprite.animation != "move_start":
					play_animation("move_start")
				elif animated_sprite.animation == "move_start" and not animated_sprite.is_playing():
					play_animation("move_loop")

		# If in IDLE state
		elif current_state == State.IDLE:
			play_animation("idle")
			target_velocity = Vector2.ZERO # No movement in IDLE
			prioritize_vertical = false # Ensure flag is off if idle

	else: # If player is invalid or dead, or state is somehow not IDLE/MOVE
		play_animation("idle")
		target_velocity = Vector2.ZERO
		prioritize_vertical = false # Ensure flag is off

	# Set facing direction based on player position relative to self
	if is_instance_valid(hitbox_pivot): hitbox_pivot.scale.x = -1 if face_right else 1
	if is_instance_valid(animated_sprite): animated_sprite.flip_h = face_right

	# Apply acceleration/deceleration towards the target velocity
	velocity = velocity.move_toward(target_velocity, speed * delta * 4) # Adjust acceleration factor if needed


# --- MODIFIED choose_action function ---
func choose_action() -> void:
	if not is_instance_valid(player_node) or not can_act or player_is_dead:
		if current_state != State.IDLE and current_state != State.DEAD:
			_go_to_idle_state()
		prioritize_vertical = false # Ensure flag is off if no player
		return

	var vector_to_player = player_node.global_position - global_position
	var distance = vector_to_player.length()
	var x_distance = abs(vector_to_player.x)
	var y_distance = abs(vector_to_player.y)
	var low_hp = current_hp <= max_hp * low_health_threshold

	# --- Update Facing Direction ---
	var face_right = (vector_to_player.x > 0)
	if is_instance_valid(animated_sprite): animated_sprite.flip_h = face_right
	if is_instance_valid(hitbox_pivot): hitbox_pivot.scale.x = -1 if face_right else 1

	# --- Check Attack Viability ---
	var slice_viable = (distance <= protractor_slice_range) and (x_distance <= protractor_slice_max_x_range)
	var jab_viable = (distance <= pencil_jab_range)
	var prefer_slice = (x_distance <= protractor_slice_max_x_range) and (y_distance <= protractor_slice_max_y_prefer)

	# Reset vertical priority flag initially for this decision tick
	prioritize_vertical = false

	# --- Decision Logic ---
	# 1. Buff Priority
	if low_hp and randf() <= buff_chance and not is_buffed:
		initiate_multiplication_buff()
		return

	# 2. Slice Execution
	elif slice_viable:
		initiate_protractor_slice()
		return

	# 3. Prioritize Slice Movement (Set flag and ensure MOVE state)
	elif prefer_slice and not slice_viable:
		prioritize_vertical = true # SET FLAG
		if current_state == State.IDLE: current_state = State.MOVE
		# print("DEBUG: Prioritizing vertical movement")
		return

	# 4. Jab Execution
	elif jab_viable:
		initiate_pencil_jab()
		return

	# 5. Move Towards Player (No specific attack viable)
	else:
		if current_state == State.IDLE:
			current_state = State.MOVE
		return

	# 6. Default to Idle (Shouldn't be reached if player detected)


func initiate_pencil_jab():
	if not can_act or not is_instance_valid(player_node) or player_is_dead: return
	if current_state != State.IDLE and current_state != State.MOVE: return
	prioritize_vertical = false # Stop prioritizing vertical if attacking
	current_state = State.PENCIL_JAB; can_act = false; attack_hit_registered = false
	play_animation("pencil_jab")

func initiate_protractor_slice():
	if not can_act or not is_instance_valid(player_node) or player_is_dead: return
	if current_state != State.IDLE and current_state != State.MOVE: return
	prioritize_vertical = false # Stop prioritizing vertical if attacking
	current_state = State.PROTRACTOR_SLICE; can_act = false; attack_hit_registered = false
	play_animation("protractor_slice")

func initiate_multiplication_buff():
	if not can_act or player_is_dead: return
	if current_state != State.IDLE and current_state != State.MOVE: return
	prioritize_vertical = false # Stop prioritizing vertical if buffing
	current_state = State.MULTIPLY_BUFF; can_act = false
	play_animation("multiplication_buff")
	play_sound(buff_sfx_player, buff_sounds)


func handle_attack_hitbox(shape: CollisionShape2D, anim_name: String, hit_frame: int):
	if current_state != State.PENCIL_JAB and current_state != State.PROTRACTOR_SLICE:
		if is_instance_valid(shape) and not shape.disabled: shape.disabled = true
		return
	if not is_instance_valid(shape) or not is_instance_valid(animated_sprite): return
	if animated_sprite.animation != anim_name:
		if not shape.disabled: shape.disabled = true
		return

	var current_frame = animated_sprite.frame
	if current_frame == hit_frame:
		if shape.disabled and not attack_hit_registered:
			shape.disabled = false
	else:
		if not shape.disabled:
			shape.disabled = true


func apply_multiplication_buff():
	if not is_buffed:
		print("Calculator: Buff Applied!")
		is_buffed = true; buff_timer = buff_duration
		pencil_jab_damage = int(base_pencil_damage * buff_multiplier)
		protractor_slice_damage = int(base_protractor_damage * buff_multiplier)

func _expire_buff():
	if is_buffed:
		is_buffed = false
		pencil_jab_damage = base_pencil_damage
		protractor_slice_damage = base_protractor_damage
		print("Calculator: Buff Expired.")


# --- MODIFIED take_damage function ---
func take_damage(amount: int, knockback_source_position: Vector2): # Expecting player position
	if current_state == State.DEAD or current_state == State.ERROR: return

	current_hp -= amount
	emit_signal("hp_changed", current_hp, max_hp)
	# print("Calculator took damage:", amount, "| HP:", current_hp, "/", max_hp)

	play_sound(damage_sfx_player, damage_sounds)

	if current_hp <= 0:
		current_hp = 0
		_die()
		return

	var health_percentage = float(current_hp) / float(max_hp)
	if health_percentage <= low_health_threshold:
		# LOW HEALTH REACTION (Interrupting)
		# print("Calculator: Low health hit reaction!")
		if is_instance_valid(pencil_hitbox_shape): pencil_hitbox_shape.set_deferred("disabled", true)
		if is_instance_valid(protractor_hitbox_shape): protractor_hitbox_shape.set_deferred("disabled", true)
		attack_hit_registered = false

		current_state = State.ERROR
		can_act = false
		play_animation("error")
		play_sound(state_sfx_player, error_sounds)

		var knockback_direction = (global_position - knockback_source_position).normalized()
		if knockback_direction == Vector2.ZERO:
			knockback_direction = Vector2.RIGHT.rotated(randf_range(0, TAU))
		velocity = knockback_direction * 150

		_expire_buff()

	else:
		# HIGH HEALTH REACTION (Non-Interrupting)
		# print("Calculator: High health hit reaction (no interrupt).")
		pass


func _die():
	if current_state == State.DEAD: return
	print("Calculator: Defeated!")
	current_state = State.DEAD; can_act = false; velocity = Vector2.ZERO
	prioritize_vertical = false # Ensure flag is off

	play_sound(death_sfx_player, death_sound)

	set_collision_layer_value(3, false)
	set_collision_mask_value(1, false)
	set_collision_mask_value(4, false)
	if is_instance_valid(hurtbox):
		hurtbox.set_deferred("collision_layer", 0)
		hurtbox.set_deferred("collision_mask", 0)
	if is_instance_valid(pencil_hitbox_shape): pencil_hitbox_shape.set_deferred("disabled", true)
	if is_instance_valid(protractor_hitbox_shape): protractor_hitbox_shape.set_deferred("disabled", true)

	play_animation("death")
	emit_signal("died")
	_expire_buff()

func play_animation(anim_name: String) -> void:
	if current_state == State.DEAD and anim_name != "death": return
	if not is_instance_valid(animated_sprite): return
	if not animated_sprite.sprite_frames.has_animation(anim_name):
		printerr("ERROR (Calculator): Animation '", anim_name, "' not found!")
		return

	if animated_sprite.animation != anim_name:
		animated_sprite.play(anim_name)


# --- Signal Handlers ---
func _on_animation_frame_changed():
	if not is_instance_valid(animated_sprite): return
	if current_state == State.DEAD: return

	if current_state == State.PROTRACTOR_SLICE and \
	   animated_sprite.animation == "protractor_slice" and \
	   animated_sprite.frame == protractor_slice_sound_frame:
		play_sound(slice_attack_sfx_player, protractor_slice_sounds)


func _on_animation_finished() -> void:
	if not is_instance_valid(animated_sprite): return
	var finished_anim = animated_sprite.animation

	if finished_anim == "pencil_jab":
		if is_instance_valid(pencil_hitbox_shape): pencil_hitbox_shape.set_deferred("disabled", true)
		attack_hit_registered = false
	elif finished_anim == "protractor_slice":
		if is_instance_valid(protractor_hitbox_shape): protractor_hitbox_shape.set_deferred("disabled", true)
		attack_hit_registered = false

	if current_state == State.DEAD: return

	if player_is_dead:
		_go_to_idle_state()
		return

	match finished_anim:
		"pencil_jab":
			if current_state == State.PENCIL_JAB: _go_to_idle_state(true)
		"protractor_slice":
			if current_state == State.PROTRACTOR_SLICE: _go_to_idle_state(true)
		"error":
			if current_state == State.ERROR: _go_to_idle_state(false)
		"multiplication_buff":
			if current_state == State.MULTIPLY_BUFF: _go_to_idle_state(true)
		"move_start":
			if current_state == State.MOVE:
				play_animation("move_loop")
			else: # If state changed during move_start (e.g., player died, decided action)
				_go_to_idle_state()
		"death":
			print("Calculator death animation finished.")
		_:
			if current_state != State.IDLE and current_state != State.MOVE:
				_go_to_idle_state()

# MODIFIED: Hitbox callbacks send direction vector
func _on_pencil_hitbox_body_entered(body: Node2D):
	if current_state != State.PENCIL_JAB or not is_instance_valid(pencil_hitbox_shape) or pencil_hitbox_shape.disabled or attack_hit_registered: return
	if body.is_in_group("player") and body.has_method("is_invulnerable") and body.has_method("take_damage"):
		if body.is_invulnerable(): return

		print("Calculator hitting player with Pencil Jab")
		play_sound(hit_player_sfx_player, pencil_hit_sounds)
		# Calculate direction FROM calculator TO player
		var knockback_dir = (body.global_position - global_position).normalized()
		body.call("take_damage", pencil_jab_damage, knockback_dir) # Send DIRECTION
		attack_hit_registered = true
		pencil_hitbox_shape.set_deferred("disabled", true)

# MODIFIED: Hitbox callbacks send direction vector
func _on_protractor_hitbox_body_entered(body: Node2D):
	if current_state != State.PROTRACTOR_SLICE or not is_instance_valid(protractor_hitbox_shape) or protractor_hitbox_shape.disabled or attack_hit_registered: return
	if body.is_in_group("player") and body.has_method("is_invulnerable") and body.has_method("take_damage"):
		if body.is_invulnerable(): return

		print("Calculator hitting player with Protractor Slice")
		play_sound(hit_player_sfx_player, protractor_hit_sounds)
		# Calculate direction FROM calculator TO player
		var knockback_dir = (body.global_position - global_position).normalized()
		body.call("take_damage", protractor_slice_damage, knockback_dir) # Send DIRECTION
		attack_hit_registered = true
		protractor_hitbox_shape.set_deferred("disabled", true)


func _on_player_died():
	# print("DEBUG: Calculator received player died signal.")
	player_node = null
	player_died_connected = false
	player_is_dead = true
	prioritize_vertical = false # Ensure flag is off

	if current_state == State.IDLE or current_state == State.MOVE:
		_go_to_idle_state()

	if is_instance_valid(pencil_hitbox_shape): pencil_hitbox_shape.set_deferred("disabled", true)
	if is_instance_valid(protractor_hitbox_shape): protractor_hitbox_shape.set_deferred("disabled", true)
	attack_hit_registered = false

	_expire_buff()


func _go_to_idle_state(allow_immediate_action: bool = false):
	if current_state != State.DEAD:
		current_state = State.IDLE
		prioritize_vertical = false # Ensure flag is off when going idle
		play_animation("idle")
		velocity = velocity.move_toward(Vector2.ZERO, 1000)
		can_act = allow_immediate_action

		if not allow_immediate_action:
			ai_timer = ai_cooldown * randf_range(0.3, 0.6)
		else:
			ai_timer = ai_cooldown * randf_range(0.05, 0.2)
