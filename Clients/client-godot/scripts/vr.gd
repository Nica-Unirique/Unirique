extends XROrigin3D

## Le rig VR. Reste inerte si aucun casque n'est disponible — le client bascule
## alors sur sa caméra classique, sans réglage à toucher.
##
## Testé avec un Meta Quest 2 via Steam Link, donc runtime OpenXR de SteamVR.

## Vitesse de rotation au joystick droit, en radians par seconde. Indispensable
## assis : sans elle il faudrait se retourner physiquement.
const VITESSE_ROTATION := 2.5
## En deçà, le joystick est considéré au repos. Les manettes ne reviennent
## jamais exactement à zéro.
const ZONE_MORTE := 0.3

var actif := false
var camera: XRCamera3D
var main_gauche: XRController3D
var main_droite: XRController3D


## Tente d'ouvrir OpenXR. Faux si aucun casque, ce qui n'est pas une erreur.
func demarrer() -> bool:
	var interface := XRServer.find_interface("OpenXR")
	if interface == null:
		return false
	if not interface.is_initialized() and not interface.initialize():
		return false

	_construire_rig()
	get_viewport().use_xr = true

	# Le casque impose sa cadence. Les réglages d'affichage du joueur ne
	# s'appliquent pas ici : une limite de FPS ou la vsync donneraient des
	# saccades et la nausée.
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)

	actif = true
	return true


func _construire_rig() -> void:
	camera = XRCamera3D.new()
	add_child(camera)

	main_gauche = _creer_main("left_hand")
	main_droite = _creer_main("right_hand")


func _creer_main(tracker: String) -> XRController3D:
	var main := XRController3D.new()
	main.tracker = tracker
	add_child(main)
	return main


## --- Regard et rotation (spécifiques VR, hors système d'actions) ---

## Lacet du casque, relatif à l'origine. Ajouté à la rotation manuelle, il donne
## la direction réelle du regard.
func lacet_casque() -> float:
	if not actif:
		return 0.0
	return camera.transform.basis.get_euler().y


## Joystick droit, axe horizontal : rotation du corps (confort, pas une action).
func entree_rotation() -> float:
	if not actif:
		return 0.0
	var valeur := main_droite.get_vector2("primary").x
	return 0.0 if absf(valeur) < ZONE_MORTE else valeur


## --- Accès brut aux manettes, pour le système d'entrées unifié ---

## `main` = "left" ou "right". Bouton maintenu ?
func bouton(main: String, nom: String) -> bool:
	if not actif:
		return false
	return _main(main).is_button_pressed(nom)


## Axe 2D d'une manette (ex. "primary" = joystick). Zéro hors zone morte non
## appliquée ici : le système d'entrées seuille lui-même.
func axe(main: String, nom: String) -> Vector2:
	if not actif:
		return Vector2.ZERO
	return _main(main).get_vector2(nom)


func _main(main: String) -> XRController3D:
	return main_droite if main == "right" else main_gauche


## Transform globale d'une manette : origine + orientation de son rayon.
func transform_pointeur(main: String) -> Transform3D:
	if not actif:
		return Transform3D.IDENTITY
	return _main(main).global_transform


## Vibration courte, pour confirmer un clic. force et durée en 0..1 / secondes.
func vibrer(main: String, force: float, duree: float) -> void:
	if not actif:
		return
	_main(main).trigger_haptic_pulse("haptic", 0.0, force, duree, 0.0)
