extends RefCounted

## Entrées unifiées : UNE couche au-dessus d'InputMap (clavier/souris/manette) et
## de l'action map OpenXR (VR), que Godot ne sait pas fusionner. Chaque action
## porte une LISTE de bindings de sources variées ; sa valeur est le max des
## bindings, en 0.0..1.0. Un bouton donne 0/1, un stick sa course réelle.
##
## Persisté dans user://input.csv : une ligne par action, `action,binding;binding`.
## Un binding s'écrit `source:params` — voir _binding_vers_texte.

const FICHIER := "user://input.csv"

## L'index EST le code du contrat.
## 0=gauche 1=droite 2=haut(avant) 3=bas(arrière) 4=action 5=retour 6=saut
const ACTIONS := [
	"move_left", "move_right", "move_forward", "move_back", "action", "back", "jump",
]

## Toutes les actions remappables. Au-delà des 7 codes du contrat : `menu`, une
## entrée de PLATEFORME (ouvrir/fermer le menu), jamais envoyée au serveur.
const NOMS := [
	"move_left", "move_right", "move_forward", "move_back", "action", "back", "jump",
	"menu",
]

## nom d'action -> Array de bindings (chaque binding = Dictionary {source, ...}).
var bindings := {}
## Le rig VR, pour lire les manettes. Null hors VR.
var vr


func _init(rig) -> void:
	vr = rig
	charger()


## --- Lecture ---

## Valeur d'un code du contrat, 0.0..1.0.
func value(code: int) -> float:
	if code < 0 or code >= ACTIONS.size():
		return 0.0
	return value_action(ACTIONS[code])


## La plus forte des sources : stick à moitié + touche tenue -> la touche gagne.
func value_action(nom: String) -> float:
	var maximum := 0.0
	for binding in bindings.get(nom, []):
		maximum = maxf(maximum, _valeur_binding(binding))
	return maximum


func _valeur_binding(binding: Dictionary) -> float:
	match binding["source"]:
		"key":   return _valeur_touche(binding)
		"mouse": return _valeur_souris(binding)
		"padb":  return _valeur_pad_bouton(binding)
		"pada":  return _valeur_pad_axe(binding)
		"vrb":   return _valeur_vr_bouton(binding)
		"vra":   return _valeur_vr_axe(binding)
	return 0.0


# --- Sources numériques (0/1) ---

func _valeur_touche(binding: Dictionary) -> float:
	return 1.0 if Input.is_physical_key_pressed(binding["code"]) else 0.0


func _valeur_souris(binding: Dictionary) -> float:
	return 1.0 if Input.is_mouse_button_pressed(binding["button"]) else 0.0


func _valeur_pad_bouton(binding: Dictionary) -> float:
	return 1.0 if Input.is_joy_button_pressed(0, binding["button"]) else 0.0


func _valeur_vr_bouton(binding: Dictionary) -> float:
	if vr == null or not vr.actif:
		return 0.0
	return 1.0 if vr.bouton(binding["hand"], binding["name"]) else 0.0


# --- Sources analogiques (course, zone morte appliquée) ---

func _valeur_pad_axe(binding: Dictionary) -> float:
	var brut := Input.get_joy_axis(0, binding["axis"])
	return _apres_zone_morte(maxf(0.0, brut * binding["sign"]))


func _valeur_vr_axe(binding: Dictionary) -> float:
	if vr == null or not vr.actif:
		return 0.0
	var vecteur: Vector2 = vr.axe(binding["hand"], binding["name"])
	var composante := vecteur.x if binding["comp"] == "x" else vecteur.y
	return _apres_zone_morte(maxf(0.0, composante * binding["sign"]))


## Rejette le bruit sous la zone morte et rééchelonne le reste sur 0..1, sinon
## le mouvement démarrerait par un saut à la sortie de la zone morte.
func _apres_zone_morte(valeur: float) -> float:
	var morte: float = Settings.get_value("controls.deadzone") / 100.0
	if valeur <= morte:
		return 0.0
	return (valeur - morte) / (1.0 - morte)


## --- Remappage (données) ---

func bindings_de(nom: String) -> Array:
	return bindings.get(nom, [])


func ajouter_binding(nom: String, binding: Dictionary) -> void:
	bindings[nom].append(binding)
	sauver()


func retirer_binding(nom: String, index: int) -> void:
	bindings[nom].remove_at(index)
	sauver()


func reset() -> void:
	bindings = _defauts()
	sauver()


## Construit un binding depuis un événement clavier / souris / bouton manette.
## Renvoie un dict vide si l'événement n'est pas une pression capturable.
## (Les sticks se capturent par scrutation, ajoutée avec l'UI de remappage.)
func binding_depuis_evenement(evenement: InputEvent) -> Dictionary:
	var touche := evenement as InputEventKey
	if touche != null and touche.pressed:
		return _touche(touche.physical_keycode)

	var souris := evenement as InputEventMouseButton
	if souris != null and souris.pressed:
		return _souris(souris.button_index)

	var pad := evenement as InputEventJoypadButton
	if pad != null and pad.pressed:
		return _pad_bouton(pad.button_index)

	return {}


## --- Persistance ---

func charger() -> void:
	bindings = _defauts()

	var fichier := FileAccess.open(FICHIER, FileAccess.READ)
	if fichier == null:
		return
	while not fichier.eof_reached():
		var ligne := fichier.get_line().strip_edges()
		if ligne.is_empty():
			continue
		var separateur := ligne.find(",")
		if separateur < 0:
			continue
		var nom := ligne.substr(0, separateur)
		if not NOMS.has(nom):
			continue
		bindings[nom] = _liste_depuis_texte(ligne.substr(separateur + 1))
	fichier.close()


func sauver() -> void:
	var fichier := FileAccess.open(FICHIER, FileAccess.WRITE)
	if fichier == null:
		push_error("Input : écriture impossible dans %s" % FICHIER)
		return
	for nom in NOMS:
		fichier.store_line("%s,%s" % [nom, _liste_vers_texte(bindings[nom])])
	fichier.close()


func _liste_vers_texte(liste: Array) -> String:
	var morceaux := []
	for binding in liste:
		morceaux.append(_binding_vers_texte(binding))
	return ";".join(morceaux)


## Une ligne peut être vide : une action sans aucun binding est légale.
func _liste_depuis_texte(texte: String) -> Array:
	var liste := []
	if texte.is_empty():
		return liste
	for morceau in texte.split(";"):
		var binding := _binding_depuis_texte(morceau)
		if not binding.is_empty():
			liste.append(binding)
	return liste


func _binding_vers_texte(binding: Dictionary) -> String:
	match binding["source"]:
		"key":   return "key:%d" % binding["code"]
		"mouse": return "mouse:%d" % binding["button"]
		"padb":  return "padb:%d" % binding["button"]
		"pada":  return "pada:%d:%s" % [binding["axis"], _signe_texte(binding["sign"])]
		"vrb":   return "vrb:%s:%s" % [binding["hand"], binding["name"]]
		"vra":   return "vra:%s:%s:%s:%s" % [
			binding["hand"], binding["name"], binding["comp"], _signe_texte(binding["sign"])
		]
	return ""


func _binding_depuis_texte(texte: String) -> Dictionary:
	var parts := texte.split(":")
	match parts[0]:
		"key":   return _touche(int(parts[1]))
		"mouse": return _souris(int(parts[1]))
		"padb":  return _pad_bouton(int(parts[1]))
		"pada":  return _pad_axe(int(parts[1]), _signe_valeur(parts[2]))
		"vrb":   return _vr_bouton(parts[1], parts[2])
		"vra":   return _vr_axe(parts[1], parts[2], parts[3], _signe_valeur(parts[4]))
	return {}


func _signe_texte(signe: int) -> String:
	return "+" if signe > 0 else "-"


func _signe_valeur(texte: String) -> int:
	return 1 if texte == "+" else -1


## --- Constructeurs de bindings ---

func _touche(code: int) -> Dictionary:
	return {"source": "key", "code": code}


func _souris(button: int) -> Dictionary:
	return {"source": "mouse", "button": button}


func _pad_bouton(button: int) -> Dictionary:
	return {"source": "padb", "button": button}


func _pad_axe(axis: int, sign: int) -> Dictionary:
	return {"source": "pada", "axis": axis, "sign": sign}


func _vr_bouton(hand: String, name: String) -> Dictionary:
	return {"source": "vrb", "hand": hand, "name": name}


func _vr_axe(hand: String, name: String, comp: String, sign: int) -> Dictionary:
	return {"source": "vra", "hand": hand, "name": name, "comp": comp, "sign": sign}


## --- Défauts : un binding clavier + un manette + un VR par action ---
##
## Manette : stick gauche (axe 0 = X, axe 1 = Y, Y négatif = avant). Boutons
## A=0 B=1 X=2. VR : stick gauche `primary`, gâchette/A/B droits.

func _defauts() -> Dictionary:
	return {
		"move_left":    [_touche(KEY_A), _pad_axe(0, -1), _vr_axe("left", "primary", "x", -1)],
		"move_right":   [_touche(KEY_D), _pad_axe(0, 1),  _vr_axe("left", "primary", "x", 1)],
		"move_forward": [_touche(KEY_W), _pad_axe(1, -1), _vr_axe("left", "primary", "y", 1)],
		"move_back":    [_touche(KEY_S), _pad_axe(1, 1),  _vr_axe("left", "primary", "y", -1)],
		"action":       [_touche(KEY_E), _pad_bouton(2), _vr_bouton("right", "trigger_click")],
		"back":         [_touche(KEY_Q), _pad_bouton(1), _vr_bouton("right", "by_button")],
		"jump":         [_touche(KEY_SPACE), _pad_bouton(0), _vr_bouton("right", "ax_button")],
		# Ouvre/ferme le menu. Bouton Y (gauche) en VR — le bouton menu est capté
		# par SteamVR. Start à la manette Xbox, Échap au clavier.
		"menu":         [_touche(KEY_ESCAPE), _pad_bouton(6), _vr_bouton("left", "by_button")],
	}
