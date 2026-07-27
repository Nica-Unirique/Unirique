extends Node

## Applique les reglages qui ne dependent de rien dans la scene : fenetre,
## rendu, audio, entrees. Tout ce qui appartient a un objet precis (la camera,
## le menu) est applique par cet objet, pas ici.
##
## A declarer en autoload sous le nom "SettingsApply", APRES "Settings".

## Les 6 actions du contrat, sur lesquelles porte la zone morte.
const ACTIONS := ["ui_left", "ui_right", "ui_up", "ui_down", "ui_accept", "ui_cancel"]

const MODES_FENETRE := {
	"windowed": DisplayServer.WINDOW_MODE_WINDOWED,
	"borderless": DisplayServer.WINDOW_MODE_FULLSCREEN,
	"fullscreen": DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN,
}

const MODES_MSAA := {
	0: Viewport.MSAA_DISABLED,
	2: Viewport.MSAA_2X,
	4: Viewport.MSAA_4X,
	8: Viewport.MSAA_8X,
}


## Les evenements manette de chaque action, releves une fois au demarrage :
## desactiver la manette les retire de l'InputMap, il faut donc les garder.
var evenements_manette := {}


func _ready() -> void:
	_relever_manette()
	Settings.applied.connect(_tout_appliquer)
	_tout_appliquer()


func _relever_manette() -> void:
	for action in ACTIONS:
		if not InputMap.has_action(action):
			continue
		var releves := []
		for evenement in InputMap.action_get_events(action):
			if evenement is InputEventJoypadButton or evenement is InputEventJoypadMotion:
				releves.append(evenement)
		evenements_manette[action] = releves


func _tout_appliquer() -> void:
	# Un serveur headless n'a ni fenêtre, ni rendu, ni son, ni joueur devant lui.
	# Lui appliquer `display.fps_limit` quantifiait sa cadence de réplication.
	if DisplayServer.get_name() == "headless":
		return

	# En VR, c'est le casque qui impose la cadence et la fenêtre. Réappliquer
	# `fps_limit` ou la vsync ici donnerait des saccades, donc la nausée.
	if XRServer.primary_interface == null:
		_appliquer_fenetre()
	_appliquer_rendu()
	_appliquer_audio()
	_appliquer_entrees()


func _appliquer_fenetre() -> void:
	var mode: String = Settings.get_value("display.window_mode")
	DisplayServer.window_set_mode(MODES_FENETRE[mode])

	# La taille n'a de sens qu'en fenetre : les deux plein ecran suivent l'ecran.
	# Integree dans l'editeur, la fenetre n'est pas redimensionnable.
	if mode == "windowed" and not get_window().is_embedded():
		DisplayServer.window_set_size(_taille_fenetre())

	var limite: int = Settings.get_value("display.fps_limit")
	Engine.max_fps = 0 if limite < 0 else limite  # 0 = illimite cote Godot

	var vsync: bool = Settings.get_value("display.vsync")
	DisplayServer.window_set_vsync_mode(
		DisplayServer.VSYNC_ENABLED if vsync else DisplayServer.VSYNC_DISABLED
	)


## La hauteur est stockee, la largeur se deduit du format.
func _taille_fenetre() -> Vector2i:
	var hauteur: int = Settings.get_value("display.resolution")
	var format: String = Settings.get_value("display.aspect_ratio")
	var largeur := int(round(
		hauteur * float(format.get_slice("/", 0)) / float(format.get_slice("/", 1))
	))
	return Vector2i(largeur, hauteur)


func _appliquer_rendu() -> void:
	var vue := get_viewport()

	vue.msaa_3d = MODES_MSAA[Settings.get_value("display.msaa")]
	vue.scaling_3d_scale = Settings.get_value("display.render_scale") / 100.0

	var ombres: int = Settings.get_value("display.shadow_size")
	vue.positional_shadow_atlas_size = ombres
	RenderingServer.directional_shadow_atlas_set_size(ombres, true)


func _appliquer_audio() -> void:
	var volume: int = Settings.get_value("audio.volume_general")
	AudioServer.set_bus_mute(0, volume == 0)
	AudioServer.set_bus_volume_db(0, linear_to_db(volume / 100.0))


func _appliquer_entrees() -> void:
	var zone_morte: float = Settings.get_value("controls.deadzone") / 100.0
	for action in ACTIONS:
		if InputMap.has_action(action):
			InputMap.action_set_deadzone(action, zone_morte)

	_appliquer_manette(Settings.get_value("controls.gamepad"))


## Manette coupee : ses evenements sortent de l'InputMap, le clavier reste.
func _appliquer_manette(actif: bool) -> void:
	for action: String in evenements_manette:
		for evenement: InputEvent in evenements_manette[action]:
			var present := InputMap.action_has_event(action, evenement)
			if actif and not present:
				InputMap.action_add_event(action, evenement)
			elif not actif and present:
				InputMap.action_erase_event(action, evenement)
