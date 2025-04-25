# --- player.gd ---
extends CharacterBody2D

# Movement Parameters
@export var speed: float = 150.0
@export var jump_velocity: float = -600.0
@export var roll_speed: float = 350.0

# Attack Parameters
@export var attack_hit_frame: int = 4 # Frame index (0-based) where attack connects
@export var attack_sound_frame: int = 3 # Frame index (0-based) to play whoosh sound
@export var attack_damage: int = 10

# Item Usage Parameters
@export var initial_item_count: int = 2
@export var item_heal_amount: int = 50
@export var use_item_effect_frame: int = 12 # Frame index (0-based) for heal effect
@export var use_item_speed_multiplier: float = 0.5 # Speed reduction while using item

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
# No stamina cost for using item in this version

# --- Knockback ---
@export var knockback_strength: float = 200.0 # Control knockback force

# --- Audio Resources ---
@export_group("Audio Streams")
@export var attack_sounds: Array[AudioStream] = [] # Assign Sword Whoosh 1-4 here
@export var attack_grunts: Array[AudioStream] = [] # Assign Breathy Grunt 1-2, Breathy Hm
@export var jump_grunt_sounds: Array[AudioStream] = [] # Assign Jump Grunt
@export var damage_grunt_sounds: Array[AudioStream] = [] # Assign Ahh 1-2, Mmm Hurt, Fuck
@export var death_sounds: Array[AudioStream] = [] # Assign Death 1-2
# Add use item sounds if you have them
# @export var use_item_sounds: Array[AudioStream] = []

@export_group("Audio Settings")
@export var min_pitch: float = 0.95
@export var max_pitch: float = 1.10

# Signals for UI
signal hp_changed(current_value, max_value)
signal stamina_changed(current_value, max_value)
signal item_count_changed(new_count) # Signal for item count updates
signal died

# Physics
var gravity: float = ProjectSettings.get_setting("physics/2d/default_gravity")

# State Flags
var is_rolling: bool = false
var is_attacking: bool = false
var is_hit: bool = false
var is_dead: bool = false # Master flag for being dead
var is_using_item: bool = false # New state flag for item usage
var is_holding_fall_frame: bool = false

# Timers
var stamina_regen_timer: float = 0.0

# Tracking hits
var enemies_hit_this_swing: Array = []

# Item Inventory
var item_count: int

# Node References (Ensure nodes exist with these names/paths)
@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var attack_hitbox: Area2D = $AttackHitbox
@onready var attack_hitbox_shape: CollisionShape2D = $AttackHitbox/CollisionShape2D
@onready var collision_shape_main: CollisionShape2D = $CollisionShape2D

# --- Audio Player Node References ---
@onready var attack_sfx_player: AudioStreamPlayer2D = $AttackSFXPlayer
@onready var grunt_sfx_player: AudioStreamPlayer2D = $GruntSFXPlayer
@onready var movement_sfx_player: AudioStreamPlayer2D = $MovementSFXPlayer # For jump/roll/item use?
@onready var damage_sfx_player: AudioStreamPlayer2D = $DamageSFXPlayer
@onready var death_sfx_player: AudioStreamPlayer2D = $DeathSFXPlayer


# --- Initialization ---
func _ready() -> void:
	current_hp = max_hp
	current_stamina = float(max_stamina)
	item_count = initial_item_count # Initialize item count
	add_to_group("player") # Add player to group for easy finding

	# Validate crucial nodes
	if not is_instance_valid(animated_sprite):
		printerr("ERROR (Player): AnimatedSprite2D node not found!")
		set_process(false) # Disable script if core components missing
		set_physics_process(false)
		return
	if not is_instance_valid(attack_hitbox):
		printerr("ERROR (Player): AttackHitbox Area2D not found!")
	if not is_instance_valid(attack_hitbox_shape):
		printerr("ERROR (Player): AttackHitbox Shape not found!")
	else:
		attack_hitbox_shape.disabled = true # Ensure hitbox starts disabled

	if not is_instance_valid(collision_shape_main):
		printerr("ERROR (Player): Main CollisionShape2D not found!")

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
	emit_signal("item_count_changed", item_count) # Emit initial item count

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
	# Stop non-physics processing if dead
	if is_dead: return

	# Regenerate stamina if conditions met (cannot regen while using item either)
	if not is_rolling and not is_attacking and not is_using_item:
		if stamina_regen_timer > 0:
			stamina_regen_timer -= delta
		elif current_stamina < max_stamina:
			var previous_stamina = current_stamina
			current_stamina = min(current_stamina + stamina_regen_rate * delta, float(max_stamina))
			if current_stamina != previous_stamina: # Only emit if value changed
				emit_signal("stamina_changed", current_stamina, max_stamina)

# --- Physics Updates ---
func _physics_process(delta: float) -> void:
	# --- Special Handling for Death Sequence ---
	if is_dead:
		# Apply gravity constantly while dead and airborne
		velocity.y += gravity * delta

		# Keep horizontal velocity zero after death
		velocity.x = 0

		move_and_slide()

		# Check if landed after dying
		if is_on_floor():
			# Once landed, stop physics processing completely
			set_physics_process(false)
			# print("Player corpse landed. Stopping physics.") # Debug

		# Skip all other physics processing during death sequence
		return
	# --- End of Death Sequence Handling ---


	# --- Normal Physics Processing ---
	var current_velocity = velocity # Start with current velocity

	# Apply gravity (only if not dead and not on floor)
	if not is_on_floor():
		current_velocity.y += gravity * delta

	# Handle states that override normal input/movement
	var blocked = handle_blocking_states(delta)

	# Handle regular input and movement ONLY if not blocked by a state
	if not blocked:
		var input_direction = Input.get_axis("move_left", "move_right")
		current_velocity = handle_input_and_movement(input_direction, current_velocity)

	# Apply final velocity and move
	velocity = current_velocity
	move_and_slide()

	# Update animation based on final velocity and state (after movement)
	update_animation()


# --- State/Movement Helpers ---
# MODIFIED: Returns true if blocked, modifies velocity directly for blocking states
func handle_blocking_states(delta: float) -> bool:
	var is_blocked = false
	var modified_velocity = velocity # Work with a copy

	if is_hit:
		# Gradual slowdown during hit state
		modified_velocity.x = move_toward(modified_velocity.x, 0, speed * 1.5 * delta)
		# Let gravity handle y velocity
		is_blocked = true
	elif is_rolling:
		# Roll velocity is set in initiate_roll and maintained by physics
		is_blocked = true
	elif is_attacking:
		# Slow down horizontally during attack
		modified_velocity.x = move_toward(modified_velocity.x, 0, speed * 0.8 * delta)
		is_blocked = true
	elif is_using_item:
		# Allow slow horizontal movement based on input during item use
		var input_direction = Input.get_axis("move_left", "move_right")
		if input_direction != 0:
			modified_velocity.x = input_direction * speed * use_item_speed_multiplier
			# Flip sprite based on movement direction during item use
			if is_instance_valid(animated_sprite):
				animated_sprite.flip_h = (input_direction < 0)
		else:
			modified_velocity.x = move_toward(modified_velocity.x, 0, speed) # Slow down if no input
		# Allow gravity while using item if airborne (though initiation might be restricted)
		is_blocked = true

	# Apply changes back to the main velocity property if blocked
	if is_blocked:
		velocity = modified_velocity
		return true
	else:
		return false

# MODIFIED: Takes current velocity, returns the potentially modified velocity
# Handles input checks for actions and default movement when not blocked
func handle_input_and_movement(direction: float, current_velocity: Vector2) -> Vector2:
	var modified_velocity = current_velocity
	var acted = false # Flag to check if an action was taken that affects velocity

	# --- Handle Actions (Check conditions before initiating) ---
	# Use Item
	if Input.is_action_just_pressed("use_item") and can_use_item():
		initiate_use_item()
		acted = true # Use item state handled by handle_blocking_states
	# Roll
	elif Input.is_action_just_pressed("roll") and is_on_floor() and current_stamina >= roll_stamina_cost:
		modified_velocity = initiate_roll(direction, modified_velocity)
		acted = true
	# Attack
	elif Input.is_action_just_pressed("attack") and is_on_floor() and current_stamina >= attack_stamina_cost:
		initiate_attack()
		acted = true # Attack state handled by handle_blocking_states
	# Jump
	elif Input.is_action_just_pressed("jump") and is_on_floor() and current_stamina >= jump_stamina_cost:
		modified_velocity = initiate_jump(modified_velocity)
		acted = true # Jump modifies velocity directly

	# --- Handle Horizontal Movement (Only if NOT performing an overriding action) ---
	if not acted: # Only apply default movement if no other action was just initiated
		if direction != 0:
			modified_velocity.x = direction * speed
		else:
			# Apply friction/deceleration if no direction input
			modified_velocity.x = move_toward(modified_velocity.x, 0, speed)

	return modified_velocity

# --- Condition Checkers ---
func can_use_item() -> bool:
	# Check if player is in a state that allows using items
	# Must be on floor (can be changed), have items, not full hp, and not in another blocking state
	return is_on_floor() and \
		   item_count > 0 and \
		   current_hp < max_hp and \
		   not is_rolling and \
		   not is_attacking and \
		   not is_hit and \
		   not is_dead and \
		   not is_using_item

# --- Animation Control ---
func update_animation() -> void:
	# Don't change animation if in a fixed-animation state or if sprite is invalid
	if not is_instance_valid(animated_sprite): return
	# NOTE: is_dead check removed here, as the death animation needs to play while falling
	if is_hit or is_rolling or is_attacking or is_using_item: return

	var anim_to_play = "idle" # Default animation

	if is_on_floor():
		if is_holding_fall_frame:
			is_holding_fall_frame = false
			if not animated_sprite.is_playing():
				anim_to_play = "idle"
				play_animation(anim_to_play)

		if abs(velocity.x) > 5.0: anim_to_play = "run"
		else: anim_to_play = "idle"

	else: # In the air
		if velocity.y >= 0:
			if animated_sprite.animation != "fall":
				play_animation("fall")
			var last_frame_index = animated_sprite.sprite_frames.get_frame_count("fall") - 1
			if animated_sprite.frame == last_frame_index and not is_holding_fall_frame:
				animated_sprite.stop()
				is_holding_fall_frame = true
			return
		elif velocity.y < 0:
			anim_to_play = "jump"
			if is_holding_fall_frame: is_holding_fall_frame = false

	if animated_sprite.animation != anim_to_play:
		play_animation(anim_to_play)

	# Flip sprite based on horizontal velocity (if moving), otherwise keep facing direction
	# Do not flip if idle and not moving
	if abs(velocity.x) > 1.0:
		animated_sprite.flip_h = (velocity.x < 0)


# --- Action Initiation ---
# MODIFIED: Takes velocity, returns modified velocity
func initiate_roll(input_direction: float, current_velocity: Vector2) -> Vector2:
	if is_dead: return current_velocity # Cannot roll if dead

	current_stamina -= roll_stamina_cost
	emit_signal("stamina_changed", current_stamina, max_stamina)
	stamina_regen_timer = stamina_regen_delay

	is_rolling = true; is_attacking = false; is_hit = false; is_using_item = false; is_holding_fall_frame = false

	var roll_dir = input_direction if input_direction != 0 else (-1.0 if animated_sprite.flip_h else 1.0)
	animated_sprite.flip_h = (roll_dir < 0)

	var modified_velocity = current_velocity
	modified_velocity.x = roll_dir * roll_speed
	modified_velocity.y = 0 # Roll cancels vertical momentum on initiation if on floor

	play_animation("roll")
	# play_sound(movement_sfx_player, roll_sounds) # Uncomment if you have roll sounds

	return modified_velocity


func initiate_attack() -> void:
	if is_dead: return # Cannot attack if dead

	current_stamina -= attack_stamina_cost
	emit_signal("stamina_changed", current_stamina, max_stamina)
	stamina_regen_timer = stamina_regen_delay

	is_attacking = true; is_rolling = false; is_hit = false; is_using_item = false; is_holding_fall_frame = false
	enemies_hit_this_swing.clear()

	play_animation("attack")
	play_sound(grunt_sfx_player, attack_grunts)


# MODIFIED: Takes velocity, returns modified velocity
func initiate_jump(current_velocity: Vector2) -> Vector2:
	if is_dead: return current_velocity # Cannot jump if dead

	current_stamina -= jump_stamina_cost
	emit_signal("stamina_changed", current_stamina, max_stamina)
	stamina_regen_timer = stamina_regen_delay

	var modified_velocity = current_velocity
	modified_velocity.y = jump_velocity

	is_holding_fall_frame = false
	if is_instance_valid(animated_sprite) and not animated_sprite.is_playing():
		animated_sprite.play()

	play_animation("jump") # Play jump animation immediately
	play_sound(movement_sfx_player, jump_grunt_sounds)

	return modified_velocity

# --- MODIFIED: Initiate Item Use (Doesn't consume item here) ---
func initiate_use_item() -> void:
	if is_dead: return # Cannot use if dead

	# Item is NO LONGER consumed here
	stamina_regen_timer = stamina_regen_delay # Using item resets stamina delay

	# Set state flags
	is_using_item = true; is_rolling = false; is_attacking = false; is_hit = false; is_holding_fall_frame = false

	play_animation("use")
	# play_sound(movement_sfx_player, use_item_sounds) # Uncomment if you have sounds


# --- Animation Playback Helper ---
func play_animation(anim_name: String) -> void:
	if not is_instance_valid(animated_sprite): return
	# MODIFICATION: Allow playing "dead" animation even if already dead
	if is_dead and anim_name != "dead": return

	if animated_sprite.sprite_frames.has_animation(anim_name):
		# Play if different, or if it's an interruptible animation
		if animated_sprite.animation != anim_name or ["fall", "attack", "roll", "use", "hit", "dead"].has(anim_name):
			animated_sprite.play(anim_name)
			if anim_name != "fall" and is_holding_fall_frame:
				is_holding_fall_frame = false
	else:
		printerr("ERROR (Player): Animation '", anim_name, "' not found!")

# --- Animation Signal Callbacks ---
func _on_animation_frame_changed():
	# Allow frame changes even if dead (for death animation)
	if not is_instance_valid(animated_sprite): return
	if is_dead: return # No effects trigger during death anim frames

	var current_anim = animated_sprite.animation
	var current_frame = animated_sprite.frame

	# Handle attack hitbox and sound timing based on current frame
	if is_attacking and current_anim == "attack":
		if current_frame == attack_sound_frame:
			play_sound(attack_sfx_player, attack_sounds)
		if is_instance_valid(attack_hitbox_shape):
			if current_frame == attack_hit_frame:
				if attack_hitbox_shape.disabled: attack_hitbox_shape.disabled = false
			elif current_frame > attack_hit_frame: # Disable after hit frame
				if not attack_hitbox_shape.disabled: attack_hitbox_shape.disabled = true

	# --- MODIFIED: Handle item effect timing AND consumption ---
	elif is_using_item and current_anim == "use":
		if current_frame == use_item_effect_frame:
			# --- Consume item ONLY when effect frame is reached ---
			if item_count > 0: # Double check we still have items
				item_count -= 1
				emit_signal("item_count_changed", item_count) # Notify UI
				# print("Consumed item. Remaining:", item_count) # Debug

				# Apply healing effect
				var hp_before_heal = current_hp
				current_hp = min(current_hp + item_heal_amount, max_hp)
				# Only emit signal if HP actually changed
				if current_hp != hp_before_heal:
					emit_signal("hp_changed", current_hp, max_hp)
				# print("Used item, healed to:", current_hp) # Debug

# --- MODIFIED: _on_animation_finished ---
func _on_animation_finished() -> void:
	# Allow processing even if dead (to stop the death animation)
	if not is_instance_valid(animated_sprite): return

	var finished_anim = animated_sprite.animation

	# Ensure attack hitbox is reliably disabled
	if finished_anim == "attack":
		if is_instance_valid(attack_hitbox_shape) and not attack_hitbox_shape.disabled:
			attack_hitbox_shape.set_deferred("disabled", true)
		# Only end attack state if not dead
		if not is_dead: _end_attack()

	# Handle state transitions based on which animation finished
	# Only transition states if NOT dead
	if not is_dead:
		match finished_anim:
			"roll": _end_roll()
			"hit": _end_hit()
			"use": _end_use_item()
			"jump": pass # Jump animation finishing doesn't imply landing
			"fall":
				if not is_on_floor() and not is_holding_fall_frame:
					play_animation("fall")
	elif finished_anim == "dead":
		# --- FIX: Stop animation on the last frame ---
		if animated_sprite.sprite_frames.has_animation("dead"):
			var last_frame_index = animated_sprite.sprite_frames.get_frame_count("dead") - 1
			# Check if frame index is valid before setting
			if last_frame_index >= 0:
				animated_sprite.frame = last_frame_index


# --- State Ending Functions ---
func _end_roll() -> void:
	if is_rolling: is_rolling = false

func _end_attack() -> void:
	if is_attacking: is_attacking = false
	if is_instance_valid(attack_hitbox_shape) and not attack_hitbox_shape.disabled:
		attack_hitbox_shape.set_deferred("disabled", true)

func _end_hit() -> void:
	if is_hit: is_hit = false

# --- NEW: End Item Use State ---
func _end_use_item() -> void:
	if is_using_item: is_using_item = false


# --- Damage & Death ---
# MODIFIED: take_damage now accepts knockback source position
func take_damage(amount: int, damage_source_position: Vector2 = global_position) -> void:
	# Check for invulnerability states
	if is_invulnerable(): return

	current_hp = max(0, current_hp - amount) # Prevent negative HP
	emit_signal("hp_changed", current_hp, max_hp)
	# print("Player took damage:", amount, "| HP:", current_hp, "/", max_hp, "| From:", damage_source_position) # Debug

	play_sound(damage_sfx_player, damage_grunt_sounds)

	# Reset active states, including item use if hit during it
	# This prevents the item effect from triggering if hit before the effect frame
	is_attacking = false; is_rolling = false; is_holding_fall_frame = false; is_using_item = false
	stamina_regen_timer = stamina_regen_delay
	if is_instance_valid(attack_hitbox_shape):
		attack_hitbox_shape.set_deferred("disabled", true) # Ensure hitbox off

	if current_hp <= 0:
		_die() # Trigger death sequence
	else:
		# Enter hit state
		is_hit = true
		play_animation("hit") # Play hit animation, interrupting any previous animation like "use"

		# Apply knockback based on the source position
		var knockback_direction = (global_position - damage_source_position).normalized()
		if knockback_direction == Vector2.ZERO:
			knockback_direction = Vector2(1.0 if randf() > 0.5 else -1.0, -0.5).normalized()

		velocity.x = knockback_direction.x * knockback_strength
		velocity.y = knockback_direction.y * knockback_strength * 0.6 - 120

# Helper function to check invulnerability conditions
# Using item does NOT grant invulnerability here. Player is NOT invulnerable when dead either (for collision purposes).
func is_invulnerable() -> bool:
	# Player is invulnerable if rolling or already hit.
	return is_rolling or is_hit

# MODIFIED: Death sequence allows falling
func _die() -> void:
	if is_dead: return # Prevent multiple deaths
	is_dead = true
	print("Player Died!")

	# Clear all active gameplay states
	is_hit = false; is_rolling = false; is_attacking = false; is_holding_fall_frame = false; is_using_item = false
	# DO NOT zero out velocity here, let gravity handle Y

	play_animation("dead")
	play_sound(death_sfx_player, death_sounds)
	emit_signal("died") # Signal game systems

	# Disable attack hitbox permanently
	if is_instance_valid(attack_hitbox_shape):
		attack_hitbox_shape.set_deferred("disabled", true)

	# --- Modify Collision Layers/Masks ---
	# Stop being on the 'player' layer (assuming layer 2)
	set_collision_layer_value(2, false)
	# Optionally remove from all layers except a potential 'corpse' layer if needed
	# set_collision_layer(0)

	# Only collide with the 'world' layer (assuming layer 1)
	set_collision_mask(0) # Clear all masks first
	set_collision_mask_value(1, true) # Set mask for world

	# --- Keep physics process running ---
	# set_physics_process(true) # Ensure it's true if it was ever disabled


# --- Hitbox Interaction ---
func _on_attack_hitbox_area_entered(area: Area2D):
	# Added is_dead check
	if is_dead or not is_attacking or not is_instance_valid(attack_hitbox_shape) or attack_hitbox_shape.disabled:
		return

	if area.is_in_group("enemy_hurtbox"):
		var enemy_node = area.get_owner()
		if not is_instance_valid(enemy_node):
			printerr("WARNING (Player): Hit enemy hurtbox without valid owner:", area.name)
			return

		if enemy_node.has_method("take_damage") and not enemies_hit_this_swing.has(area):
			enemy_node.call("take_damage", attack_damage, global_position)
			enemies_hit_this_swing.append(area)


# --- Convenience getters (Optional, but can be useful) ---
func get_current_hp() -> int:
	return current_hp

func get_current_stamina() -> float:
	return current_stamina

func get_item_count() -> int: # Getter for item count
	return item_count
