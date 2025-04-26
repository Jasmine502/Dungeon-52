# --- player.gd ---
extends CharacterBody2D

# --- Movement Parameters (Souls-like Tuning) ---
@export var speed: float = 180.0 # Slightly faster base speed for responsiveness
@export var jump_velocity: float = -450.0 # Reduced jump height, less floaty
@export var roll_speed: float = 350.0 # Roll speed - adjust with animation duration for distance
@export var air_acceleration: float = 600.0 # How quickly player can change direction mid-air

# --- Attack Parameters ---
@export var attack_hit_frame: int = 4 # Frame index (0-based) where attack connects
@export var attack_sound_frame: int = 3 # Frame index (0-based) to play whoosh sound
@export var attack_damage: int = 15 # Base attack damage

# --- Parry Parameters ---
@export var parry_stamina_cost: int = 25 # Increased parry cost
@export var parry_active_start_frame: int = 2 # Frame index (0-based) parry window starts (TIGHTENED)
@export var parry_active_end_frame: int = 4   # Frame index (0-based) parry window ends (TIGHTENED) - Needs animation sync!

# --- Item Usage Parameters ---
@export var initial_item_count: int = 3 # Start with 3 heals (like Estus)
@export var item_heal_amount: int = 40 # Heal amount per item
@export var use_item_effect_frame: int = 12 # Frame index (0-based) for heal effect
@export var use_item_speed_multiplier: float = 0.3 # SIGNIFICANT speed reduction while using item

# --- Stats (Souls-like Tuning) ---
@export var max_hp: int = 100
var current_hp: int

@export var max_stamina: int = 100
var current_stamina: float # Float for smooth regen
@export var stamina_regen_rate: float = 20.0 # Slightly slower base regen
@export var stamina_regen_delay: float = 1.2 # INCREASED delay before regen starts
@export var roll_stamina_cost: int = 30 # INCREASED roll cost
@export var attack_stamina_cost: int = 20 # INCREASED attack cost
@export var jump_stamina_cost: int = 15 # INCREASED jump cost

# --- Knockback ---
@export var knockback_strength: float = 250.0 # Increased knockback force

# --- Audio Resources ---
@export_group("Audio Streams")
@export var attack_sounds: Array[AudioStream] = [] # Assign Sword Whoosh 1-4 here
@export var attack_grunts: Array[AudioStream] = [] # Assign Breathy Grunt 1-2, Breathy Hm
@export var jump_grunt_sounds: Array[AudioStream] = [] # Assign Jump Grunt
@export var damage_grunt_sounds: Array[AudioStream] = [] # Assign Ahh 1-2, Mmm Hurt, Fuck
@export var death_sounds: Array[AudioStream] = [] # Assign Death 1-2
@export var parry_try_sounds: Array[AudioStream] = [] # Assign ParryTry.wav here
@export var parry_success_sounds: Array[AudioStream] = [] # Assign ParrySucceed.wav here
@export var roll_sounds: Array[AudioStream] = [] # NEW: Assign Roll SFX (e.g., clothing rustle)
@export var use_item_sounds: Array[AudioStream] = [] # NEW: Assign item use SFX (e.g., drink/heal sound)

@export_group("Audio Settings")
@export var min_pitch: float = 0.9
@export var max_pitch: float = 1.1

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
var is_parrying: bool = false
var is_hit: bool = false
var is_dead: bool = false # Master flag for being dead
var is_using_item: bool = false
var is_holding_fall_frame: bool = false
var parry_is_active_window: bool = false

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
@onready var movement_sfx_player: AudioStreamPlayer2D = $MovementSFXPlayer # For jump/roll/item use
@onready var damage_sfx_player: AudioStreamPlayer2D = $DamageSFXPlayer
@onready var death_sfx_player: AudioStreamPlayer2D = $DeathSFXPlayer
@onready var parry_sfx_player: AudioStreamPlayer2D = $ParrySFXPlayer
@onready var item_sfx_player: AudioStreamPlayer2D = $ItemSFXPlayer # NEW: Reference for item sounds


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

	# Audio node validation
	if not is_instance_valid(attack_sfx_player): printerr("WARNING (Player): AttackSFXPlayer node not found!")
	if not is_instance_valid(grunt_sfx_player): printerr("WARNING (Player): GruntSFXPlayer node not found!")
	if not is_instance_valid(movement_sfx_player): printerr("WARNING (Player): MovementSFXPlayer node not found!")
	if not is_instance_valid(damage_sfx_player): printerr("WARNING (Player): DamageSFXPlayer node not found!")
	if not is_instance_valid(death_sfx_player): printerr("WARNING (Player): DeathSFXPlayer node not found!")
	if not is_instance_valid(parry_sfx_player): printerr("WARNING (Player): ParrySFXPlayer node not found!")
	if not is_instance_valid(item_sfx_player): printerr("WARNING (Player): ItemSFXPlayer node not found!")


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

	# Regenerate stamina if conditions met
	# Condition: Not performing stamina-consuming or blocking actions AND delay timer is up
	if not is_rolling and not is_attacking and not is_parrying and not is_using_item and current_stamina < max_stamina:
		if stamina_regen_timer > 0:
			stamina_regen_timer -= delta
		else:
			var previous_stamina = current_stamina
			current_stamina = min(current_stamina + stamina_regen_rate * delta, float(max_stamina))
			if current_stamina != previous_stamina: # Only emit if value changed
				emit_signal("stamina_changed", current_stamina, max_stamina)


# --- Physics Updates ---
func _physics_process(delta: float) -> void:
	# --- Special Handling for Death Sequence ---
	if is_dead:
		velocity.y += gravity * delta
		velocity.x = move_toward(velocity.x, 0, speed * 0.5 * delta) # Allow some slide on death
		move_and_slide()
		# Removed the floor check physics process disable here, let the animation handle the final state
		return
	# --- End of Death Sequence Handling ---

	# --- Normal Physics Processing ---
	var current_velocity = velocity
	# Apply gravity
	if not is_on_floor():
		current_velocity.y += gravity * delta

	# Handle states that block or modify standard movement/input
	var blocked = handle_blocking_states(delta)
	if not blocked:
		var input_direction = Input.get_axis("move_left", "move_right")
		current_velocity = handle_input_and_movement(input_direction, current_velocity, delta)

	velocity = current_velocity
	move_and_slide()
	update_animation() # Update animation based on final velocity and state


# --- State/Movement Helpers ---
# Returns true if standard input/movement should be blocked
func handle_blocking_states(delta: float) -> bool:
	var is_blocked = false
	var modified_velocity = velocity

	if is_hit: # Hit state takes priority
		# Allow gravity but dampen horizontal movement quickly
		modified_velocity.x = move_toward(modified_velocity.x, 0, speed * 2.0 * delta) # Faster stop during hit
		is_blocked = true
	elif is_rolling:
		# Roll velocity is set in initiate_roll, gravity still applies if needed (e.g. rolling off edge)
		# No horizontal input change during roll
		is_blocked = true
	elif is_attacking:
		# Greatly reduce movement speed during attack for commitment
		modified_velocity.x = move_toward(modified_velocity.x, 0, speed * 0.2 * delta) # VERY slow during attack
		is_blocked = true
	elif is_parrying:
		# Completely stop movement during parry
		modified_velocity = Vector2.ZERO # Absolute stop for parry stance
		is_blocked = true
	elif is_using_item:
		# Allow slow movement while using item based on multiplier
		var input_direction = Input.get_axis("move_left", "move_right")
		var target_speed = input_direction * speed * use_item_speed_multiplier
		modified_velocity.x = move_toward(modified_velocity.x, target_speed, speed * delta) # Move towards target speed
		if abs(input_direction) > 0.1: # Flip sprite if moving significantly
				animated_sprite.flip_h = (input_direction < 0)
		is_blocked = true

	if is_blocked:
		velocity = modified_velocity # Update velocity directly for blocking states
		return true
	else:
		return false # Standard movement can proceed

# Handle standard movement and action inputs
func handle_input_and_movement(direction: float, current_velocity: Vector2, delta: float) -> Vector2:
	var modified_velocity = current_velocity
	var acted = false # Track if an action was taken this frame

	# --- Handle Actions (Prioritize actions over movement) ---
	# Check actions only if not currently in a blocking state handled above
	if Input.is_action_just_pressed("parry") and can_parry():
		initiate_parry()
		acted = true
	elif Input.is_action_just_pressed("use_item") and can_use_item():
		initiate_use_item()
		acted = true
	# Roll only if on floor OR maybe add air-dash condition later?
	elif Input.is_action_just_pressed("roll") and is_on_floor() and can_roll():
		modified_velocity = initiate_roll(direction, modified_velocity)
		acted = true
	# Attack only if on floor OR maybe add air-attack condition later?
	elif Input.is_action_just_pressed("attack") and is_on_floor() and can_attack():
		initiate_attack()
		acted = true
	# Jump only if on floor
	elif Input.is_action_just_pressed("jump") and is_on_floor() and can_jump():
		modified_velocity = initiate_jump(modified_velocity)
		acted = true

	# --- Handle Horizontal Movement ---
	# Apply movement only if no overriding action was taken this frame
	if not acted:
		if is_on_floor():
			# Grounded movement: Instant or near-instant acceleration
			if direction != 0:
				modified_velocity.x = direction * speed
			else:
				modified_velocity.x = move_toward(modified_velocity.x, 0, speed) # Smooth stop
		else:
			# Air control: Use move_toward for less snappy control
			modified_velocity.x = move_toward(modified_velocity.x, direction * speed, air_acceleration * delta)

	# --- Update Sprite Facing Direction ---
	# Only flip if moving horizontally significantly and not performing an action that locks direction (like attack/roll)
	if abs(direction) > 0.1 and not is_attacking and not is_rolling and not is_using_item and not is_parrying:
		animated_sprite.flip_h = (direction < 0)

	return modified_velocity


# --- Condition Checkers (Can perform action?) ---
func can_roll() -> bool:
	return current_stamina >= roll_stamina_cost and \
		   not is_rolling and not is_attacking and not is_hit and \
		   not is_dead and not is_using_item and not is_parrying

func can_attack() -> bool:
	return current_stamina >= attack_stamina_cost and \
		   not is_rolling and not is_attacking and not is_hit and \
		   not is_dead and not is_using_item and not is_parrying

func can_jump() -> bool:
	return current_stamina >= jump_stamina_cost and \
		   not is_rolling and not is_attacking and not is_hit and \
		   not is_dead and not is_using_item and not is_parrying

func can_use_item() -> bool:
	return is_on_floor() and \
		   item_count > 0 and \
		   current_hp < max_hp and \
		   not is_rolling and \
		   not is_attacking and \
		   not is_hit and \
		   not is_dead and \
		   not is_using_item and \
		   not is_parrying

func can_parry() -> bool:
	return is_on_floor() and \
		   current_stamina >= parry_stamina_cost and \
		   not is_rolling and \
		   not is_attacking and \
		   not is_hit and \
		   not is_dead and \
		   not is_using_item and \
		   not is_parrying


# --- Animation Control ---
func update_animation() -> void:
	if not is_instance_valid(animated_sprite): return
	# Don't change animation if in a dedicated action state (handled by initiation/finish)
	if is_hit or is_rolling or is_attacking or is_using_item or is_parrying or is_dead: return

	var anim_to_play = "idle"

	if is_on_floor():
		if is_holding_fall_frame: # Reset fall state if landed
			is_holding_fall_frame = false
			# Don't immediately force idle if sprite is finishing another anim
			if not animated_sprite.is_playing() or animated_sprite.animation == "fall":
				play_animation("idle") # Play idle explicitly on land if needed

		# Determine grounded animation
		if abs(velocity.x) > 5.0: anim_to_play = "run"
		else: anim_to_play = "idle"
	else: # In the air
		if velocity.y > 5.0: # Moving down significantly
			# Play fall animation, hold last frame
			if animated_sprite.animation != "fall":
				play_animation("fall")
				is_holding_fall_frame = false # Ensure we don't start holding immediately

			# Logic to hold the last frame of 'fall'
			if animated_sprite.sprite_frames.has_animation("fall"):
				var last_frame_index = animated_sprite.sprite_frames.get_frame_count("fall") - 1
				if last_frame_index >= 0 and animated_sprite.frame == last_frame_index and not is_holding_fall_frame:
					animated_sprite.stop() # Stop playback
					animated_sprite.frame = last_frame_index # Ensure it stays on last frame
					is_holding_fall_frame = true
			return # Don't try to play other anims if falling/holding frame
		elif velocity.y < -5.0: # Moving up significantly
			anim_to_play = "jump"
			if is_holding_fall_frame: is_holding_fall_frame = false # Release hold if jumping

	# Play the determined animation if it's different from the current one
	# Allow overriding idle/run easily, but be careful about interrupting others
	if animated_sprite.animation != anim_to_play and (animated_sprite.animation == "idle" or animated_sprite.animation == "run" or not animated_sprite.is_playing()):
		play_animation(anim_to_play)


# --- Action Initiation ---
func initiate_roll(input_direction: float, current_velocity: Vector2) -> Vector2:
	if is_dead: return current_velocity

	current_stamina -= roll_stamina_cost
	emit_signal("stamina_changed", current_stamina, max_stamina)
	stamina_regen_timer = stamina_regen_delay # Reset regen delay timer

	# Set state flags
	is_rolling = true; is_attacking = false; is_hit = false; is_using_item = false; is_parrying = false; parry_is_active_window = false; is_holding_fall_frame = false

	# Determine roll direction (use input or facing direction if no input)
	var roll_dir = input_direction if abs(input_direction) > 0.1 else (-1.0 if animated_sprite.flip_h else 1.0)
	animated_sprite.flip_h = (roll_dir < 0) # Face the roll direction

	# Set velocity for the roll
	var modified_velocity = current_velocity
	modified_velocity.x = roll_dir * roll_speed
	modified_velocity.y = 0 # Keep roll horizontal unless map design requires otherwise

	play_animation("roll")
	play_sound(movement_sfx_player, roll_sounds) # Play roll sound
	return modified_velocity

func initiate_attack() -> void:
	if is_dead: return

	current_stamina -= attack_stamina_cost
	emit_signal("stamina_changed", current_stamina, max_stamina)
	stamina_regen_timer = stamina_regen_delay

	is_attacking = true; is_rolling = false; is_hit = false; is_using_item = false; is_parrying = false; parry_is_active_window = false; is_holding_fall_frame = false
	enemies_hit_this_swing.clear() # Clear hit list for new swing

	play_animation("attack")
	play_sound(grunt_sfx_player, attack_grunts) # Play grunt on attack start

func initiate_jump(current_velocity: Vector2) -> Vector2:
	if is_dead: return current_velocity

	current_stamina -= jump_stamina_cost
	emit_signal("stamina_changed", current_stamina, max_stamina)
	stamina_regen_timer = stamina_regen_delay

	var modified_velocity = current_velocity
	modified_velocity.y = jump_velocity # Apply jump force

	# Reset flags potentially affected by jump
	is_holding_fall_frame = false
	if is_instance_valid(animated_sprite) and not animated_sprite.is_playing():
		animated_sprite.play() # Ensure sprite animates if somehow stopped

	play_animation("jump")
	play_sound(movement_sfx_player, jump_grunt_sounds)
	return modified_velocity

func initiate_use_item() -> void:
	if is_dead: return

	stamina_regen_timer = stamina_regen_delay # Using item should pause stamina regen
	is_using_item = true; is_rolling = false; is_attacking = false; is_hit = false; is_parrying = false; parry_is_active_window = false; is_holding_fall_frame = false

	play_animation("use")
	# Play sound maybe at start of animation? Or tied to frame? Assume start for now.
	play_sound(item_sfx_player, use_item_sounds)

func initiate_parry() -> void:
	if is_dead: return

	current_stamina -= parry_stamina_cost
	emit_signal("stamina_changed", current_stamina, max_stamina)
	stamina_regen_timer = stamina_regen_delay

	is_parrying = true; parry_is_active_window = false; is_rolling = false; is_attacking = false; is_hit = false; is_using_item = false; is_holding_fall_frame = false

	play_animation("parry")
	play_sound(parry_sfx_player, parry_try_sounds) # Play parry attempt sound


# --- Animation Playback Helper ---
func play_animation(anim_name: String) -> void:
	if not is_instance_valid(animated_sprite): return
	# Prevent changing animation during death unless it's the death animation itself
	if is_dead and anim_name != "dead": return

	if animated_sprite.sprite_frames.has_animation(anim_name):
		# Play if different anim OR if it's an action anim that needs restarting
		# Or if sprite isn't playing currently
		if animated_sprite.animation != anim_name or not animated_sprite.is_playing() or ["attack", "roll", "use", "hit", "dead", "parry", "jump"].has(anim_name):
			animated_sprite.play(anim_name)
			# Reset fall hold if starting a new animation that isn't fall
			if anim_name != "fall" and is_holding_fall_frame:
				is_holding_fall_frame = false
	else:
		printerr("ERROR (Player): Animation '", anim_name, "' not found!")


# --- Animation Signal Callbacks ---
func _on_animation_frame_changed():
	if not is_instance_valid(animated_sprite): return
	if is_dead: return # Don't process frames if dead

	var current_anim = animated_sprite.animation
	var current_frame = animated_sprite.frame

	# --- Attack Hitbox/Sound Logic ---
	if is_attacking and current_anim == "attack":
		# Play swing sound on specific frame
		if current_frame == attack_sound_frame:
			play_sound(attack_sfx_player, attack_sounds)
		# Enable/disable hitbox based on frame
		if is_instance_valid(attack_hitbox_shape):
			# Enable hitbox slightly before visual contact might suggest, lasting a few frames
			var attack_hit_start_frame = attack_hit_frame
			var attack_hit_end_frame = attack_hit_frame + 1 # Example: hitbox active for 2 frames
			if current_frame >= attack_hit_start_frame and current_frame <= attack_hit_end_frame:
				if attack_hitbox_shape.disabled:
					attack_hitbox_shape.disabled = false
					enemies_hit_this_swing.clear() # Clear hit list when hitbox activates
			else:
				if not attack_hitbox_shape.disabled:
					attack_hitbox_shape.disabled = true

	# --- Item Effect/Consumption Logic ---
	elif is_using_item and current_anim == "use":
		# Apply healing effect on specific frame
		if current_frame == use_item_effect_frame:
			if item_count > 0:
				item_count -= 1
				emit_signal("item_count_changed", item_count)
				var hp_before_heal = current_hp
				current_hp = min(current_hp + item_heal_amount, max_hp)
				if current_hp != hp_before_heal: # Only emit if HP actually changed
					emit_signal("hp_changed", current_hp, max_hp)
				# Maybe play a success sound here too?
				# play_sound(item_sfx_player, item_success_sounds) # If you have one

	# --- Parry Active Window Logic ---
	elif is_parrying and current_anim == "parry":
		# Set active window based on frame range
		if current_frame >= parry_active_start_frame and current_frame <= parry_active_end_frame:
			if not parry_is_active_window: parry_is_active_window = true
		else:
			if parry_is_active_window: parry_is_active_window = false


func _on_animation_finished() -> void:
	if not is_instance_valid(animated_sprite): return
	var finished_anim = animated_sprite.animation

	# Ensure attack hitbox is always disabled after attack animation finishes
	if finished_anim == "attack":
		if is_instance_valid(attack_hitbox_shape) and not attack_hitbox_shape.disabled:
			attack_hitbox_shape.set_deferred("disabled", true)
		# Transition out of attacking state ONLY if not dead
		if not is_dead: _end_attack()

	# State transitions based on finished animation (if not dead)
	if not is_dead:
		match finished_anim:
			"roll": _end_roll()
			"hit": _end_hit()
			"use": _end_use_item()
			"parry": _end_parry()
			"jump":
				# If jump animation finishes mid-air, transition to fall maybe?
				if not is_on_floor(): play_animation("fall")
			"fall":
				# If fall animation finishes (e.g., single frame anim), ensure it can replay or hold
				if not is_on_floor() and not is_holding_fall_frame: play_animation("fall")
	# Handle death animation finish
	elif finished_anim == "dead":
		# Optional: Freeze on last frame after death anim plays fully
		if animated_sprite.sprite_frames.has_animation("dead"):
			var last_frame_index = animated_sprite.sprite_frames.get_frame_count("dead") - 1
			if last_frame_index >= 0:
				animated_sprite.stop() # Stop playback
				animated_sprite.frame = last_frame_index # Set to last frame


# --- State Ending Functions ---
func _end_roll() -> void:
	if is_rolling:
		is_rolling = false
		# Optional: Add a small delay here before allowing next action if needed
		# velocity.x = 0 # Or slow down gradually

func _end_attack() -> void:
	if is_attacking:
		is_attacking = false
	# Ensure hitbox is off (redundant if frame logic is solid, but safe)
	if is_instance_valid(attack_hitbox_shape) and not attack_hitbox_shape.disabled:
		attack_hitbox_shape.set_deferred("disabled", true)

func _end_hit() -> void:
	if is_hit:
		is_hit = false

func _end_use_item() -> void:
	if is_using_item:
		is_using_item = false

func _end_parry() -> void:
	if is_parrying:
		is_parrying = false
	if parry_is_active_window: # Ensure active flag is also reset
		parry_is_active_window = false


# --- Damage & Death ---
func take_damage(amount: int, damage_source_node: Node = null, damage_source_position: Vector2 = global_position) -> void:
	# --- 1. Check for Successful Parry ---
	if is_parrying_successfully():
		print("Parry Attempt vs incoming damage!") # Debug
		if is_instance_valid(damage_source_node) and damage_source_node.has_method("trigger_parried_state"):
			damage_source_node.trigger_parried_state() # Tell the enemy it got parried
			print("Parry Successful against:", damage_source_node.name) # Debug
			play_sound(parry_sfx_player, parry_success_sounds) # Play parry success sound
			# Optional: Gain brief invulnerability or restore some stamina on successful parry?
			# current_stamina = min(max_stamina, current_stamina + 10)
			_end_parry() # Reset parry state immediately after success
		else:
			# Still counts as a successful parry even if enemy can't react, play sound
			play_sound(parry_sfx_player, parry_success_sounds)
			printerr("WARNING (Player): Parry successful but damage_source_node invalid or missing trigger_parried_state:", damage_source_node)
			_end_parry() # Still end parry state
		return # Crucial: Do not proceed to take damage if parried

	# --- 2. Check for Other Invulnerabilities (e.g., Roll) ---
	if is_invulnerable():
		# print("Damage ignored due to invulnerability (Rolling/Hit)") # Debug
		return # Do not take damage

	# --- 3. Process Damage Taken ---
	current_hp = max(0, current_hp - amount)
	emit_signal("hp_changed", current_hp, max_hp)
	play_sound(damage_sfx_player, damage_grunt_sounds)

	# Interrupt current actions (except death)
	is_attacking = false; is_rolling = false; is_holding_fall_frame = false; is_using_item = false;
	if is_parrying: _end_parry() # End parry if hit outside active window

	# Reset stamina regen delay
	stamina_regen_timer = stamina_regen_delay

	# Ensure attack hitbox is off if hit mid-attack
	if is_instance_valid(attack_hitbox_shape) and not attack_hitbox_shape.disabled:
		attack_hitbox_shape.set_deferred("disabled", true)

	# --- 4. Handle Death or Hit State ---
	if current_hp <= 0:
		_die()
	else:
		# Enter hit state
		is_hit = true
		play_animation("hit") # Play the hit reaction animation

		# Apply knockback
		var knockback_direction = (global_position - damage_source_position).normalized()
		# If source is exactly on player, knock back horizontally based on facing dir
		if knockback_direction == Vector2.ZERO:
			knockback_direction = Vector2(1.0 if animated_sprite.flip_h else -1.0, -0.3).normalized() # Knock back opposite facing direction
		# Apply force - stronger horizontal, moderate vertical pop
		velocity.x = knockback_direction.x * knockback_strength
		velocity.y = knockback_direction.y * knockback_strength * 0.5 - 100 # Add a small upward pop


# Helper function to check standard invulnerability conditions (Roll iFrames)
func is_invulnerable() -> bool:
	# Rolling provides invulnerability. Add more conditions here if needed (e.g. brief spawn invincibility)
	return is_rolling

# Helper function to check if parry is currently active (used in take_damage)
func is_parrying_successfully() -> bool:
	return is_parrying and parry_is_active_window


func _die() -> void:
	if is_dead: return # Prevent triggering death multiple times
	is_dead = true
	print("Player Died!")

	# Clear all active states immediately
	is_hit = false; is_rolling = false; is_attacking = false; is_holding_fall_frame = false; is_using_item = false; is_parrying = false; parry_is_active_window = false

	play_animation("dead") # Play death animation
	play_sound(death_sfx_player, death_sounds) # Play death sound
	emit_signal("died") # Signal that death occurred

	# Disable attack hitbox permanently on death
	if is_instance_valid(attack_hitbox_shape):
		attack_hitbox_shape.set_deferred("disabled", true)

	# Change collision layers/masks for death
	set_collision_layer_value(2, false) # No longer on player layer
	set_collision_mask(0) # Don't collide with anything
	set_collision_mask_value(1, true) # EXCEPT collide with world for falling/resting


# --- Hitbox Interaction ---
func _on_attack_hitbox_area_entered(area: Area2D):
	# Check if alive, attacking, and hitbox is actually enabled
	if is_dead or not is_attacking or not is_instance_valid(attack_hitbox_shape) or attack_hitbox_shape.disabled:
		return

	# Check if the area belongs to an enemy hurtbox group
	if area.is_in_group("enemy_hurtbox"):
		var enemy_node = area.get_owner() # Get the main enemy node
		if not is_instance_valid(enemy_node): return # Check if enemy node is valid

		# Check if enemy can take damage and hasn't been hit by *this specific swing* yet
		if enemy_node.has_method("take_damage") and not enemies_hit_this_swing.has(area):
			# Call the enemy's take_damage method
			enemy_node.call("take_damage", attack_damage, self, global_position)
			# Add the specific hurtbox area to the list of things hit this swing
			enemies_hit_this_swing.append(area)
			# Optional: Add brief hitstop effect here?
			# Engine.time_scale = 0.5; await get_tree().create_timer(0.05).timeout; Engine.time_scale = 1.0


# --- Convenience getters ---
func get_current_hp() -> int: return current_hp
func get_current_stamina() -> float: return current_stamina
func get_item_count() -> int: return item_count
