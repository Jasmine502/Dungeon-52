# --- player.gd ---
extends CharacterBody2D

# Movement Parameters
@export var speed: float = 150.0
@export var jump_velocity: float = -600.0
@export var roll_speed: float = 400.0

# Attack Parameters
@export var attack_hit_frame: int = 4 # Frame index (0-based) where attack connects
@export var attack_sound_frame: int = 3 # Frame index (0-based) to play whoosh sound
@export var attack_damage: int = 10

# Parry Parameters
@export var parry_stamina_cost: int = 20
@export var parry_active_start_frame: int = 2 # Frame index (0-based) parry window starts
@export var parry_active_end_frame: int = 5   # Frame index (0-based) parry window ends

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

# --- Knockback ---
@export var knockback_strength: float = 200.0 # Control knockback force

# --- Audio Resources ---
@export_group("Audio Streams")
@export var attack_sounds: Array[AudioStream] = [] # Assign Sword Whoosh 1-4 here
@export var attack_grunts: Array[AudioStream] = [] # Assign Breathy Grunt 1-2, Breathy Hm
@export var jump_grunt_sounds: Array[AudioStream] = [] # Assign Jump Grunt
@export var damage_grunt_sounds: Array[AudioStream] = [] # Assign Ahh 1-2, Mmm Hurt, Fuck
@export var death_sounds: Array[AudioStream] = [] # Assign Death 1-2
@export var parry_try_sounds: Array[AudioStream] = [] # NEW: Assign ParryTry.wav here
@export var parry_success_sounds: Array[AudioStream] = [] # NEW: Assign ParrySucceed.wav here
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
var is_parrying: bool = false # NEW: Parry state
var is_hit: bool = false
var is_dead: bool = false # Master flag for being dead
var is_using_item: bool = false
var is_holding_fall_frame: bool = false
var parry_is_active_window: bool = false # NEW: Is the parry active?

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
@onready var parry_sfx_player: AudioStreamPlayer2D = $ParrySFXPlayer # NEW: Reference to the parry audio player


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
	if not is_instance_valid(parry_sfx_player): printerr("WARNING (Player): ParrySFXPlayer node not found!") # NEW: Validate parry node


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
	if not is_rolling and not is_attacking and not is_using_item and not is_parrying:
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
		velocity.y += gravity * delta
		velocity.x = 0
		move_and_slide()
		if is_on_floor():
			set_physics_process(false)
		return
	# --- End of Death Sequence Handling ---

	# --- Normal Physics Processing ---
	var current_velocity = velocity
	if not is_on_floor():
		current_velocity.y += gravity * delta

	var blocked = handle_blocking_states(delta)
	if not blocked:
		var input_direction = Input.get_axis("move_left", "move_right")
		current_velocity = handle_input_and_movement(input_direction, current_velocity)

	velocity = current_velocity
	move_and_slide()
	update_animation()


# --- State/Movement Helpers ---
func handle_blocking_states(delta: float) -> bool:
	var is_blocked = false
	var modified_velocity = velocity

	if is_hit:
		modified_velocity.x = move_toward(modified_velocity.x, 0, speed * 1.5 * delta)
		is_blocked = true
	elif is_rolling:
		is_blocked = true
	elif is_attacking:
		modified_velocity.x = move_toward(modified_velocity.x, 0, speed * 0.8 * delta)
		is_blocked = true
	elif is_parrying: # Stop movement during parry
		modified_velocity = Vector2.ZERO
		is_blocked = true
	elif is_using_item:
		var input_direction = Input.get_axis("move_left", "move_right")
		if input_direction != 0:
			modified_velocity.x = input_direction * speed * use_item_speed_multiplier
			if is_instance_valid(animated_sprite):
				animated_sprite.flip_h = (input_direction < 0)
		else:
			modified_velocity.x = move_toward(modified_velocity.x, 0, speed)
		is_blocked = true

	if is_blocked:
		velocity = modified_velocity
		return true
	else:
		return false

func handle_input_and_movement(direction: float, current_velocity: Vector2) -> Vector2:
	var modified_velocity = current_velocity
	var acted = false

	# --- Handle Actions ---
	if Input.is_action_just_pressed("parry") and can_parry():
		initiate_parry()
		acted = true
	elif Input.is_action_just_pressed("use_item") and can_use_item():
		initiate_use_item()
		acted = true
	elif Input.is_action_just_pressed("roll") and is_on_floor() and current_stamina >= roll_stamina_cost:
		modified_velocity = initiate_roll(direction, modified_velocity)
		acted = true
	elif Input.is_action_just_pressed("attack") and is_on_floor() and current_stamina >= attack_stamina_cost:
		initiate_attack()
		acted = true
	elif Input.is_action_just_pressed("jump") and is_on_floor() and current_stamina >= jump_stamina_cost:
		modified_velocity = initiate_jump(modified_velocity)
		acted = true

	# --- Handle Horizontal Movement ---
	if not acted:
		if direction != 0:
			modified_velocity.x = direction * speed
		else:
			modified_velocity.x = move_toward(modified_velocity.x, 0, speed)

	return modified_velocity

# --- Condition Checkers ---
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
	if is_hit or is_rolling or is_attacking or is_using_item or is_parrying: return

	var anim_to_play = "idle"

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
			if animated_sprite.animation != "fall": play_animation("fall")
			var last_frame_index = animated_sprite.sprite_frames.get_frame_count("fall") - 1
			if animated_sprite.frame == last_frame_index and not is_holding_fall_frame:
				animated_sprite.stop()
				is_holding_fall_frame = true
			return
		elif velocity.y < 0:
			anim_to_play = "jump"
			if is_holding_fall_frame: is_holding_fall_frame = false

	if animated_sprite.animation != anim_to_play: play_animation(anim_to_play)
	if abs(velocity.x) > 1.0: animated_sprite.flip_h = (velocity.x < 0)


# --- Action Initiation ---
func initiate_roll(input_direction: float, current_velocity: Vector2) -> Vector2:
	if is_dead: return current_velocity
	current_stamina -= roll_stamina_cost
	emit_signal("stamina_changed", current_stamina, max_stamina)
	stamina_regen_timer = stamina_regen_delay
	is_rolling = true; is_attacking = false; is_hit = false; is_using_item = false; is_parrying = false; parry_is_active_window = false; is_holding_fall_frame = false
	var roll_dir = input_direction if input_direction != 0 else (-1.0 if animated_sprite.flip_h else 1.0)
	animated_sprite.flip_h = (roll_dir < 0)
	var modified_velocity = current_velocity
	modified_velocity.x = roll_dir * roll_speed
	modified_velocity.y = 0
	play_animation("roll")
	return modified_velocity

func initiate_attack() -> void:
	if is_dead: return
	current_stamina -= attack_stamina_cost
	emit_signal("stamina_changed", current_stamina, max_stamina)
	stamina_regen_timer = stamina_regen_delay
	is_attacking = true; is_rolling = false; is_hit = false; is_using_item = false; is_parrying = false; parry_is_active_window = false; is_holding_fall_frame = false
	enemies_hit_this_swing.clear()
	play_animation("attack")
	play_sound(grunt_sfx_player, attack_grunts)

func initiate_jump(current_velocity: Vector2) -> Vector2:
	if is_dead: return current_velocity
	current_stamina -= jump_stamina_cost
	emit_signal("stamina_changed", current_stamina, max_stamina)
	stamina_regen_timer = stamina_regen_delay
	var modified_velocity = current_velocity
	modified_velocity.y = jump_velocity
	is_holding_fall_frame = false
	if is_instance_valid(animated_sprite) and not animated_sprite.is_playing():
		animated_sprite.play()
	play_animation("jump")
	play_sound(movement_sfx_player, jump_grunt_sounds)
	return modified_velocity

func initiate_use_item() -> void:
	if is_dead: return
	stamina_regen_timer = stamina_regen_delay
	is_using_item = true; is_rolling = false; is_attacking = false; is_hit = false; is_parrying = false; parry_is_active_window = false; is_holding_fall_frame = false
	play_animation("use")

func initiate_parry() -> void: # Plays ParryTry sound
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
	if is_dead and anim_name != "dead": return
	if animated_sprite.sprite_frames.has_animation(anim_name):
		if animated_sprite.animation != anim_name or ["fall", "attack", "roll", "use", "hit", "dead", "parry"].has(anim_name):
			animated_sprite.play(anim_name)
			if anim_name != "fall" and is_holding_fall_frame:
				is_holding_fall_frame = false
	else:
		printerr("ERROR (Player): Animation '", anim_name, "' not found!")

# --- Animation Signal Callbacks ---
func _on_animation_frame_changed():
	if not is_instance_valid(animated_sprite): return
	if is_dead: return

	var current_anim = animated_sprite.animation
	var current_frame = animated_sprite.frame

	# Attack hitbox/sound
	if is_attacking and current_anim == "attack":
		if current_frame == attack_sound_frame: play_sound(attack_sfx_player, attack_sounds)
		if is_instance_valid(attack_hitbox_shape):
			if current_frame == attack_hit_frame:
				if attack_hitbox_shape.disabled: attack_hitbox_shape.disabled = false
			elif current_frame > attack_hit_frame:
				if not attack_hitbox_shape.disabled: attack_hitbox_shape.disabled = true

	# Item effect/consumption
	elif is_using_item and current_anim == "use":
		if current_frame == use_item_effect_frame:
			if item_count > 0:
				item_count -= 1
				emit_signal("item_count_changed", item_count)
				var hp_before_heal = current_hp
				current_hp = min(current_hp + item_heal_amount, max_hp)
				if current_hp != hp_before_heal:
					emit_signal("hp_changed", current_hp, max_hp)

	# Parry active window
	elif is_parrying and current_anim == "parry":
		if current_frame >= parry_active_start_frame and current_frame <= parry_active_end_frame:
			if not parry_is_active_window: parry_is_active_window = true
		else:
			if parry_is_active_window: parry_is_active_window = false


func _on_animation_finished() -> void:
	if not is_instance_valid(animated_sprite): return
	var finished_anim = animated_sprite.animation

	# Ensure attack hitbox disabled
	if finished_anim == "attack":
		if is_instance_valid(attack_hitbox_shape) and not attack_hitbox_shape.disabled:
			attack_hitbox_shape.set_deferred("disabled", true)
		if not is_dead: _end_attack()

	# State transitions
	if not is_dead:
		match finished_anim:
			"roll": _end_roll()
			"hit": _end_hit()
			"use": _end_use_item()
			"parry": _end_parry() # End parry state
			"jump": pass
			"fall":
				if not is_on_floor() and not is_holding_fall_frame: play_animation("fall")
	elif finished_anim == "dead":
		# Stop animation on last frame
		if animated_sprite.sprite_frames.has_animation("dead"):
			var last_frame_index = animated_sprite.sprite_frames.get_frame_count("dead") - 1
			if last_frame_index >= 0: animated_sprite.frame = last_frame_index


# --- State Ending Functions ---
func _end_roll() -> void:
	if is_rolling: is_rolling = false

func _end_attack() -> void:
	if is_attacking: is_attacking = false
	if is_instance_valid(attack_hitbox_shape) and not attack_hitbox_shape.disabled:
		attack_hitbox_shape.set_deferred("disabled", true)

func _end_hit() -> void:
	if is_hit: is_hit = false

func _end_use_item() -> void:
	if is_using_item: is_using_item = false

func _end_parry() -> void:
	if is_parrying: is_parrying = false
	if parry_is_active_window: parry_is_active_window = false


# --- Damage & Death ---
# MODIFIED: Plays ParrySucceed sound on success
func take_damage(amount: int, damage_source_node: Node = null, damage_source_position: Vector2 = global_position) -> void:
	# 1. Check for successful parry FIRST
	if is_parrying and parry_is_active_window:
		if is_instance_valid(damage_source_node) and damage_source_node.has_method("trigger_parried_state"):
			damage_source_node.trigger_parried_state()
			print("Parry Successful against:", damage_source_node.name) # Debug
			play_sound(parry_sfx_player, parry_success_sounds) # Play success sound
			_end_parry() # Reset parry state immediately
		else:
			printerr("WARNING (Player): Parry successful but damage_source_node invalid or missing trigger_parried_state:", damage_source_node)
			_end_parry() # Still end parry state
		return # Do not take damage

	# 2. Check for other invulnerabilities
	if is_invulnerable(): return

	# 3. Proceed with taking damage
	current_hp = max(0, current_hp - amount)
	emit_signal("hp_changed", current_hp, max_hp)
	play_sound(damage_sfx_player, damage_grunt_sounds)

	# Reset active states
	is_attacking = false; is_rolling = false; is_holding_fall_frame = false; is_using_item = false;
	if is_parrying: _end_parry() # End parry if hit outside window

	stamina_regen_timer = stamina_regen_delay
	if is_instance_valid(attack_hitbox_shape):
		attack_hitbox_shape.set_deferred("disabled", true)

	if current_hp <= 0:
		_die()
	else:
		# Enter hit state
		is_hit = true
		play_animation("hit")

		# Apply knockback
		var knockback_direction = (global_position - damage_source_position).normalized()
		if knockback_direction == Vector2.ZERO:
			knockback_direction = Vector2(1.0 if randf() > 0.5 else -1.0, -0.5).normalized()
		velocity.x = knockback_direction.x * knockback_strength
		velocity.y = knockback_direction.y * knockback_strength * 0.6 - 120

# Helper function to check standard invulnerability conditions
func is_invulnerable() -> bool:
	return is_rolling or is_hit

# Helper function to check if parry is currently active
func is_parrying_successfully() -> bool:
	return is_parrying and parry_is_active_window

# Death sequence
func _die() -> void:
	if is_dead: return
	is_dead = true
	print("Player Died!")
	is_hit = false; is_rolling = false; is_attacking = false; is_holding_fall_frame = false; is_using_item = false; is_parrying = false; parry_is_active_window = false
	play_animation("dead")
	play_sound(death_sfx_player, death_sounds)
	emit_signal("died")
	if is_instance_valid(attack_hitbox_shape):
		attack_hitbox_shape.set_deferred("disabled", true)
	set_collision_layer_value(2, false)
	set_collision_mask(0)
	set_collision_mask_value(1, true)


# --- Hitbox Interaction ---
func _on_attack_hitbox_area_entered(area: Area2D):
	if is_dead or not is_attacking or not is_instance_valid(attack_hitbox_shape) or attack_hitbox_shape.disabled:
		return
	if area.is_in_group("enemy_hurtbox"):
		var enemy_node = area.get_owner()
		if not is_instance_valid(enemy_node): return
		if enemy_node.has_method("take_damage") and not enemies_hit_this_swing.has(area):
			enemy_node.call("take_damage", attack_damage, self, global_position)
			enemies_hit_this_swing.append(area)

# --- Convenience getters ---
func get_current_hp() -> int: return current_hp
func get_current_stamina() -> float: return current_stamina
func get_item_count() -> int: return item_count
