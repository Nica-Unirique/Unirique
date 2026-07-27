extends VBoxContainer

## Sous-menu AMIS. Autonome : il ne connaît ni les autres sous-menus, ni les
## routes HTTP — celles-ci vivent dans `amis.gd`.
##
## Quatre onglets : les amis, les demandes en attente, la recherche, les blocages.
## Protégé par le menu : on ne l'atteint jamais sans compte.

enum { LISTE, DEMANDES, AJOUTER, BLOQUES }

const Compte := preload("res://scripts/compte.gd")
const Amis := preload("res://scripts/amis.gd")

const ONGLETS := ["Mes amis", "Demandes", "Ajouter", "Bloqués"]
const ESPACEMENT := 12
const LARGEUR_PSEUDO := 220
## Les statuts changent lentement (ping de 120 s côté présence) ; ce qui bouge
## vite, ce sont les demandes reçues.
const RAFRAICHIR_SECONDES := 30.0

const BLANC := Color(1, 1, 1)
const VERT := Color(0.55, 1.0, 0.55)
const ROUGE := Color(1.0, 0.5, 0.5)
## Les états d'un bouton dont il faut teindre le texte : sans eux, le survol
## rétablirait la couleur du thème.
const ETATS_TEXTE := [
	"font_color", "font_hover_color", "font_pressed_color", "font_focus_color",
]

## Relayé jusqu'au client par le menu : rejoindre un monde n'est pas l'affaire
## d'une liste d'amis.
signal rejoindre_serveur(adresses: Array)

## Injecté par menu.gd avant `add_child`.
var compte: Compte

var amis: Amis
var onglet := LISTE
var statut_texte := ""

var barre: HBoxContainer
var boutons_onglets: Array[Button] = []
var defilement: ScrollContainer
var liste: VBoxContainer
## Zone superposée à la liste, pour les messages centrés : un ScrollContainer
## ne peut pas centrer verticalement, il dimensionne son contenu au minimum.
var centre: CenterContainer
var statut: Label
var minuteur: Timer


func _ready() -> void:
	amis = Amis.new(compte.data, compte)
	add_theme_constant_override("separation", ESPACEMENT)

	_construire_onglets()

	# Les deux occupent la même zone ; on montre l'une ou l'autre.
	var zone := MarginContainer.new()
	zone.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(zone)

	defilement = ScrollContainer.new()
	defilement.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	zone.add_child(defilement)

	liste = VBoxContainer.new()
	liste.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	liste.add_theme_constant_override("separation", 6)
	defilement.add_child(liste)

	centre = CenterContainer.new()
	centre.visible = false
	zone.add_child(centre)

	statut = Label.new()
	statut.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	statut.add_theme_color_override("font_color", ROUGE)
	add_child(statut)

	minuteur = Timer.new()
	minuteur.wait_time = RAFRAICHIR_SECONDES
	minuteur.timeout.connect(_rafraichir)
	add_child(minuteur)

	visibility_changed.connect(_sur_visibilite)


func _construire_onglets() -> void:
	barre = HBoxContainer.new()
	barre.alignment = BoxContainer.ALIGNMENT_CENTER
	barre.add_theme_constant_override("separation", ESPACEMENT)
	add_child(barre)

	for index in ONGLETS.size():
		var bouton := Button.new()
		bouton.text = ONGLETS[index]
		bouton.pressed.connect(_vers.bind(index))
		barre.add_child(bouton)
		boutons_onglets.append(bouton)


## Le rafraîchissement ne tourne que sous les yeux de l'utilisateur : inutile
## d'interroger le serveur pendant qu'il joue.
func _sur_visibilite() -> void:
	if visible:
		minuteur.start()
		_rafraichir()
	else:
		minuteur.stop()


func reinitialiser() -> void:
	_vers(LISTE)


func _vers(index: int) -> void:
	onglet = index
	statut_texte = ""
	for rang in boutons_onglets.size():
		_teinter(boutons_onglets[rang], VERT if rang == index else BLANC)
	_rafraichir()


## Teinte le TEXTE d'un bouton, pas le bouton : un `modulate` colorerait aussi
## son fond.
func _teinter(bouton: Button, couleur: Color) -> void:
	for etat in ETATS_TEXTE:
		bouton.add_theme_color_override(etat, couleur)


## --- Remplissage ---

## Les données sont lues D'ABORD, affichées ensuite — et seulement si l'onglet
## n'a pas changé entre-temps. Sans ce contrôle, une requête lente terminant
## après un changement d'onglet y écraserait le contenu du nouvel onglet.
func _rafraichir() -> void:
	if not compte.connecte:
		return
	var demande := onglet

	match demande:
		LISTE:
			var trouves := await amis.liste()
			if demande != onglet:
				return
			_afficher_amis(trouves)
		DEMANDES:
			var recues := await amis.recues()
			var envoyees := await amis.envoyees()
			if demande != onglet:
				return
			_afficher_demandes(recues, envoyees)
		BLOQUES:
			var trouves := await amis.bloques()
			if demande != onglet:
				return
			_afficher_bloques(trouves)
		AJOUTER:
			_remplir_ajouter()  # aucune lecture tant qu'on n'a rien cherché

	statut.text = statut_texte


func _vider() -> void:
	for ancien in liste.get_children():
		ancien.queue_free()
		liste.remove_child(ancien)
	for ancien in centre.get_children():
		ancien.queue_free()
		centre.remove_child(ancien)
	defilement.visible = true
	centre.visible = false


func _afficher_amis(trouves: Array) -> void:
	_vider()
	if trouves.is_empty():
		_message_vide("Aucun ami pour l'instant.")
		return
	for item in trouves:
		_ligne_ami(item)


func _afficher_demandes(recues: Array, envoyees: Array) -> void:
	_vider()
	if recues.is_empty() and envoyees.is_empty():
		_message_vide("Aucune demande en attente.")
		return

	if not recues.is_empty():
		_titre("Reçues")
		for item in recues:
			_ligne_action(item, [
				["Accepter", amis.accepter], ["Refuser", amis.refuser],
			])
	if not envoyees.is_empty():
		_titre("Envoyées")
		for item in envoyees:
			_ligne_action(item, [["Annuler", amis.annuler]])


func _afficher_bloques(trouves: Array) -> void:
	_vider()
	if trouves.is_empty():
		_message_vide("Personne de bloqué.")
		return
	for item in trouves:
		_ligne_action(item, [["Débloquer", amis.debloquer]])


## Rien n'est cherché tant qu'on ne l'a pas demandé : le formulaire occupe donc
## la zone entière, centré.
func _remplir_ajouter() -> void:
	_vider()
	defilement.visible = false
	centre.visible = true
	centre.add_child(_formulaire(""))


## Le champ de recherche et le pseudo, groupés. Reconstruits à chaque affichage,
## d'où `motif` : sans lui, la saisie disparaîtrait en même temps qu'elle sert.
func _formulaire(motif: String) -> VBoxContainer:
	var colonne := VBoxContainer.new()
	colonne.add_theme_constant_override("separation", ESPACEMENT)

	var mien := _etiquette("Ton pseudo est : %s" % compte.pseudo)
	mien.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	colonne.add_child(mien)

	var ligne := HBoxContainer.new()
	ligne.alignment = BoxContainer.ALIGNMENT_CENTER
	ligne.add_theme_constant_override("separation", ESPACEMENT)
	colonne.add_child(ligne)

	var champ := LineEdit.new()
	champ.placeholder_text = "Pseudo à rechercher"
	champ.text = motif
	champ.custom_minimum_size.x = LARGEUR_PSEUDO
	champ.add_theme_color_override("font_color", BLANC)
	ligne.add_child(champ)

	var bouton := Button.new()
	bouton.text = "Rechercher"
	bouton.pressed.connect(func(): _chercher(champ.text))
	ligne.add_child(bouton)
	champ.text_submitted.connect(func(t: String): _chercher(t))
	return colonne


## Avec des résultats, le formulaire remonte en tête d'une liste défilante : ils
## peuvent être nombreux, la zone centrée ne saurait pas les faire défiler.
func _chercher(motif: String) -> void:
	if motif.strip_edges().is_empty():
		return
	var trouves := await amis.rechercher(motif)
	_vider()
	liste.add_child(_formulaire(motif))

	if trouves.is_empty():
		var vide := _etiquette("Aucun compte à ce nom.")
		vide.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		liste.add_child(vide)
		return
	for item in trouves:
		if item.get("userid", "") == compte.userid:
			continue  # inutile de se proposer soi-même
		_ligne_action(item, [["Demander en ami", amis.demander]])


## --- Lignes ---

func _ligne_ami(item: Dictionary) -> void:
	var ligne := _ligne(item.get("pseudo", ""))

	# `en_ligne` absent = l'ami ne partage pas son statut. C'est différent de
	# « hors ligne », et le lui faire dire serait une indiscrétion.
	var etat := Label.new()
	var couleur := BLANC
	if not item.has("en_ligne"):
		etat.text = "—"
	elif item["en_ligne"]:
		etat.text = "en ligne"
		couleur = VERT  # seul état actif : le vert le distingue d'un coup d'œil
	else:
		etat.text = "hors ligne"
	etat.add_theme_color_override("font_color", couleur)
	etat.custom_minimum_size.x = 110
	ligne.add_child(etat)

	var lieu := Label.new()
	lieu.text = item.get("serveur", "")
	lieu.custom_minimum_size.x = 160
	lieu.add_theme_color_override("font_color", BLANC)
	ligne.add_child(lieu)

	# Le serveur n'apparaît que si l'ami le partage ET que sa politique nous
	# autorise : son absence signifie « pas de serveur, ou pas pour toi ».
	var serveur: String = item.get("serveur", "")
	var rejoindre := Button.new()
	rejoindre.text = "Rejoindre"
	rejoindre.disabled = serveur.is_empty()
	if serveur.is_empty():
		rejoindre.tooltip_text = "Aucun serveur joignable"
	else:
		rejoindre.pressed.connect(func(): _rejoindre(serveur))
	ligne.add_child(rejoindre)

	_action_sur(ligne, item, "Retirer", amis.retirer)
	_action_sur(ligne, item, "Bloquer", amis.bloquer)


func _ligne_action(item: Dictionary, actions: Array) -> void:
	var ligne := _ligne(item.get("pseudo", ""))
	for action in actions:
		_action_sur(ligne, item, action[0], action[1])


func _ligne(pseudo: String) -> HBoxContainer:
	var ligne := HBoxContainer.new()
	# Centré : le panneau est bien plus large qu'une ligne, tout coller à gauche
	# laisserait un grand vide à droite.
	ligne.alignment = BoxContainer.ALIGNMENT_CENTER
	ligne.add_theme_constant_override("separation", ESPACEMENT)
	liste.add_child(ligne)

	var nom := Label.new()
	nom.text = pseudo
	nom.custom_minimum_size.x = LARGEUR_PSEUDO
	nom.add_theme_color_override("font_color", BLANC)
	ligne.add_child(nom)
	return ligne


func _action_sur(
	ligne: HBoxContainer, item: Dictionary, texte: String, appel: Callable
) -> void:
	var bouton := Button.new()
	bouton.text = texte
	bouton.pressed.connect(func(): _executer(appel, item.get("userid", "")))
	ligne.add_child(bouton)


## L'identifiant vu chez l'ami ne sert à rien seul : c'est l'annuaire qui donne
## l'adresse, et seulement s'il nous juge autorisé. Un refus se traduit ici par
## une adresse vide — l'ami a pu quitter, ou fermer son serveur entre-temps.
func _rejoindre(serveur_id: String) -> void:
	var adresses := await amis.adresses_du_serveur(serveur_id)
	if adresses.is_empty():
		statut_texte = "Ce serveur n'est plus joignable."
		statut.text = statut_texte
		return
	# Le client les essaiera dans l'ordre : IPv6 d'abord, repli ensuite.
	rejoindre_serveur.emit(adresses)


## Toute action se termine par un rafraîchissement : c'est le serveur qui dit
## l'état réel, pas notre supposition sur ce que l'action a produit.
func _executer(appel: Callable, userid: String) -> void:
	if userid.is_empty():
		return
	var erreur: String = await appel.call(userid)
	statut_texte = erreur
	_rafraichir()


## --- Petits éléments ---

## Une ligne de texte dans la liste.
func _texte(contenu: String) -> void:
	liste.add_child(_etiquette(contenu))


## Intertitre d'une section de la liste ; centré comme les lignes.
func _titre(contenu: String) -> void:
	var etiquette := _etiquette(contenu)
	etiquette.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	liste.add_child(etiquette)


## Onglet sans contenu : le message occupe la zone entière, centré.
func _message_vide(contenu: String) -> void:
	defilement.visible = false
	centre.visible = true
	var etiquette := _etiquette(contenu)
	etiquette.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	centre.add_child(etiquette)


func _etiquette(contenu: String) -> Label:
	var noeud := Label.new()
	noeud.text = contenu
	noeud.add_theme_color_override("font_color", BLANC)
	return noeud
