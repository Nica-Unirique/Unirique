extends Node

## Reglages de la plateforme, persistes dans un CSV "cle,valeur".
##
## Deux dictionnaires : `values` = ce qui est enregistre, `pending` = les
## modifications en attente. Le menu ecrit dans `pending` ; `apply()` valide
## et enregistre, `cancel()` jette.
##
## A declarer en autoload sous le nom "Settings".

const FICHIER := "user://setting.csv"

## Declaration de chaque reglage : type de valeur, defaut, et domaine
## (`choix` = liste fermee, `min`/`max` = intervalle).
const DECLARATIONS := {
	"display.window_mode": {
		"type": TYPE_STRING, "defaut": "windowed",
		"choix": ["windowed", "borderless", "fullscreen"],
	},
	"display.aspect_ratio": {
		"type": TYPE_STRING, "defaut": "16/9",
		"choix": ["16/9", "16/10", "21/9", "4/3"],
	},
	"display.resolution": {  # hauteur en pixels, la largeur se deduit du ratio
		"type": TYPE_INT, "defaut": 1080,
		"choix": [720, 1080, 1440, 2160],
	},
	"display.fps_limit": {  # -1 = illimite
		"type": TYPE_INT, "defaut": 60,
		"choix": [-1, 60, 120, 144],
	},
	"display.vsync": {"type": TYPE_BOOL, "defaut": true},
	"display.quality": {
		"type": TYPE_STRING, "defaut": "medium",
		"choix": ["low", "medium", "high", "custom"],
		# `grise` : valeurs affichables mais non choisissables. Ici "custom" est
		# un etat atteint automatiquement, jamais un choix.
		"grise": ["custom"],
	},
	"display.msaa": {  # nombre d'echantillons
		"type": TYPE_INT, "defaut": 2,
		"choix": [0, 2, 4, 8],
	},
	"display.render_scale": {  # en pourcent
		"type": TYPE_INT, "defaut": 100,
		"choix": [50, 75, 100, 125],
	},
	"display.shadow_size": {
		"type": TYPE_INT, "defaut": 2048,
		"choix": [1024, 2048, 4096, 8192],
	},
	"display.anisotropic": {
		# Verrouille : Godot ne lit ce parametre qu'a la creation des textures,
		# il n'est pas applicable a l'execution. Affiche, jamais modifie.
		"type": TYPE_INT, "defaut": 4,
		"choix": [1, 2, 4, 8, 16],
		"verrouille": true,
	},
	"display.ssao": {"type": TYPE_BOOL, "defaut": false},
	"display.fov": {"type": TYPE_INT, "defaut": 75, "min": 60, "max": 110},

	"audio.volume_general": {"type": TYPE_INT, "defaut": 80, "min": 0, "max": 100},
	# Verrouilles : ces bus n'existent pas, et le contrat n'a aucune fonction son.
	"audio.volume_game": {
		"type": TYPE_INT, "defaut": 80, "min": 0, "max": 100, "verrouille": true,
	},
	"audio.volume_ui": {
		"type": TYPE_INT, "defaut": 80, "min": 0, "max": 100, "verrouille": true,
	},
	# Verrouille : pas de VoIP.
	"audio.volume_voice": {
		"type": TYPE_INT, "defaut": 80, "min": 0, "max": 100, "verrouille": true,
	},

	"controls.mouse_sensitivity": {"type": TYPE_INT, "defaut": 50, "min": 1, "max": 100},
	"controls.invert_y": {"type": TYPE_BOOL, "defaut": false},
	"controls.gamepad": {"type": TYPE_BOOL, "defaut": true},
	"controls.deadzone": {"type": TYPE_INT, "defaut": 15, "min": 0, "max": 50},

	# Verrouille : aucun fichier de traduction.
	"interface.language": {
		"type": TYPE_STRING, "defaut": "fr",
		"choix": ["fr", "en"],
		"verrouille": true,
	},
	"interface.text_size": {"type": TYPE_INT, "defaut": 100, "min": 50, "max": 200},
	"interface.menu_opacity": {"type": TYPE_INT, "defaut": 50, "min": 0, "max": 100},
	"interface.show_fps": {"type": TYPE_BOOL, "defaut": false},

	## Mon serveur de jeu local. `publish` decide s'il figure dans l'annuaire
	## (nom, jeu, nombre de joueurs) ; `visibility` decide qui obtient son
	## ADRESSE. Un serveur publie en `nobody` se voit donc sans se rejoindre.
	"server.publish": {"type": TYPE_BOOL, "defaut": true},
	## UPnP demande a la box d'ouvrir le port, et revele l'adresse publique.
	## Modifier le routeur ne va pas de soi : on doit pouvoir le refuser.
	## Sans lui, restent l'IPv6 (qui n'en a pas besoin) et le reseau local.
	"server.upnp": {"type": TYPE_BOOL, "defaut": true},
	"server.visibility": {
		"type": TYPE_STRING, "defaut": "friends",
		"choix": ["nobody", "friends", "friends_plus", "invite", "invite_plus"],
		# Grises tant que les invitations n'existent pas : le serveur data les
		# refuse, les choisir rendrait le serveur injoignable sans le dire.
		"grise": ["invite", "invite_plus"],
	},

	# Verrouilles : il n'y a pas de serveur.
	"network.region": {
		"type": TYPE_STRING, "defaut": "auto",
		"choix": ["auto", "eu", "na", "asia"],
		"verrouille": true,
	},
	"network.show_ping": {"type": TYPE_BOOL, "defaut": false, "verrouille": true},
}

## La qualite est un prereglage : la choisir ecrit les cles pilotees ci-dessous,
## et modifier l'une d'elles a la main fait retomber la qualite sur "custom".
const CLE_QUALITY := "display.quality"
const QUALITY_KEYS := [
	"display.msaa",
	"display.render_scale",
	"display.shadow_size",
	"display.ssao",
]
const QUALITY_PRESETS := {
	"low": {
		"display.msaa": 0, "display.render_scale": 75,
		"display.shadow_size": 1024, "display.ssao": false,
	},
	"medium": {
		"display.msaa": 2, "display.render_scale": 100,
		"display.shadow_size": 2048, "display.ssao": false,
	},
	"high": {
		"display.msaa": 4, "display.render_scale": 100,
		"display.shadow_size": 4096, "display.ssao": true,
	},
}

## Emis a chaque valeur reposee. Sert au menu a se resynchroniser quand un
## reglage en pilote d'autres.
signal changed(cle: String)

## Emis quand les valeurs enregistrees deviennent effectives : au chargement et
## a chaque `apply()`. Chaque objet s'y abonne pour appliquer ce qu'il possede.
signal applied

var values := {}
var pending := {}


func _ready() -> void:
	read_file()


## --- Lecture / ecriture ---

## Charge le CSV. Toute cle absente ou illisible retombe sur son defaut.
func read_file() -> void:
	values = _defauts()
	pending.clear()

	var fichier := FileAccess.open(FICHIER, FileAccess.READ)
	if fichier == null:
		applied.emit()  # premier lancement : les defauts sont deja effectifs
		return

	while not fichier.eof_reached():
		var ligne := fichier.get_line().strip_edges()
		if ligne.is_empty():
			continue
		var separateur := ligne.find(",")
		if separateur < 0:
			continue
		var cle := ligne.substr(0, separateur)
		if not DECLARATIONS.has(cle):
			continue
		values[cle] = _depuis_texte(cle, ligne.substr(separateur + 1))
	fichier.close()
	applied.emit()


## Reecrit le CSV entier, dans l'ordre des declarations.
func write_file() -> void:
	var fichier := FileAccess.open(FICHIER, FileAccess.WRITE)
	if fichier == null:
		push_error("Settings : ecriture impossible dans %s" % FICHIER)
		return
	for cle in DECLARATIONS:
		fichier.store_line("%s,%s" % [cle, _vers_texte(values[cle])])
	fichier.close()


## --- Lecture / modification par le menu ---

## La valeur en attente si elle existe, sinon la valeur enregistree.
func get_value(cle: String):
	if pending.has(cle):
		return pending[cle]
	return values[cle]


## Repose la valeur en attente, puis propage le lien qualite <-> cles pilotees.
func set_value(cle: String, valeur) -> void:
	if not DECLARATIONS.has(cle):
		push_error("Settings : cle inconnue %s" % cle)
		return
	if DECLARATIONS[cle].get("verrouille", false):
		return

	_poser(cle, valeur)
	if cle == CLE_QUALITY:
		_poser_preset(valeur)
	elif QUALITY_KEYS.has(cle):
		_poser(CLE_QUALITY, "custom")
	changed.emit(cle)


func is_dirty() -> bool:
	return not pending.is_empty()


## --- Apply / Cancel ---

func apply() -> void:
	for cle in pending:
		values[cle] = pending[cle]
	pending.clear()
	write_file()
	applied.emit()


func cancel() -> void:
	pending.clear()


## Remet les defauts en attente : annulable tant qu'`apply()` n'est pas appele.
## Passe par `_poser` et non `set_value` : les defauts sont deja coherents entre
## eux, les repropager ferait retomber la qualite sur "custom".
func reset_to_defaults() -> void:
	for cle: String in DECLARATIONS:
		_poser(cle, DECLARATIONS[cle]["defaut"])
	changed.emit(CLE_QUALITY)


## --- Interne ---

## Ecrit une valeur en attente, sans aucune propagation. Revenir a la valeur
## enregistree retire l'entree : `is_dirty()` retombe a faux tout seul.
func _poser(cle: String, valeur) -> void:
	if values[cle] == valeur:
		pending.erase(cle)
		return
	pending[cle] = valeur


## Ecrit les cles d'un prereglage. "custom" n'en est pas un : il n'ecrit rien.
func _poser_preset(nom: String) -> void:
	if not QUALITY_PRESETS.has(nom):
		return
	var preset: Dictionary = QUALITY_PRESETS[nom]
	for cle: String in preset:
		_poser(cle, preset[cle])


func _defauts() -> Dictionary:
	var resultat := {}
	for cle in DECLARATIONS:
		resultat[cle] = DECLARATIONS[cle]["defaut"]
	return resultat


func _depuis_texte(cle: String, texte: String):
	var declaration: Dictionary = DECLARATIONS[cle]
	match declaration["type"]:
		TYPE_BOOL:
			return texte == "true"
		TYPE_INT:
			if not texte.is_valid_int():
				return declaration["defaut"]
			return texte.to_int()
		_:
			return texte


func _vers_texte(valeur) -> String:
	if typeof(valeur) == TYPE_BOOL:
		return "true" if valeur else "false"
	return str(valeur)
