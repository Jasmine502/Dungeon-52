# --- calculator.gd ---
extends CharacterBody2D

# Stats
@export var max_hp: int = 200
@export var speed: float = 60.0
@export var detection_radius: float = 300.0
@export var pencil_jab_damage: int = 15
@export var protractor_slice_damage: int = 25
@export var low_health_threshold: float = 0.3

# Variable Declaration
var current_hp: int # Declared here

# Signals for UI
signal hp_changed(current_value, max_value)
signal died

# AI / Movement Parameters
@export var pencil_jab_range: float = 85.0
@export var protractor_slice_range: float = 110.0
@export var buff_chance: float = 0.2
@export var follow_y_speed_multiplier: float = 0.6
@export var hover_deadzone: float = 10.0

# State Machine
enum State { IDLE, MOVE, PENCIL_JAB, PROTRACTOR_SLICE, MULTIPLY_BUFF, ERROR, DEAD }
var current_state: State = State.IDLE

# AI Control
var player_node: CharacterBody2D = null
var can_act: bool = true
var ai_timer: float = 0.0
var ai_cooldown: float = 1.5

# Flags
var attack_hit_registered: bool = false

# Node References
# Ensure these nodes exist as direct children with these exact names in calculator.tscn!
@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var hurtbox: Area2D = $Hurtbox
@onready var pencil_hitbox: Area2D = $PencilHitbox
@onready var protractor_hitbox: Area2D = $ProtractorHitbox
@onready var pencil_hitbox_shape: CollisionShape2D = $PencilHitbox/CollisionShape2D
@onready var protractor_hitbox_shape: CollisionShape2D = $ProtractorHitbox/CollisionShape2D

# --- Initialization ---
func _ready() -> void:
	current_hp = max_hp # Initialize HP
	add_to_group("enemies")

	# Attempt to register with UI (deferred is safer)
	call_deferred("register_with_ui")

	# Emit initial HP signal AFTER current_hp is set
	emit_signal("hp_changed", current_hp, max_hp)

	# --- Connect Signals using Callable ---
	# Check node validity before connecting
	if is_instance_valid(pencil_hitbox):
		pencil_hitbox.body_entered.connect(Callable(self, "_on_pencil_hitbox_body_entered"))
	else:
		print("ERROR (Calculator): PencilHitbox node invalid/missing in _ready!")

	if is_instance_valid(protractor_hitbox):
		protractor_hitbox.body_entered.connect(Callable(self, "_on_protractor_hitbox_body_entered"))
	else:
		print("ERROR (Calculator): ProtractorHitbox node invalid/missing in _ready!")

	if is_instance_valid(animated_sprite):
		# THIS IS THE CRITICAL CONNECTION FOR THE ERROR
		animated_sprite.animation_finished.connect(Callable(self, "_on_animation_finished"))
	else:
		print("ERROR (Calculator): AnimatedSprite2D node invalid/missing in _ready!")

	# Disable hitboxes initially
	if is_instance_valid(pencil_hitbox_shape): pencil_hitbox_shape.disabled = true
	if is_instance_valid(protractor_hitbox_shape): protractor_hitbox_shape.disabled = true

	print("Calculator Ready. HP=", current_hp)


func register_with_ui():
	var game_ui = get_tree().get_first_node_in_group("game_ui")
	if is_instance_valid(game_ui) and game_ui.has_method("register_boss"):
		game_ui.register_boss(self)
	# else: print("WARNING: Calculator could not find/register with Game UI.")


# --- Core Logic ---
func _physics_process(delta: float) -> void:
	# No Gravity for Flying
	match current_state:
		State.DEAD:
			velocity = Vector2.ZERO; move_and_slide(); return
		State.ERROR, State.PENCIL_JAB, State.PROTRACTOR_SLICE, State.MULTIPLY_BUFF:
			handle_action_state_movement(delta); move_and_slide(); return
		_: # IDLE, MOVE
			if can_act: find_player_and_decide_action(delta)
			handle_idle_move_state(delta)
	move_and_slide()


func find_player_and_decide_action(delta: float):
	if player_node == null or not is_instance_valid(player_node):
		player_node = get_tree().get_first_node_in_group("player")
	if is_instance_valid(player_node):
		ai_timer -= delta
		if ai_timer <= 0:
			choose_action()
			ai_timer = ai_cooldown * randf_range(0.8, 1.2)
	else: current_state = State.IDLE # No player, stay idle


func handle_action_state_movement(delta: float) -> void:
	var friction = speed * delta * 3 # Define friction factor
	match current_state:
		State.ERROR: velocity = velocity.move_toward(Vector2.ZERO, friction)
		State.PENCIL_JAB:
			velocity = velocity.move_toward(Vector2.ZERO, friction * 0.8)
			handle_attack_hitbox(pencil_hitbox_shape, "pencil_jab", 6)
		State.PROTRACTOR_SLICE:
			velocity = velocity.move_toward(Vector2.ZERO, friction * 0.6)
			handle_attack_hitbox(protractor_hitbox_shape, "protractor_slice", 7)
		State.MULTIPLY_BUFF:
			velocity = velocity.move_toward(Vector2.ZERO, friction * 0.9)
			if animated_sprite.animation == "multiplication_buff" and animated_sprite.frame == 17: apply_multiplication_buff()


func handle_idle_move_state(delta: float) -> void:
	var target_velocity = Vector2.ZERO
	if current_state == State.MOVE and is_instance_valid(player_node):
		var vector_to_player = player_node.global_position - global_position
		target_velocity.x = vector_to_player.normalized().x * speed
		var y_diff = vector_to_player.y
		if abs(y_diff) > hover_deadzone: target_velocity.y = sign(y_diff) * speed * follow_y_speed_multiplier
		if abs(target_velocity.x) > 1.0: animated_sprite.flip_h = (target_velocity.x > 0)
		play_animation("move")
	elif current_state == State.IDLE:
		play_animation("idle")
	velocity = velocity.move_toward(target_velocity, speed * delta * 4)


func choose_action() -> void:
	if not is_instance_valid(player_node): current_state = State.IDLE; return
	var distance = global_position.distance_to(player_node.global_position)
	var vector_to_player = player_node.global_position - global_position
	var low_hp = current_hp <= max_hp * low_health_threshold
	animated_sprite.flip_h = (vector_to_player.x > 0) # Face Player
	if distance > detection_radius * 1.5: current_state = State.IDLE; return

	if low_hp and randf() <= buff_chance and current_state != State.MULTIPLY_BUFF: initiate_multiplication_buff()
	elif distance <= protractor_slice_range: initiate_protractor_slice()
	elif distance <= pencil_jab_range: initiate_pencil_jab()
	else: current_state = State.MOVE


func initiate_pencil_jab():
	if not can_act: return
	current_state = State.PENCIL_JAB; can_act = false; attack_hit_registered = false; play_animation("pencil_jab")
func initiate_protractor_slice():
	if not can_act: return
	current_state = State.PROTRACTOR_SLICE; can_act = false; attack_hit_registered = false; play_animation("protractor_slice")
func initiate_multiplication_buff():
	if not can_act: return
	current_state = State.MULTIPLY_BUFF; can_act = false; play_animation("multiplication_buff")


func handle_attack_hitbox(shape: CollisionShape2D, anim_name: String, hit_frame: int):
	if not is_instance_valid(shape) or not is_instance_valid(animated_sprite): return
	if animated_sprite.animation != anim_name: return # Only check for the relevant animation
	var start_frame = hit_frame
	var end_frame = hit_frame + 2 # Active for 3 frames
	var current_frame = animated_sprite.frame

	if current_frame >= start_frame and current_frame <= end_frame:
		if shape.disabled and not attack_hit_registered: shape.disabled = false
	else:
		if not shape.disabled: shape.disabled = true


func apply_multiplication_buff(): print("Calculator: Buff Applied!")


func take_damage(amount: int):
	if current_state == State.DEAD or current_state == State.ERROR: return
	current_hp -= amount
	emit_signal("hp_changed", current_hp, max_hp)
	print("Calculator took damage:", amount, "| HP:", current_hp, "/", max_hp)
	if is_instance_valid(pencil_hitbox_shape): pencil_hitbox_shape.disabled = true
	if is_instance_valid(protractor_hitbox_shape): protractor_hitbox_shape.disabled = true

	if current_hp <= 0: current_hp = 0; _die()
	else:
		current_state = State.ERROR; can_act = false; play_animation("error")
		if is_instance_valid(player_node):
			velocity = (global_position - player_node.global_position).normalized() * 120


func _die():
	if current_state == State.DEAD: return
	print("Calculator: Defeated!")
	current_state = State.DEAD; can_act = false; velocity = Vector2.ZERO
	set_collision_layer_value(3, false); set_collision_mask_value(1, false)
	if is_instance_valid(hurtbox): hurtbox.set_collision_layer_value(5, false)
	if is_instance_valid(pencil_hitbox_shape): pencil_hitbox_shape.disabled = true
	if is_instance_valid(protractor_hitbox_shape): protractor_hitbox_shape.disabled = true
	play_animation("death"); emit_signal("died")


func play_animation(anim_name: String) -> void:
	if current_state == State.DEAD and anim_name != "death": return
	if is_instance_valid(animated_sprite) and animated_sprite.sprite_frames.has_animation(anim_name):
		if animated_sprite.animation != anim_name: animated_sprite.play(anim_name)


# --- Signal Handlers ---

# THIS FUNCTION MUST EXIST AND BE SPELLED EXACTLY LIKE THIS
func _on_animation_finished() -> void:
	var finished_anim = animated_sprite.animation
	# print("DEBUG: Anim finished:", finished_anim, "| Current State:", State.keys()[current_state]) # Uncomment for deep debug

	# Safety disable hitboxes
	if finished_anim in ["pencil_jab", "protractor_slice"]:
		if is_instance_valid(pencil_hitbox_shape): pencil_hitbox_shape.disabled = true
		if is_instance_valid(protractor_hitbox_shape): protractor_hitbox_shape.disabled = true
		attack_hit_registered = false

	if current_state != State.DEAD:
		# Convert state enum value to string for comparison with animation name string
		var current_state_str = State.keys()[current_state]
		var finished_anim_state_equivalent = finished_anim.to_upper() # Convert anim name to potential state name format

		# Reset state only if the finished animation matches the current state
		if current_state_str == finished_anim_state_equivalent:
			match finished_anim:
				"pencil_jab", "protractor_slice", "multiplication_buff", "error":
					# print("DEBUG: Resetting state from", finished_anim, "to IDLE") # Uncomment for deep debug
					current_state = State.IDLE; can_act = true
					ai_timer = ai_cooldown * randf_range(0.1, 0.5) # Short cooldown
		# Handle specific non-state-resetting finishes if needed
		elif finished_anim == "death":
			print("Calculator death animation finished.")
			# Example: Make invisible after animation completes
			# visible = false
			# Or stop processing completely
			# set_physics_process(false)
			pass


# Make sure this function exists and is spelled correctly
func _on_pencil_hitbox_body_entered(body: Node2D):
	if pencil_hitbox_shape.disabled or attack_hit_registered: return
	if body.is_in_group("player") and body.has_method("take_damage"):
		# print("DEBUG: Calling Player take_damage from Pencil") # Uncomment for deep debug
		body.call("take_damage", pencil_jab_damage)
		attack_hit_registered = true; pencil_hitbox_shape.disabled = true


# Make sure this function exists and is spelled correctly
func _on_protractor_hitbox_body_entered(body: Node2D):
	if protractor_hitbox_shape.disabled or attack_hit_registered: return
	if body.is_in_group("player") and body.has_method("take_damage"):
		# print("DEBUG: Calling Player take_damage from Protractor") # Uncomment for deep debug
		body.call("take_damage", protractor_slice_damage)
		attack_hit_registered = true; protractor_hitbox_shape.disabled = true
