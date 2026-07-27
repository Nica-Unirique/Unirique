extends GridContainer

## Grille des 24 mots d'une phrase secrète, numérotés « n: mot ».
##
## Composant PARTAGÉ : l'assistant de connexion la remplit, le profil l'affiche.
## Aucun des deux ne dépend de l'autre — tous deux dépendent d'ici. C'est ce qui
## garantit que la phrase se présente partout de la même façon.

const Mots := preload("res://scripts/mots.gd")

const COLONNES := 6
const ESPACEMENT := 16
## Plus large que l'horizontal : sans ça les 24 mots forment un bloc illisible.
const ESPACEMENT_RANGEES := 18
const LARGEUR_CHAMP := 91
const LARGEUR_NUMERO := 28

const BLANC := Color(1, 1, 1)
const VERT := Color(0.55, 1.0, 0.55)
const ROUGE := Color(1.0, 0.5, 0.5)

var mots: Mots
var champs: Array[LineEdit] = []


## `contenu` peut être vide (grille à remplir). `modifiable` faux donne une
## grille de lecture, à la même place et au même format.
func construire(un_mots: Mots, contenu: PackedStringArray, modifiable: bool) -> void:
	mots = un_mots
	columns = COLONNES
	add_theme_constant_override("h_separation", ESPACEMENT)
	add_theme_constant_override("v_separation", ESPACEMENT_RANGEES)

	for rang in Mots.NB_MOTS:
		var ligne := HBoxContainer.new()

		var numero := Label.new()
		numero.text = "%d:" % (rang + 1)
		numero.custom_minimum_size.x = LARGEUR_NUMERO
		numero.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		numero.add_theme_color_override("font_color", BLANC)
		ligne.add_child(numero)

		var champ := LineEdit.new()
		champ.custom_minimum_size.x = LARGEUR_CHAMP
		champ.editable = modifiable
		_teinter(champ, BLANC)
		if rang < contenu.size():
			champ.text = contenu[rang]
		if modifiable:
			champ.text_changed.connect(_colorer.bind(champ))
			# À la sortie du champ : compléter si un seul mot peut convenir.
			champ.focus_exited.connect(_completer.bind(champ))
		ligne.add_child(champ)

		add_child(ligne)
		champs.append(champ)


func phrase() -> String:
	var lus := PackedStringArray()
	for champ in champs:
		lus.append(champ.text.strip_edges().to_lower())
	return " ".join(lus)


## Vert : mot valide. Rouge : aucun mot BIP39 ne commence ainsi — inutile
## d'attendre la validation pour le dire. Blanc : préfixe encore possible.
func _colorer(texte: String, champ: LineEdit) -> void:
	var propre := texte.strip_edges().to_lower()
	if propre.is_empty():
		_teinter(champ, BLANC)
	elif mots.valide(propre):
		_teinter(champ, VERT)
	elif mots.suggestions(propre, 1).is_empty():
		_teinter(champ, ROUGE)
	else:
		_teinter(champ, BLANC)


## Autocomplétion : la plupart des mots BIP39 sont uniques dès quatre lettres.
func _completer(champ: LineEdit) -> void:
	var propre := champ.text.strip_edges().to_lower()
	if not propre.is_empty() and not mots.valide(propre):
		var trouves := mots.suggestions(propre, 2)
		if trouves.size() == 1:
			champ.text = trouves[0]
	_colorer(champ.text, champ)


## La couleur du TEXTE, pas un `modulate` : celui-ci teinterait aussi le fond.
## `font_uneditable_color` couvre la grille en lecture seule.
func _teinter(champ: LineEdit, couleur: Color) -> void:
	champ.add_theme_color_override("font_color", couleur)
	champ.add_theme_color_override("font_uneditable_color", couleur)
