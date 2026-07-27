extends VBoxContainer

## Sous-menu REGLAGES. Se remplit tout seul a partir de Settings.DECLARATIONS :
## ajouter un reglage a la table suffit, il n'y a aucun widget a ecrire ici.
##
## `choix`      -> OptionButton
## `min`/`max`  -> HSlider + valeur
## TYPE_BOOL    -> CheckButton

const COLONNE_LARGEUR := 190
const VALEUR_LARGEUR := 56
const ESPACEMENT := 8
## Le curseur porte le Label qui affiche sa valeur, pour pouvoir le remettre
## a jour en meme temps que lui.
const META_VALEUR := "libelle_valeur"

var sous_section := ""
var colonne: VBoxContainer
var liste: VBoxContainer
var bouton_appliquer: Button
var bouton_annuler: Button
var boutons_sous_section := {}
## Le controle vivant de chaque reglage affiche, pour le resynchroniser sans
## reconstruire la sous-section.
var widgets := {}


func _ready() -> void:
	_construire()
	_ouvrir_sous_section(_sous_sections()[0])
	Settings.changed.connect(_sur_changement)


## Le lien qualite <-> cles pilotees va dans les deux sens : on resynchronise
## l'autre bout. On rafraichit les widgets, on ne les reconstruit pas.
func _sur_changement(cle: String) -> void:
	if cle == Settings.CLE_QUALITY:
		for pilotee: String in Settings.QUALITY_KEYS:
			_rafraichir_widget(pilotee)
		return
	if Settings.QUALITY_KEYS.has(cle):
		_rafraichir_widget(Settings.CLE_QUALITY)


## Remet le widget sur la valeur courante, sans reemettre de signal : sinon
## chaque resynchronisation en declencherait une autre.
func _rafraichir_widget(cle: String) -> void:
	if not widgets.has(cle):
		return  # le reglage n'est pas dans la sous-section affichee
	var widget: Control = widgets[cle]
	var valeur = Settings.get_value(cle)

	if widget is OptionButton:
		widget.selected = Settings.DECLARATIONS[cle]["choix"].find(valeur)
	elif widget is CheckButton:
		widget.set_pressed_no_signal(valeur)
	elif widget is HSlider:
		widget.set_value_no_signal(valeur)
		widget.get_meta(META_VALEUR).text = str(int(valeur))


func _construire() -> void:
	add_theme_constant_override("separation", ESPACEMENT)

	var corps := HBoxContainer.new()
	corps.add_theme_constant_override("separation", ESPACEMENT)
	corps.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(corps)

	_construire_colonne(corps)
	_construire_liste(corps)
	_construire_barre()


## La colonne de gauche : une entree par prefixe de cle.
func _construire_colonne(parent: Control) -> void:
	colonne = VBoxContainer.new()
	colonne.custom_minimum_size.x = COLONNE_LARGEUR
	parent.add_child(colonne)

	for nom in _sous_sections():
		var bouton := Button.new()
		bouton.text = nom.to_upper()
		bouton.pressed.connect(_ouvrir_sous_section.bind(nom))
		colonne.add_child(bouton)
		boutons_sous_section[nom] = bouton


## La zone de droite : les reglages de la sous-section courante.
func _construire_liste(parent: Control) -> void:
	var defilement := ScrollContainer.new()
	defilement.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	defilement.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	parent.add_child(defilement)

	liste = VBoxContainer.new()
	liste.add_theme_constant_override("separation", ESPACEMENT)
	liste.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	defilement.add_child(liste)


func _construire_barre() -> void:
	var barre := HBoxContainer.new()
	barre.alignment = BoxContainer.ALIGNMENT_END
	barre.add_theme_constant_override("separation", ESPACEMENT)
	add_child(barre)

	bouton_annuler = Button.new()
	bouton_annuler.text = "Annuler"
	bouton_annuler.pressed.connect(_annuler)
	barre.add_child(bouton_annuler)

	bouton_appliquer = Button.new()
	bouton_appliquer.text = "Appliquer"
	bouton_appliquer.pressed.connect(_appliquer)
	barre.add_child(bouton_appliquer)

	_rafraichir_barre()


## --- Navigation ---

## Les prefixes de cle, dans l'ordre de la table, sans doublon.
func _sous_sections() -> Array:
	var noms := []
	for cle: String in Settings.DECLARATIONS:
		var nom := cle.get_slice(".", 0)
		if not noms.has(nom):
			noms.append(nom)
	return noms


func _ouvrir_sous_section(nom: String) -> void:
	sous_section = nom

	widgets.clear()
	for enfant in liste.get_children():
		enfant.queue_free()

	for cle: String in Settings.DECLARATIONS:
		if cle.get_slice(".", 0) == nom:
			liste.add_child(_creer_ligne(cle))

	for autre in boutons_sous_section:
		var actif: bool = autre == nom
		boutons_sous_section[autre].modulate = (
			Color(1, 1, 1) if actif else Color(0.62, 0.62, 0.68)
		)


## --- Construction des lignes ---

func _creer_ligne(cle: String) -> Control:
	var ligne := HBoxContainer.new()
	ligne.add_theme_constant_override("separation", ESPACEMENT)

	var libelle := Label.new()
	libelle.text = cle.get_slice(".", 1).capitalize()
	libelle.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ligne.add_child(libelle)

	ligne.add_child(_creer_widget(cle))
	if Settings.DECLARATIONS[cle].get("verrouille", false):
		ligne.modulate = Color(0.62, 0.62, 0.68)
	return ligne


func _creer_widget(cle: String) -> Control:
	var declaration: Dictionary = Settings.DECLARATIONS[cle]

	var widget: Control
	if declaration["type"] == TYPE_BOOL:
		widget = _creer_bascule(cle)
	elif declaration.has("choix"):
		widget = _creer_choix(cle)
	else:
		widget = _creer_curseur(cle)

	if declaration.get("verrouille", false):
		_verrouiller(cle)
	return widget


## Le reglage se lit mais ne se touche pas. `widgets[cle]` porte le controle
## vivant, pas la boite qui l'entoure.
func _verrouiller(cle: String) -> void:
	var widget: Control = widgets[cle]
	if widget is HSlider:
		widget.editable = false
		return
	widget.disabled = true


func _creer_bascule(cle: String) -> Control:
	var bascule := CheckButton.new()
	bascule.button_pressed = Settings.get_value(cle)
	bascule.toggled.connect(func(actif: bool) -> void: _changer(cle, actif))
	widgets[cle] = bascule
	return bascule


func _creer_choix(cle: String) -> Control:
	var declaration: Dictionary = Settings.DECLARATIONS[cle]
	var choix: Array = declaration["choix"]
	var grisees: Array = declaration.get("grise", [])

	var deroulant := OptionButton.new()
	for index in choix.size():
		deroulant.add_item(str(choix[index]))
		# Affichable mais pas choisissable : état atteint automatiquement, ou
		# valeur que le serveur ne gère pas encore.
		deroulant.set_item_disabled(index, grisees.has(choix[index]))
	deroulant.selected = choix.find(Settings.get_value(cle))
	deroulant.item_selected.connect(
		func(index: int) -> void: _changer(cle, choix[index])
	)
	widgets[cle] = deroulant
	return deroulant


func _creer_curseur(cle: String) -> Control:
	var declaration: Dictionary = Settings.DECLARATIONS[cle]

	var boite := HBoxContainer.new()
	boite.custom_minimum_size.x = 260

	var curseur := HSlider.new()
	curseur.min_value = declaration["min"]
	curseur.max_value = declaration["max"]
	curseur.step = 1
	curseur.value = Settings.get_value(cle)
	curseur.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	curseur.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	boite.add_child(curseur)

	var valeur := Label.new()
	valeur.text = str(int(curseur.value))
	valeur.custom_minimum_size.x = VALEUR_LARGEUR
	valeur.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	boite.add_child(valeur)

	curseur.value_changed.connect(func(nouvelle: float) -> void:
		valeur.text = str(int(nouvelle))
		_changer(cle, int(nouvelle))
	)
	curseur.set_meta(META_VALEUR, valeur)
	widgets[cle] = curseur  # le curseur, pas la boite : c'est lui qui porte la valeur
	return boite


## --- Apply / Cancel ---

func _changer(cle: String, valeur) -> void:
	Settings.set_value(cle, valeur)
	_rafraichir_barre()


func _appliquer() -> void:
	Settings.apply()
	_rafraichir_barre()


func _annuler() -> void:
	Settings.cancel()
	_ouvrir_sous_section(sous_section)  # les widgets reprennent les valeurs enregistrees
	_rafraichir_barre()


func _rafraichir_barre() -> void:
	var modifie := Settings.is_dirty()
	bouton_appliquer.disabled = not modifie
	bouton_annuler.disabled = not modifie
