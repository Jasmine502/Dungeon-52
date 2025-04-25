# --- player.gd ---
extends CharacterBody2D

# Movement Parameters
@export var speed: float = 150.0
@export var jump_velocity: float = -300.0
@export var roll_speed: float = 350.0

# Attack Parameters
@export var attack_hit_frame: int = 4 # Frame index (0-based) where attack connects
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
@onready var collision_shape_main: CollisionShape2D = $CollisionShape2D # Assuming default name

# --- Initialization ---
func _ready() -> void:
	current_hp = max_hp
	current_stamina = float(max_stamina)
	add_to_group("player")

	# --- Connect Signals using Callable ---
	if is_instance_valid(animated_sprite):
		# Connect animation_finished
		if not animated_sprite.animation_finished.is_connected(Callable(self, "_on_animation_finished")):
			animated_sprite.animation_finished.connect(Callable(self, "_on_animation_finished"))
		# Connect frame_changed (Needed for hitbox timing)
		if not animated_sprite.frame_changed.is_connected(Callable(self, "_on_animation_frame_changed")):
			animated_sprite.frame_changed.connect(Callable(self, "_on_animation_frame_changed"))
	else:
		print("ERROR (Player): AnimatedSprite2D node not found!")

	if is_instance_valid(attack_hitbox):
		# Connect area_entered
		if not attack_hitbox.area_entered.is_connected(Callable(self, "_on_attack_hitbox_area_entered")):
			attack_hitbox.area_entered.connect(Callable(self, "_on_attack_hitbox_area_entered"))

		# Ensure hitbox shape exists and is disabled
		if is_instance_valid(attack_hitbox_shape):
			attack_hitbox_shape.disabled = true
		else:
			print("ERROR (Player): AttackHitbox Shape not found!")
	else:
		print("ERROR (Player): AttackHitbox Area2D not found!")

	# Emit initial signals AFTER values are set
	emit_signal("hp_changed", current_hp, max_hp)
	emit_signal("stamina_changed", current_stamina, max_stamina)
	# print("Player Ready: HP=", current_hp, " Stamina=", current_stamina) # Less verbose


# --- Non-Physics Updates ---
func _process(delta: float) -> void:
	if is_dead: return # Stop processing if dead

	# Stamina Regeneration
	if not is_rolling and not is_attacking: # Check blocking states
		if stamina_regen_timer > 0:
			stamina_regen_timer -= delta
		elif current_stamina < max_stamina:
			var previous_stamina = current_stamina
			current_stamina = min(current_stamina + stamina_regen_rate * delta, float(max_stamina))
			if current_stamina != previous_stamina: # Emit only if value changed
				emit_signal("stamina_changed", current_stamina, max_stamina)


# --- Physics Updates ---
func _physics_process(delta: float) -> void:
	if is_dead: # Ensure no movement if dead
		velocity = Vector2.ZERO
		move_and_slide() # Apply stop
		return

	# Apply Gravity (unless rolling on floor)
	if not is_on_floor() or (is_rolling and not is_on_floor()):
		velocity.y += gravity * delta

	# Handle states that block input/normal movement
	if handle_blocking_states(delta):
		move_and_slide() # Apply velocity changes from the blocking state
		return

	# Handle normal input and movement if not blocked
	var input_direction = Input.get_axis("move_left", "move_right")
	handle_input_and_movement(input_direction)

	# Update animations based on state/movement
	update_animation(input_direction)

	# Final movement calculation
	move_and_slide()


# --- State/Movement Helpers ---

# Returns true if a blocking state is active and handled movement
func handle_blocking_states(delta: float) -> bool:
	if is_hit:
		velocity.x = move_toward(velocity.x, 0, speed * 1.5 * delta) # Friction during hit
		return true
	if is_rolling:
		# Velocity set in initiate_roll, just need to potentially adjust gravity
		if not is_on_floor(): velocity.y += gravity * delta * 0.5
		return true
	if is_attacking:
		velocity.x = move_toward(velocity.x, 0, speed * 0.8 * delta) # Slow down during attack
		# Hitbox timing handled by _on_animation_frame_changed
		return true
	return false # No blocking state


func handle_input_and_movement(direction: float) -> void:
	# Check actions first
	if Input.is_action_just_pressed("roll") and is_on_floor() and current_stamina >= roll_stamina_cost:
		initiate_roll(direction); return # Prioritize roll
	if Input.is_action_just_pressed("attack") and is_on_floor() and current_stamina >= attack_stamina_cost:
		initiate_attack(); return # Prioritize attack
	if Input.is_action_just_pressed("jump") and is_on_floor():
		initiate_jump() # Jump doesn't block horizontal input this frame

	# Apply horizontal movement if no action initiated
	if direction != 0:
		velocity.x = direction * speed
	else:
		velocity.x = move_toward(velocity.x, 0, speed) # Friction


func update_animation(input_direction: float) -> void:
	if is_dead or is_hit or is_rolling or is_attacking: return # Handled by other states

	var anim_to_play = "idle"
	if is_on_floor():
		if is_holding_fall_frame: # Reset on landing
			is_holding_fall_frame = false
			if not animated_sprite.is_playing(): animated_sprite.play() # Unpause

		if abs(velocity.x) > 5.0: anim_to_play = "run"
		else: anim_to_play = "idle"
	else: # In air
		if is_holding_fall_frame: # Keep showing held fall frame
			if animated_sprite.animation != "fall" or animated_sprite.is_playing():
				play_animation("fall") # Ensure it's playing 'fall' (likely paused)
			return
		elif velocity.y < 0: anim_to_play = "jump"
		else: anim_to_play = "fall"

	play_animation(anim_to_play)

	# Flip sprite based on input direction (more responsive)
	if input_direction != 0:
		animated_sprite.flip_h = (input_direction < 0)


# --- Action Initiation ---

func initiate_roll(input_direction: float) -> void:
	if is_dead: return
	current_stamina -= roll_stamina_cost
	emit_signal("stamina_changed", current_stamina, max_stamina)
	stamina_regen_timer = stamina_regen_delay

	is_rolling = true; is_attacking = false; is_hit = false; is_holding_fall_frame = false
	var roll_dir = input_direction if input_direction != 0 else (-1.0 if animated_sprite.flip_h else 1.0)
	animated_sprite.flip_h = (roll_dir < 0)
	velocity.x = roll_dir * roll_speed
	velocity.y = 0 # Ensure grounded start
	play_animation("roll")
	# print("Player: Roll Started")


func initiate_attack() -> void:
	if is_dead: return
	current_stamina -= attack_stamina_cost
	emit_signal("stamina_changed", current_stamina, max_stamina)
	stamina_regen_timer = stamina_regen_delay

	is_attacking = true; is_rolling = false; is_hit = false; is_holding_fall_frame = false
	enemies_hit_this_swing.clear()
	velocity.x = 0 # Stop during attack
	play_animation("attack")
	# print("Player: Attack Started")


func initiate_jump() -> void:
	if is_dead: return
	velocity.y = jump_velocity
	is_holding_fall_frame = false
	play_animation("jump")


# --- Animation Handling ---

func play_animation(anim_name: String) -> void:
	if is_dead and anim_name != "dead": return # Only allow dead anim if dead

	if is_instance_valid(animated_sprite) and animated_sprite.sprite_frames.has_animation(anim_name):
		if animated_sprite.animation != anim_name or (anim_name == "fall" and is_holding_fall_frame):
			if anim_name == "fall" and is_holding_fall_frame: is_holding_fall_frame = false # Reset flag when restarting
			animated_sprite.play(anim_name)
	# else: print("Player anim warning: Cannot play", anim_name)


func _on_animation_frame_changed():
	if is_dead or not is_attacking or animated_sprite.animation != "attack": return

	# Handle attack hitbox timing precisely
	if animated_sprite.frame == attack_hit_frame:
		if is_instance_valid(attack_hitbox_shape):
			attack_hitbox_shape.disabled = false
			# print("Hitbox ENABLED frame", animated_sprite.frame)
	# Consider disabling slightly later for better feel? Or rely on _on_animation_finished.
	# Let's disable it definitively AFTER the hit frame.
	elif animated_sprite.frame > attack_hit_frame:
		if is_instance_valid(attack_hitbox_shape) and not attack_hitbox_shape.disabled:
			attack_hitbox_shape.disabled = true
			# print("Hitbox DISABLED frame", animated_sprite.frame)


func _on_animation_finished() -> void:
	if is_dead: return # Ignore if dead

	var finished_anim = animated_sprite.animation

	# Ensure hitbox is always disabled when these finish (Safety)
	if finished_anim in ["attack", "roll", "hit"]:
		if is_instance_valid(attack_hitbox_shape) and not attack_hitbox_shape.disabled:
			attack_hitbox_shape.disabled = true

	# Handle state transitions based on finished animation
	match finished_anim:
		"roll": _end_roll()
		"attack": _end_attack()
		"hit": _end_hit()
		"jump": pass # Let physics handle transition to fall
		"fall":
			if not is_on_floor(): # Still falling? Hold last frame.
				var last_frame_index = animated_sprite.sprite_frames.get_frame_count("fall") - 1
				if last_frame_index >= 0:
					animated_sprite.set_frame_and_progress(last_frame_index, 0)
					animated_sprite.stop()
					is_holding_fall_frame = true
			else: is_holding_fall_frame = false # Landed
		"dead":
			print("Player Death animation finished.") # For debug


# --- State Ending Functions ---

func _end_roll() -> void:
	if not is_rolling: return # Avoid ending state twice
	is_rolling = false
	# Optional: reset velocity.x = 0 here if desired
	# print("Player: Roll Ended")


func _end_attack() -> void:
	if not is_attacking: return
	is_attacking = false
	if is_instance_valid(attack_hitbox_shape): attack_hitbox_shape.disabled = true # Ensure off
	# print("Player: Attack Ended")


func _end_hit() -> void:
	if not is_hit: return
	is_hit = false
	# print("Player: Hit Stun Ended")


# --- Damage & Death ---

func take_damage(amount: int) -> void:
	# print("DEBUG: Player take_damage called with amount:", amount) # Keep for debug if needed
	if is_dead or is_hit or is_rolling: return # Invincible checks

	current_hp -= amount
	emit_signal("hp_changed", current_hp, max_hp)
	print("Player took damage:", amount, "| HP:", current_hp, "/", max_hp) # User feedback

	# Enter hit state
	is_hit = true; is_attacking = false; is_rolling = false; is_holding_fall_frame = false
	stamina_regen_timer = stamina_regen_delay # Reset stamina delay

	if current_hp <= 0:
		current_hp = 0
		_die() # Trigger death sequence
	else:
		# --- FIX: Play "hit" animation, not "error" ---
		play_animation("hit")
		# Apply knockback
		velocity.y = -120
		velocity.x = (-1.0 if animated_sprite.flip_h else 1.0) * -90 # Knock away from facing


func _die() -> void:
	if is_dead: return # Prevent multiple calls
	print("Player Died!")
	is_dead = true
	# Clear other states that might interfere
	is_hit = false; is_rolling = false; is_attacking = false
	velocity = Vector2.ZERO # Stop movement

	play_animation("dead") # Play the death animation
	emit_signal("died") # Signal game over or UI changes

	# Disable physics interaction (deferred to avoid issues in the same frame)
	if is_instance_valid(collision_shape_main):
		collision_shape_main.set_deferred("disabled", true)
	else: print("ERROR (Player): Main CollisionShape2D not found for disabling!")
	set_physics_process(false) # Stop running _physics_process


# --- Hitbox Interaction ---

func _on_attack_hitbox_area_entered(area: Area2D):
	if is_dead or attack_hitbox_shape.disabled: return # Don't hit if dead or hitbox off

	var parent = area.get_parent()
	# Check if parent exists, is an enemy, and can take damage
	if is_instance_valid(parent) and parent.is_in_group("enemies") and parent.has_method("take_damage"):
		var enemy_hurtbox = area # The specific hurtbox entered
		# Check if this specific hurtbox hasn't been hit this swing
		if not enemies_hit_this_swing.has(enemy_hurtbox):
			# print("Player attacking:", parent.name) # Debug
			parent.call("take_damage", attack_damage)
			enemies_hit_this_swing.append(enemy_hurtbox) # Record hit
