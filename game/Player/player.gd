# --- player.gd ---
extends CharacterBody2D

# Movement Parameters
@export var speed: float = 150.0
@export var jump_velocity: float = -400.0
@export var roll_speed: float = 350.0

# Attack Parameters
@export var attack_hit_frame: int = 4 # Frame index (0-based) where attack connects
@export var attack_sound_frame: int = 3 # Frame index (0-based) to play whoosh sound
@export var attack_damage: int = 10

# Stats
@export var max_hp: int = 100
var current_hp: int

@export var max_stamina: int = 100
var current_stamina: float # Float for smooth regen
@export var stamina_regen_rate: float = 25.0
@export var stamina_regen_delay: float = 1.0
@export var roll_stamina_cost: int = 25
@export var attack_stamina_cost: int = 15
@export var jump_stamina_cost: int = 10

# --- Knockback ---
@export var knockback_strength: float = 200.0 # Control knockback force

# --- Audio Resources ---
@export_group("Audio Streams")
@export var attack_sounds: Array[AudioStream] = [] # Assign Sword Whoosh 1-4 here
@export var attack_grunts: Array[AudioStream] = [] # Assign Breathy Grunt 1-2, Breathy Hm
@export var jump_grunt_sounds: Array[AudioStream] = [] # Assign Jump Grunt
@export var damage_grunt_sounds: Array[AudioStream] = [] # Assign Ahh 1-2, Mmm Hurt, Fuck
@export var death_sounds: Array[AudioStream] = [] # Assign Death 1-2
# Add roll sounds if you have them
# @export var roll_sounds: Array[AudioStream] = []

@export_group("Audio Settings")
@export var min_pitch: float = 0.95
@export var max_pitch: float = 1.10

# Signals for UI
signal hp_changed(current_value, max_value)
signal stamina_changed(current_value, max_value)
signal died

# Physics
var gravity: float = ProjectSettings.get_setting("physics/2d/default_gravity")

# State Flags
var is_rolling: bool = false
var is_attacking: bool = false
var is_hit: bool = false
var is_dead: bool = false
var is_holding_fall_frame: bool = false

# Timers
var stamina_regen_timer: float = 0.0

# Tracking hits
var enemies_hit_this_swing: Array = []

# Node References (Ensure nodes exist with these names/paths)
@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var attack_hitbox: Area2D = $AttackHitbox
@onready var attack_hitbox_shape: CollisionShape2D = $AttackHitbox/CollisionShape2D
@onready var collision_shape_main: CollisionShape2D = $CollisionShape2D

# --- Audio Player Node References ---
@onready var attack_sfx_player: AudioStreamPlayer2D = $AttackSFXPlayer
@onready var grunt_sfx_player: AudioStreamPlayer2D = $GruntSFXPlayer
@onready var movement_sfx_player: AudioStreamPlayer2D = $MovementSFXPlayer # For jump/roll
@onready var damage_sfx_player: AudioStreamPlayer2D = $DamageSFXPlayer
@onready var death_sfx_player: AudioStreamPlayer2D = $DeathSFXPlayer


# --- Initialization ---
func _ready() -> void:
	current_hp = max_hp
	current_stamina = float(max_stamina)
	add_to_group("player") # Add player to group for easy finding

	# Validate crucial nodes
	if not is_instance_valid(animated_sprite):
		printerr("ERROR (Player): AnimatedSprite2D node not found!")
		set_process(false) # Disable script if core components missing
		set_physics_process(false)
		return
	if not is_instance_valid(attack_hitbox):
		printerr("ERROR (Player): AttackHitbox Area2D not found!")
		# Can continue, but attack won't work
	if not is_instance_valid(attack_hitbox_shape):
		printerr("ERROR (Player): AttackHitbox Shape not found!")
		# Can continue, but attack won't work
	else:
		attack_hitbox_shape.disabled = true # Ensure hitbox starts disabled

	if not is_instance_valid(collision_shape_main):
		printerr("ERROR (Player): Main CollisionShape2D not found!")
		# Cannot function without collision

	# Connect signals safely
	if not animated_sprite.animation_finished.is_connected(Callable(self, "_on_animation_finished")):
		animated_sprite.animation_finished.connect(Callable(self, "_on_animation_finished"))
	if not animated_sprite.frame_changed.is_connected(Callable(self, "_on_animation_frame_changed")):
		animated_sprite.frame_changed.connect(Callable(self, "_on_animation_frame_changed"))

	if is_instance_valid(attack_hitbox):
		if not attack_hitbox.area_entered.is_connected(Callable(self, "_on_attack_hitbox_area_entered")):
			attack_hitbox.area_entered.connect(Callable(self, "_on_attack_hitbox_area_entered"))

	# Initial UI update
	emit_signal("hp_changed", current_hp, max_hp)
	emit_signal("stamina_changed", current_stamina, max_stamina)

	# Audio node validation (optional, but good practice)
	if not is_instance_valid(attack_sfx_player): printerr("WARNING (Player): AttackSFXPlayer node not found!")
	if not is_instance_valid(grunt_sfx_player): printerr("WARNING (Player): GruntSFXPlayer node not found!")
	if not is_instance_valid(movement_sfx_player): printerr("WARNING (Player): MovementSFXPlayer node not found!")
	if not is_instance_valid(damage_sfx_player): printerr("WARNING (Player): DamageSFXPlayer node not found!")
	if not is_instance_valid(death_sfx_player): printerr("WARNING (Player): DeathSFXPlayer node not found!")

# --- Audio Helper ---
func play_sound(player_node: AudioStreamPlayer2D, sound_variations: Array, p_min_pitch: float = min_pitch, p_max_pitch: float = max_pitch) -> void:
	if not is_instance_valid(player_node): return
	if sound_variations.is_empty(): return

	var sound_stream = sound_variations.pick_random()
	if not sound_stream is AudioStream:
		printerr("Warning (Player): Invalid item in sound variations array for player: ", player_node.name)
		return

	player_node.stream = sound_stream
	player_node.pitch_scale = randf_range(p_min_pitch, p_max_pitch)
	player_node.play()

# --- Non-Physics Updates ---
func _process(delta: float) -> void:
	if is_dead: return # Stop processing if dead

	# Regenerate stamina if conditions met
	if not is_rolling and not is_attacking:
		if stamina_regen_timer > 0:
			stamina_regen_timer -= delta
		elif current_stamina < max_stamina:
			var previous_stamina = current_stamina
			current_stamina = min(current_stamina + stamina_regen_rate * delta, float(max_stamina))
			if current_stamina != previous_stamina: # Only emit if value changed
				emit_signal("stamina_changed", current_stamina, max_stamina)

# --- Physics Updates ---
func _physics_process(delta: float) -> void:
	if is_dead: return # Physics stops upon death (_die handles this)

	var current_velocity = velocity # Start with current velocity

	# Apply gravity
	if not is_on_floor():
		current_velocity.y += gravity * delta

	# Handle states that override normal input/movement
	if handle_blocking_states(delta, current_velocity):
		# If a blocking state handled movement, apply its modified velocity
		velocity = current_velocity
		move_and_slide()
		update_animation() # Update animation based on current state
		return # Skip normal input handling

	# Handle regular input and movement
	var input_direction = Input.get_axis("move_left", "move_right")
	current_velocity = handle_input_and_movement(input_direction, current_velocity)

	# Apply final velocity and move
	velocity = current_velocity
	move_and_slide()

	# Update animation based on final velocity and state (after movement)
	update_animation()


# --- State/Movement Helpers ---
# MODIFIED: Takes velocity by value, returns true if blocked, modifies velocity directly
func handle_blocking_states(delta: float, current_velocity: Vector2) -> bool:
	var is_blocked = false

	if is_hit:
		# Gradual slowdown during hit state
		current_velocity.x = move_toward(current_velocity.x, 0, speed * 1.5 * delta)
		# Let gravity handle y velocity
		is_blocked = true
	elif is_rolling:
		# Roll velocity is set in initiate_roll and maintained by physics
		# (Gravity will affect it naturally if in the air)
		is_blocked = true
	elif is_attacking:
		# Slow down horizontally during attack
		current_velocity.x = move_toward(current_velocity.x, 0, speed * 0.8 * delta)
		is_blocked = true

	# If blocked, update the character's main velocity directly
	if is_blocked:
		velocity = current_velocity # Update main velocity property
		return true
	else:
		return false

# MODIFIED: Takes current velocity, returns the potentially modified velocity
func handle_input_and_movement(direction: float, current_velocity: Vector2) -> Vector2:
	var modified_velocity = current_velocity
	var acted = false # Flag to check if an action was taken that affects velocity

	# --- Handle Actions (Check conditions before initiating) ---
	# Roll
	if Input.is_action_just_pressed("roll") and is_on_floor() and current_stamina >= roll_stamina_cost:
		modified_velocity = initiate_roll(direction, modified_velocity)
		acted = true
	# Attack
	elif Input.is_action_just_pressed("attack") and is_on_floor() and current_stamina >= attack_stamina_cost:
		initiate_attack()
		acted = true # Attack state will handle velocity in handle_blocking_states
	# Jump
	elif Input.is_action_just_pressed("jump") and is_on_floor() and current_stamina >= jump_stamina_cost:
		modified_velocity = initiate_jump(modified_velocity)
		acted = true # Jump modifies velocity directly

	# --- Handle Horizontal Movement (Only if NOT performing an overriding action) ---
	# Apply horizontal movement based on input if not rolling or attacking
	if not is_rolling and not is_attacking:
		if direction != 0:
			modified_velocity.x = direction * speed
		else:
			# Apply friction/deceleration if no direction input
			modified_velocity.x = move_toward(modified_velocity.x, 0, speed) # Use speed as friction factor

	return modified_velocity

# --- Animation Control ---
func update_animation() -> void:
	# Don't change animation if in a fixed-animation state or if sprite is invalid
	if not is_instance_valid(animated_sprite): return
	if is_dead or is_hit or is_rolling or is_attacking: return

	var anim_to_play = "idle" # Default animation

	if is_on_floor():
		# Reset fall frame hold if landed
		if is_holding_fall_frame:
			is_holding_fall_frame = false
			# If sprite was stopped, ensure it plays the landing/idle animation
			if not animated_sprite.is_playing():
				anim_to_play = "idle" # Or a specific landing animation if you have one
				play_animation(anim_to_play) # Play immediately
				# Don't return yet, allow horizontal check below

		# Determine floor animation based on horizontal velocity
		if abs(velocity.x) > 5.0: anim_to_play = "run"
		else: anim_to_play = "idle"

	else: # In the air
		# Fall animation logic
		if velocity.y >= 0: # Moving downwards or stationary vertically
			if animated_sprite.animation != "fall":
				play_animation("fall") # Start fall animation
			# Check if we should hold the last frame
			var last_frame_index = animated_sprite.sprite_frames.get_frame_count("fall") - 1
			if animated_sprite.frame == last_frame_index and not is_holding_fall_frame:
				animated_sprite.stop() # Stop at the last frame
				is_holding_fall_frame = true
			# Don't change anim_to_play if falling/holding fall
			return # Exit early, fall logic handles itself
		# Jump animation logic
		elif velocity.y < 0: # Moving upwards
			anim_to_play = "jump"
			# Release hold if jumping up again
			if is_holding_fall_frame: is_holding_fall_frame = false


	# Play the determined animation if it's different from the current one
	if animated_sprite.animation != anim_to_play:
		play_animation(anim_to_play)

	# Flip sprite based on horizontal velocity (if moving), otherwise keep facing direction
	if abs(velocity.x) > 1.0: # Use a small threshold
		animated_sprite.flip_h = (velocity.x < 0)


# --- Action Initiation ---
# MODIFIED: Takes velocity, returns modified velocity
func initiate_roll(input_direction: float, current_velocity: Vector2) -> Vector2:
	if is_dead: return current_velocity # Cannot roll if dead

	# Consume stamina and reset delay
	current_stamina -= roll_stamina_cost
	emit_signal("stamina_changed", current_stamina, max_stamina)
	stamina_regen_timer = stamina_regen_delay

	# Set state flags
	is_rolling = true; is_attacking = false; is_hit = false; is_holding_fall_frame = false

	# Determine roll direction
	var roll_dir = input_direction if input_direction != 0 else (-1.0 if animated_sprite.flip_h else 1.0)
	animated_sprite.flip_h = (roll_dir < 0) # Flip sprite to match roll direction

	# Set velocity for the roll
	var modified_velocity = current_velocity
	modified_velocity.x = roll_dir * roll_speed
	modified_velocity.y = 0 # Ensure no vertical movement is initiated by the roll itself

	play_animation("roll")
	# play_sound(movement_sfx_player, roll_sounds) # Uncomment if you have roll sounds

	return modified_velocity # Return the velocity set by the roll


func initiate_attack() -> void:
	if is_dead: return # Cannot attack if dead

	# Consume stamina and reset delay
	current_stamina -= attack_stamina_cost
	emit_signal("stamina_changed", current_stamina, max_stamina)
	stamina_regen_timer = stamina_regen_delay

	# Set state flags
	is_attacking = true; is_rolling = false; is_hit = false; is_holding_fall_frame = false
	enemies_hit_this_swing.clear() # Reset hit list for this attack

	# Play attack animation and grunt sound
	play_animation("attack")
	play_sound(grunt_sfx_player, attack_grunts)
	# Sword Whoosh sound is played via _on_animation_frame_changed


# MODIFIED: Takes velocity, returns modified velocity
func initiate_jump(current_velocity: Vector2) -> Vector2:
	if is_dead: return current_velocity # Cannot jump if dead

	# Consume stamina and reset delay
	current_stamina -= jump_stamina_cost
	emit_signal("stamina_changed", current_stamina, max_stamina)
	stamina_regen_timer = stamina_regen_delay

	# Apply jump velocity
	var modified_velocity = current_velocity
	modified_velocity.y = jump_velocity

	# Reset fall state flags
	is_holding_fall_frame = false
	if is_instance_valid(animated_sprite) and not animated_sprite.is_playing():
		animated_sprite.play() # Ensure sprite plays if it was stopped (e.g., held fall)

	play_animation("jump") # Play jump animation immediately
	play_sound(movement_sfx_player, jump_grunt_sounds)

	return modified_velocity # Return the velocity affected by the jump


# --- Animation Playback Helper ---
func play_animation(anim_name: String) -> void:
	if not is_instance_valid(animated_sprite): return
	# Do not change animation if dead, unless playing the 'dead' animation itself
	if is_dead and anim_name != "dead": return

	if animated_sprite.sprite_frames.has_animation(anim_name):
		# Only play if the animation is different, or if it needs restarting (like attack)
		# Exception: Allow re-playing 'fall' to handle the hold logic correctly
		if animated_sprite.animation != anim_name or anim_name == "fall":
			animated_sprite.play(anim_name)
			# If starting an animation other than fall, release the hold flag
			if anim_name != "fall" and is_holding_fall_frame:
				is_holding_fall_frame = false

	else:
		printerr("ERROR (Player): Animation '", anim_name, "' not found!")

# --- Animation Signal Callbacks ---
func _on_animation_frame_changed():
	if is_dead or not is_instance_valid(animated_sprite): return

	# Handle attack hitbox and sound timing based on current frame
	if is_attacking and animated_sprite.animation == "attack":
		var current_frame = animated_sprite.frame

		# Play attack sound on specific frame
		if current_frame == attack_sound_frame:
			play_sound(attack_sfx_player, attack_sounds)

		# Enable/disable hitbox based on frame
		if is_instance_valid(attack_hitbox_shape):
			# Enable hitbox at the designated frame
			if current_frame == attack_hit_frame:
				if attack_hitbox_shape.disabled:
					attack_hitbox_shape.disabled = false
			# Disable hitbox AFTER the hit frame
			# Important: Could also disable in _on_animation_finished for safety
			elif current_frame > attack_hit_frame:
				if not attack_hitbox_shape.disabled:
					attack_hitbox_shape.disabled = true


func _on_animation_finished() -> void:
	if is_dead or not is_instance_valid(animated_sprite): return

	var finished_anim = animated_sprite.animation

	# Ensure attack hitbox is reliably disabled when attack animation finishes
	if finished_anim == "attack":
		if is_instance_valid(attack_hitbox_shape) and not attack_hitbox_shape.disabled:
			# Use call_deferred for safety if physics issues arise, but direct should be fine here
			attack_hitbox_shape.disabled = true
		_end_attack() # Transition out of attack state

	# Handle state transitions based on which animation finished
	match finished_anim:
		"roll": _end_roll()
		"hit": _end_hit()
		"jump":
			# If jump animation finishes but still moving up, do nothing special.
			# If starting to fall, update_animation logic should handle switching to "fall".
			pass
		"fall":
			# If fall animation finishes (unlikely unless 1 frame?), ensure hold logic is reset
			# If on floor, update_animation handles idle/run. If still airborne, should ideally loop or hold.
			# The hold logic in update_animation should prevent this callback causing issues.
			if not is_on_floor() and not is_holding_fall_frame:
				# If somehow it finished while airborne without holding, replay and hold
				play_animation("fall")
		"dead":
			# Animation finished, character remains in dead state. Stop sprite updates.
			animated_sprite.stop()
			# set_process(false) # Optional: further disable processing

# --- State Ending Functions ---
func _end_roll() -> void:
	if is_rolling: is_rolling = false

func _end_attack() -> void:
	if is_attacking: is_attacking = false
	# Final check to ensure hitbox is off
	if is_instance_valid(attack_hitbox_shape) and not attack_hitbox_shape.disabled:
		attack_hitbox_shape.set_deferred("disabled", true)

func _end_hit() -> void:
	if is_hit: is_hit = false


# --- Damage & Death ---
# MODIFIED: take_damage now accepts knockback source position
func take_damage(amount: int, damage_source_position: Vector2 = global_position) -> void:
	# Check for invulnerability states
	if is_invulnerable(): return

	current_hp = max(0, current_hp - amount) # Prevent negative HP
	emit_signal("hp_changed", current_hp, max_hp)
	# print("Player took damage:", amount, "| HP:", current_hp, "/", max_hp, "| From:", damage_source_position) # Debug

	play_sound(damage_sfx_player, damage_grunt_sounds)

	# Reset attack/roll states and stamina delay
	is_attacking = false; is_rolling = false; is_holding_fall_frame = false
	stamina_regen_timer = stamina_regen_delay
	if is_instance_valid(attack_hitbox_shape):
		attack_hitbox_shape.set_deferred("disabled", true) # Ensure hitbox off

	if current_hp <= 0:
		_die() # Trigger death sequence
	else:
		# Enter hit state
		is_hit = true
		play_animation("hit")

		# Apply knockback based on the source position
		var knockback_direction = (global_position - damage_source_position).normalized()
		# Handle case where source is exactly the same position
		if knockback_direction == Vector2.ZERO:
			knockback_direction = Vector2(1.0 if randf() > 0.5 else -1.0, -0.5).normalized() # Random direction with upward bias

		# Apply knockback force (can be adjusted)
		velocity.x = knockback_direction.x * knockback_strength
		velocity.y = knockback_direction.y * knockback_strength * 0.6 - 120 # Add slight upward boost

# Helper function to check invulnerability conditions
func is_invulnerable() -> bool:
	# Player is invulnerable if rolling, already hit, or dead
	return is_rolling or is_hit or is_dead

func _die() -> void:
	if is_dead: return # Prevent multiple deaths
	is_dead = true
	print("Player Died!")

	# Clear all active states
	is_hit = false; is_rolling = false; is_attacking = false; is_holding_fall_frame = false
	velocity = Vector2.ZERO # Stop all movement immediately

	play_animation("dead")
	play_sound(death_sfx_player, death_sounds)
	emit_signal("died") # Signal game systems

	# Disable collisions and physics processing safely
	if is_instance_valid(collision_shape_main):
		collision_shape_main.set_deferred("disabled", true)
	if is_instance_valid(attack_hitbox_shape):
		attack_hitbox_shape.set_deferred("disabled", true)

	set_physics_process(false) # Stop physics updates for this node


# --- Hitbox Interaction ---
func _on_attack_hitbox_area_entered(area: Area2D):
	# Ensure hitbox is active, player is attacking, and not dead
	if is_dead or not is_attacking or not is_instance_valid(attack_hitbox_shape) or attack_hitbox_shape.disabled:
		return

	# Check if the entered area belongs to an enemy
	if area.is_in_group("enemy_hurtbox"):
		# Get the owner (should be the main enemy script)
		var enemy_node = area.get_owner()

		# Validate the enemy node
		if not is_instance_valid(enemy_node):
			printerr("WARNING (Player): Hit enemy hurtbox without valid owner:", area.name)
			return # Cannot apply damage without a valid owner

		# Ensure enemy can take damage and hasn't been hit by this specific swing yet
		if enemy_node.has_method("take_damage") and not enemies_hit_this_swing.has(area):
			# print("Player attacking:", enemy_node.name) # Debug

			# Call the enemy's take_damage method, passing damage and source position
			# The enemy will calculate knockback direction from this source
			enemy_node.call("take_damage", attack_damage, global_position)

			# Add the specific hurtbox area to the list to prevent multi-hits per swing
			enemies_hit_this_swing.append(area)


# --- Convenience getters (Optional, but can be useful) ---
func get_current_hp() -> int:
	return current_hp

func get_current_stamina() -> float:
	return current_stamina
