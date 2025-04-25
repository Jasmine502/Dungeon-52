# --- player.gd ---
extends CharacterBody2D

# Movement Parameters
@export var speed: float = 150.0
@export var jump_velocity: float = -300.0
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
@export var knockback_strength: float = 200.0 # NEW: Control knockback force

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
	add_to_group("player")

	if is_instance_valid(animated_sprite):
		if not animated_sprite.animation_finished.is_connected(Callable(self, "_on_animation_finished")):
			animated_sprite.animation_finished.connect(Callable(self, "_on_animation_finished"))
		if not animated_sprite.frame_changed.is_connected(Callable(self, "_on_animation_frame_changed")):
			animated_sprite.frame_changed.connect(Callable(self, "_on_animation_frame_changed"))
	else:
		printerr("ERROR (Player): AnimatedSprite2D node not found!")

	if is_instance_valid(attack_hitbox):
		if not attack_hitbox.area_entered.is_connected(Callable(self, "_on_attack_hitbox_area_entered")):
			attack_hitbox.area_entered.connect(Callable(self, "_on_attack_hitbox_area_entered"))
		if is_instance_valid(attack_hitbox_shape):
			attack_hitbox_shape.disabled = true
		else:
			printerr("ERROR (Player): AttackHitbox Shape not found!")
	else:
		printerr("ERROR (Player): AttackHitbox Area2D not found!")

	emit_signal("hp_changed", current_hp, max_hp)
	emit_signal("stamina_changed", current_stamina, max_stamina)

	if not is_instance_valid(attack_sfx_player): printerr("ERROR (Player): AttackSFXPlayer node not found!")
	if not is_instance_valid(grunt_sfx_player): printerr("ERROR (Player): GruntSFXPlayer node not found!")
	if not is_instance_valid(movement_sfx_player): printerr("ERROR (Player): MovementSFXPlayer node not found!")
	if not is_instance_valid(damage_sfx_player): printerr("ERROR (Player): DamageSFXPlayer node not found!")
	if not is_instance_valid(death_sfx_player): printerr("ERROR (Player): DeathSFXPlayer node not found!")

# --- Audio Helper ---
func play_sound(player_node: AudioStreamPlayer2D, sound_variations: Array, p_min_pitch: float = min_pitch, p_max_pitch: float = max_pitch) -> void:
	if not is_instance_valid(player_node):
		return
	if sound_variations.is_empty():
		return

	var sound_stream = sound_variations.pick_random()
	if not sound_stream is AudioStream:
		printerr("Warning (Player): Invalid item in sound variations array.")
		return

	player_node.stream = sound_stream
	player_node.pitch_scale = randf_range(p_min_pitch, p_max_pitch)
	player_node.play()

# --- Non-Physics Updates ---
func _process(delta: float) -> void:
	if is_dead: return

	# Regenerate stamina if not performing a blocking action and delay has passed
	if not is_rolling and not is_attacking: # Could add is_jumping check if needed, but regen delay handles it
		if stamina_regen_timer > 0:
			stamina_regen_timer -= delta
		elif current_stamina < max_stamina:
			var previous_stamina = current_stamina
			current_stamina = min(current_stamina + stamina_regen_rate * delta, float(max_stamina))
			if current_stamina != previous_stamina:
				emit_signal("stamina_changed", current_stamina, max_stamina)

# --- Physics Updates ---
func _physics_process(delta: float) -> void:
	if is_dead:
		# No need to set velocity to zero here if physics process is false (set in _die)
		return

	var current_velocity = velocity # Store velocity before modifications

	# Apply gravity if not on the floor
	if not is_on_floor():
		current_velocity.y += gravity * delta

	# Handle states that prevent normal movement (hit, roll, attack)
	if handle_blocking_states(delta):
		velocity = current_velocity # Update velocity with changes from blocking state handler
		move_and_slide()
		return

	# Get input and handle movement/actions
	var input_direction = Input.get_axis("move_left", "move_right")
	# Modify current_velocity based on input
	current_velocity = handle_input_and_movement(input_direction, current_velocity)

	# Apply final movement
	velocity = current_velocity # Update the character's velocity
	move_and_slide()

	# Update animation based on final state and velocity (after move_and_slide)
	update_animation(input_direction)


# --- State/Movement Helpers ---
# MODIFIED: This function now returns the modified velocity
func handle_blocking_states(delta: float) -> bool:
	var is_blocked = false
	var current_velocity = velocity # Work with current velocity

	if is_hit:
		# Allow some movement drift while hit, gradually slowing down
		current_velocity.x = move_toward(current_velocity.x, 0, speed * 1.5 * delta)
		# Don't modify current_velocity.y here, let gravity handle it
		is_blocked = true
	elif is_rolling:
		# Roll velocity is set in initiate_roll, maintain it (gravity applies)
		# Friction could be added here if needed:
		# current_velocity.x = move_toward(current_velocity.x, 0, roll_friction * delta)
		is_blocked = true
	elif is_attacking:
		# Slow down horizontally during attack
		current_velocity.x = move_toward(current_velocity.x, 0, speed * 0.8 * delta)
		is_blocked = true

	if is_blocked:
		velocity = current_velocity # Update main velocity if blocked
		return true
	else:
		return false # No blocking state active


# MODIFIED: This function now takes velocity as input and returns the modified velocity
func handle_input_and_movement(direction: float, current_velocity: Vector2) -> Vector2:
	var acted = false # Flag to check if an action was taken

	# --- Handle Actions (Check conditions before initiating) ---
	# Roll
	if Input.is_action_just_pressed("roll") and is_on_floor() and current_stamina >= roll_stamina_cost and not is_attacking and not is_hit:
		current_velocity = initiate_roll(direction, current_velocity) # Roll modifies velocity directly
		acted = true
	# Attack
	elif Input.is_action_just_pressed("attack") and is_on_floor() and current_stamina >= attack_stamina_cost and not is_rolling and not is_hit:
		initiate_attack() # Attack stops horizontal movement implicitly via handle_blocking_states
		acted = true
	# Jump
	elif Input.is_action_just_pressed("jump") and is_on_floor() and current_stamina >= jump_stamina_cost and not is_attacking and not is_rolling and not is_hit:
		current_velocity = initiate_jump(current_velocity) # Jump modifies velocity directly
		acted = true # Technically jump happens, but allow horizontal movement setting below

	# --- Handle Horizontal Movement (Only if NOT rolling or attacking) ---
	if not is_rolling and not is_attacking:
		if direction != 0:
			current_velocity.x = direction * speed
		else:
			# Apply friction/deceleration if no direction input
			current_velocity.x = move_toward(current_velocity.x, 0, speed) # Use speed as friction factor

	return current_velocity


func update_animation(input_direction: float) -> void:
	# Don't change animation if in a fixed-animation state
	if is_dead or is_hit or is_rolling or is_attacking: return

	var anim_to_play = "idle" # Default animation

	if is_on_floor():
		# Reset fall frame hold if landed
		if is_holding_fall_frame:
			is_holding_fall_frame = false
			if not animated_sprite.is_playing(): animated_sprite.play() # Resume if stopped

		# Determine animation based on horizontal velocity
		if abs(velocity.x) > 5.0: anim_to_play = "run"
		else: anim_to_play = "idle"

	else: # In the air
		# Check if we should hold the last frame of 'fall'
		if is_holding_fall_frame:
			# Ensure we are on the fall animation and stopped at the last frame
			if animated_sprite.animation != "fall" or animated_sprite.is_playing():
				play_animation("fall") # This call handles stopping at the last frame now
			return # Don't proceed further if holding fall frame

		# Determine animation based on vertical velocity
		elif velocity.y < 0: anim_to_play = "jump"
		else: anim_to_play = "fall"

	# Play the determined animation
	play_animation(anim_to_play)

	# Flip sprite based on input direction (or keep last direction if no input)
	if input_direction != 0:
		animated_sprite.flip_h = (input_direction < 0)


# --- Action Initiation ---
# MODIFIED: Roll now takes velocity and returns modified velocity
func initiate_roll(input_direction: float, current_velocity: Vector2) -> Vector2:
	if is_dead: return current_velocity
	current_stamina -= roll_stamina_cost
	emit_signal("stamina_changed", current_stamina, max_stamina)
	stamina_regen_timer = stamina_regen_delay # Reset regen delay

	is_rolling = true; is_attacking = false; is_hit = false; is_holding_fall_frame = false
	# Determine roll direction based on input or facing direction if neutral
	var roll_dir = input_direction if input_direction != 0 else (-1.0 if animated_sprite.flip_h else 1.0)
	animated_sprite.flip_h = (roll_dir < 0) # Flip sprite to match roll direction
	current_velocity.x = roll_dir * roll_speed # Set roll velocity
	current_velocity.y = 0 # Ensure no vertical movement during roll start
	play_animation("roll")
	# play_sound(movement_sfx_player, roll_sounds) # Uncomment if you have roll sounds
	return current_velocity

func initiate_attack() -> void:
	if is_dead: return
	current_stamina -= attack_stamina_cost
	emit_signal("stamina_changed", current_stamina, max_stamina)
	stamina_regen_timer = stamina_regen_delay # Reset regen delay

	is_attacking = true; is_rolling = false; is_hit = false; is_holding_fall_frame = false
	enemies_hit_this_swing.clear() # Clear list of enemies hit in previous swing
	play_animation("attack")
	# Play Attack GRUNT sound immediately
	play_sound(grunt_sfx_player, attack_grunts)
	# Sword Whoosh sound is played via _on_animation_frame_changed

# MODIFIED: Jump now takes velocity and returns modified velocity
func initiate_jump(current_velocity: Vector2) -> Vector2:
	if is_dead: return current_velocity

	current_stamina -= jump_stamina_cost
	emit_signal("stamina_changed", current_stamina, max_stamina)
	stamina_regen_timer = stamina_regen_delay # Reset regen delay

	current_velocity.y = jump_velocity # Apply jump impulse
	is_holding_fall_frame = false # Ensure not holding fall frame
	play_sound(movement_sfx_player, jump_grunt_sounds)
	return current_velocity


# --- Animation Handling ---
func play_animation(anim_name: String) -> void:
	# Do not change animation if dead, unless playing the 'dead' animation itself
	if is_dead and anim_name != "dead": return
	if not is_instance_valid(animated_sprite): return

	# Check if the animation exists
	if animated_sprite.sprite_frames.has_animation(anim_name):
		# Special handling for fall animation to hold last frame
		if anim_name == "fall":
			if animated_sprite.animation != "fall":
				animated_sprite.play("fall")
			# Check if we need to manually stop at the last frame
			var last_frame_index = animated_sprite.sprite_frames.get_frame_count("fall") - 1
			if animated_sprite.frame == last_frame_index and not is_holding_fall_frame:
				animated_sprite.stop()
				is_holding_fall_frame = true
			elif is_holding_fall_frame and animated_sprite.is_playing():
				# If playing again after being held, just let it play
				is_holding_fall_frame = false

		# Play other animations only if different
		elif animated_sprite.animation != anim_name:
			# If currently holding fall frame, release it
			if is_holding_fall_frame:
				is_holding_fall_frame = false
				# Ensure sprite is playing if it was stopped
				if not animated_sprite.is_playing(): animated_sprite.play()

			animated_sprite.play(anim_name)


func _on_animation_frame_changed():
	if is_dead: return

	# Handle attack hitbox and sound timing precisely based on current frame
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
			# Disable hitbox AFTER the hit frame (important for multi-hit prevention)
			elif current_frame > attack_hit_frame:
				if not attack_hitbox_shape.disabled:
					attack_hitbox_shape.disabled = true


func _on_animation_finished() -> void:
	if is_dead: return

	var finished_anim = animated_sprite.animation

	# Ensure attack hitbox is disabled when related animations finish
	if finished_anim == "attack": # Only need attack here, roll/hit don't use attack hitbox
		if is_instance_valid(attack_hitbox_shape) and not attack_hitbox_shape.disabled:
			attack_hitbox_shape.disabled = true

	# Handle state transitions based on which animation finished
	match finished_anim:
		"roll": _end_roll()
		"attack": _end_attack()
		"hit": _end_hit()
		"jump": pass # Jump animation finishing doesn't change physics state directly
		"fall":
			# If the fall animation finishes, ensure holding frame logic is consistent
			if is_on_floor():
				is_holding_fall_frame = false
			elif not is_holding_fall_frame: # Still in air, hold frame
				play_animation("fall") # This will trigger the hold logic in play_animation
		"dead":
			# Animation finished, character remains in dead state. No action needed here.
			pass


# --- State Ending Functions ---
func _end_roll() -> void:
	# Only end roll state if currently rolling
	if not is_rolling: return
	is_rolling = false

func _end_attack() -> void:
	# Only end attack state if currently attacking
	if not is_attacking: return
	is_attacking = false
	# Ensure hitbox is disabled as a final check
	if is_instance_valid(attack_hitbox_shape): attack_hitbox_shape.set_deferred("disabled", true)

func _end_hit() -> void:
	# Only end hit state if currently hit
	if not is_hit: return
	is_hit = false


# --- Damage & Death ---
# MODIFIED: take_damage now accepts a direction
func take_damage(amount: int, knockback_direction: Vector2 = Vector2.ZERO) -> void:
	# Check for invulnerability states
	if is_invulnerable(): return

	current_hp -= amount
	emit_signal("hp_changed", current_hp, max_hp)
	print("Player took damage:", amount, "| HP:", current_hp, "/", max_hp, "| Knockback From:", knockback_direction)

	play_sound(damage_sfx_player, damage_grunt_sounds)

	# Enter hit state, cancelling other actions
	is_hit = true; is_attacking = false; is_rolling = false; is_holding_fall_frame = false
	stamina_regen_timer = stamina_regen_delay # Reset regen delay on taking hit

	if current_hp <= 0:
		current_hp = 0
		_die() # Trigger death sequence
	else:
		# Apply hit effects
		play_animation("hit")
		# Apply knockback based on the direction and strength
		# Ensure direction is normalized
		var effective_knockback_dir = knockback_direction.normalized()
		if effective_knockback_dir == Vector2.ZERO: # Avoid zero vector if source was same position
			effective_knockback_dir = Vector2.RIGHT.rotated(randf_range(0, TAU))

		# Apply force. You might want separate horizontal/vertical strengths
		# Example: Stronger horizontal push, slight upward push
		velocity.x = effective_knockback_dir.x * knockback_strength
		velocity.y = effective_knockback_dir.y * knockback_strength * 0.5 - 100 # Apply Y knockback + small upward boost


# Helper function to check invulnerability conditions
func is_invulnerable() -> bool:
	# Player is invulnerable if rolling, already hit, or dead
	return is_rolling or is_hit or is_dead


func _die() -> void:
	# Prevent dying multiple times
	if is_dead: return
	print("Player Died!")
	is_dead = true
	# Clear any active states
	is_hit = false; is_rolling = false; is_attacking = false; is_holding_fall_frame = false
	velocity = Vector2.ZERO # Stop all movement

	play_animation("dead") # Play death animation
	play_sound(death_sfx_player, death_sounds) # Play death sound
	emit_signal("died") # Signal that the player died

	# Disable collisions and physics processing
	if is_instance_valid(collision_shape_main):
		# Use call_deferred to avoid physics errors during the frame collision occurs
		collision_shape_main.set_deferred("disabled", true)
	else: printerr("ERROR (Player): Main CollisionShape2D not found for disabling!")
	# Stop physics updates for the dead player
	set_physics_process(false)


# --- Hitbox Interaction ---
func _on_attack_hitbox_area_entered(area: Area2D):
	# Check basic conditions: is attacking, hitbox enabled, not dead
	if is_dead or not is_attacking or not is_instance_valid(attack_hitbox_shape) or attack_hitbox_shape.disabled: return

	# Check if the entered area is an enemy hurtbox
	if area.is_in_group("enemy_hurtbox"):
		# Try to get the owner (the enemy script node)
		var enemy_node = area.get_owner()
		# Fallback if owner isn't set correctly (less ideal)
		if not is_instance_valid(enemy_node): enemy_node = area.get_parent()

		# Ensure parent is valid, is an enemy, can take damage, and hasn't been hit this swing
		if is_instance_valid(enemy_node) and \
		   enemy_node.is_in_group("enemies") and \
		   enemy_node.has_method("take_damage") and \
		   not enemies_hit_this_swing.has(area): # Check against the hurtbox area itself

			print("Player attacking:", enemy_node.name)
			# Calculate knockback direction away from the player
			# Pass the PLAYER'S global position as the source for the enemy's knockback calculation
			enemy_node.call("take_damage", attack_damage, global_position)
			# Add the specific hurtbox area to the list of hits for this swing
			enemies_hit_this_swing.append(area)


# --- Convenience getters ---
func get_current_hp() -> int:
	return current_hp

func get_current_stamina() -> float:
	return current_stamina
