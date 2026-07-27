extends VBoxContainer

## Sous-menu COMPTE. Autonome : il ne connaît ni les autres sous-menus, ni
## l'assistant de création — celui-ci vit dans CONNEXION.
##
## Protégé par le menu : on ne l'atteint jamais déconnecté.
##
##   PROFIL --voir la phrase--> AVERTISSEMENT --> PHRASE
##          --supprimer-------> SUPPRESSION_1 --> SUPPRESSION_2 --> compte effacé

enum { PROFIL, AVERTISSEMENT, PHRASE, SUPPRESSION_1, SUPPRESSION_2 }

const Compte := preload("res://scripts/compte.gd")
const Mots := preload("res://scripts/mots.gd")
const GrilleMots := preload("res://scripts/grille_mots.gd")

const ESPACEMENT := 12
const LARGEUR_LIBELLE := 150
const LARGEUR_CHAMP := 320

## RECOPIE des bornes du serveur (profil.pseudo_min/max, profil.bio_max de
## config.csv). La règle vit LÀ-BAS : ici ce n'est qu'une optimisation, pour
## éviter un aller-retour réseau sur une évidence. Le serveur revalide tout, et
## c'est lui qui tranche — un client modifié ne contourne donc rien.
## Ne jamais imposer ici une limite que le serveur n'applique pas : elle
## bloquerait une saisie qu'il aurait acceptée.
const PSEUDO_MIN := 3
const PSEUDO_MAX := 20
const BIO_MAX := 200

const BLANC := Color(1, 1, 1)
const VERT := Color(0.55, 1.0, 0.55)
const ROUGE := Color(1.0, 0.5, 0.5)

## Injecté par menu.gd avant `add_child`.
var compte: Compte

var ecran := PROFIL
var statut_texte := ""
var statut_bon := false

var corps: VBoxContainer
var statut: Label
var boutons: HBoxContainer
## Champs du formulaire, relus à l'enregistrement.
var champ_pseudo: LineEdit
var champ_bio: LineEdit
var champ_email: LineEdit
var case_statut: CheckBox
var case_serveur: CheckBox
## Saisie de confirmation de suppression.
var champ_confirmation: LineEdit


func _ready() -> void:
	add_theme_constant_override("separation", ESPACEMENT)

	var defilement := ScrollContainer.new()
	defilement.size_flags_vertical = Control.SIZE_EXPAND_FILL
	defilement.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(defilement)

	corps = VBoxContainer.new()
	corps.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	corps.add_theme_constant_override("separation", ESPACEMENT)
	defilement.add_child(corps)

	statut = Label.new()
	statut.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(statut)

	boutons = HBoxContainer.new()
	boutons.alignment = BoxContainer.ALIGNMENT_CENTER
	boutons.add_theme_constant_override("separation", ESPACEMENT)
	add_child(boutons)

	compte.change.connect(_afficher)
	_afficher()


## Le menu rouvre toujours sur le profil : on ne veut pas retomber sur la phrase
## secrète affichée, ni sur un écran de suppression à moitié parcouru.
func reinitialiser() -> void:
	ecran = PROFIL
	statut_texte = ""
	_afficher()


## Échap recule d'un écran au lieu de fermer le sous-menu.
func retour() -> bool:
	if ecran == PROFIL:
		return false
	_vers(PROFIL)
	return true


## --- Écrans ---

func _afficher() -> void:
	for ancien in corps.get_children():
		ancien.queue_free()
		corps.remove_child(ancien)
	for ancien in boutons.get_children():
		ancien.queue_free()
		boutons.remove_child(ancien)

	if not compte.connecte:
		# Transitoire : le menu nous fait sortir dans la foulée.
		statut.text = ""
		return

	match ecran:
		PROFIL: _ecran_profil()
		AVERTISSEMENT: _ecran_avertissement()
		PHRASE: _ecran_phrase()
		SUPPRESSION_1: _ecran_suppression_1()
		SUPPRESSION_2: _ecran_suppression_2()

	statut.add_theme_color_override("font_color", VERT if statut_bon else ROUGE)
	statut.text = statut_texte


func _ecran_profil() -> void:
	_titre("Profil")
	_ligne_lecture("Identifiant", compte.userid)
	_ligne_lecture("Créé le", _date(compte.date_creation))
	champ_pseudo = _ligne_saisie("Pseudo", compte.pseudo, PSEUDO_MAX)
	champ_bio = _ligne_saisie("Bio", compte.bio, BIO_MAX)
	# 0 = sans limite : le serveur n'en impose aucune sur l'email, en inventer
	# une ici refuserait une adresse qu'il aurait acceptée.
	champ_email = _ligne_saisie("Email", compte.email, 0)

	_titre("Confidentialité")
	case_statut = _case(
		"Montrer à mes amis que je suis en ligne", compte.partage_statut
	)
	case_serveur = _case(
		"Montrer à mes amis le serveur où je joue", compte.partage_serveur
	)

	_bouton("Enregistrer", _enregistrer)
	_bouton("Voir ma phrase secrète", _vers.bind(AVERTISSEMENT))
	_bouton("Se déconnecter", _deconnecter)
	_bouton("Supprimer le compte", _vers.bind(SUPPRESSION_1), ROUGE)


func _ecran_avertissement() -> void:
	_titre("Ta phrase secrète")
	_paragraphe(
		"Ces 24 mots SONT ton compte.\n"
		+ "\n"
		+ "Qui les possède peut se connecter à ta place, depuis n'importe où.\n"
		+ "Ne les montre à personne, jamais — ni support, ni ami, ni Unirique.\n"
		+ "\n"
		+ "Assure-toi que personne ne regarde ton écran."
	)
	_bouton("Retour", _vers.bind(PROFIL))
	_bouton("Afficher quand même", _vers.bind(PHRASE), ROUGE)


func _ecran_phrase() -> void:
	_titre("Tes 24 mots")
	# Le composant partagé : même disposition et même « n: mot » qu'à la création,
	# pour qu'on reconnaisse sa phrase au lieu de la relire.
	var grille := GrilleMots.new()
	grille.construire(Mots.new(), compte.phrase.split(" "), false)

	var centre := CenterContainer.new()
	centre.add_child(grille)
	corps.add_child(centre)

	# Une grille se lit mais se recopie mal : le presse-papiers évite de la
	# retaper à la main dans un gestionnaire de mots de passe.
	_bouton("Copier", _copier)
	_bouton("Masquer", _vers.bind(PROFIL))


func _copier() -> void:
	DisplayServer.clipboard_set(compte.phrase)
	_dire("Phrase copiée dans le presse-papiers.", true)


func _ecran_suppression_1() -> void:
	_titre("Supprimer le compte")
	_paragraphe(
		"Seront effacés du serveur : ton identifiant %s, ton pseudo, tes amis "
		% compte.userid
		+ "et tes blocages. C'est définitif.\n"
		+ "\n"
		+ "Ta phrase, elle, reste valide : tu pourrais te réinscrire — mais avec "
		+ "un nouvel identifiant, et sans tes amis."
	)
	_bouton("Annuler", _vers.bind(PROFIL))
	_bouton("Continuer", _vers.bind(SUPPRESSION_2), ROUGE)


## Deuxième vérification : recopier son pseudo. Un second bouton ne prouverait
## que la vitesse du clic ; recopier demande de lire.
func _ecran_suppression_2() -> void:
	_titre("Dernière confirmation")
	_paragraphe("Recopie ton pseudo « %s » pour confirmer." % compte.pseudo)
	champ_confirmation = _ligne_saisie("Pseudo", "", PSEUDO_MAX)
	_bouton("Annuler", _vers.bind(PROFIL))
	_bouton("Supprimer définitivement", _supprimer, ROUGE)


## --- Actions ---

## N'envoie que ce qui a changé : le serveur valide chaque champ fourni, inutile
## de lui faire revérifier ce qu'on n'a pas touché.
func _enregistrer() -> void:
	var champs := {}
	if champ_pseudo.text.strip_edges() != compte.pseudo:
		champs["pseudo"] = champ_pseudo.text.strip_edges()
	if champ_bio.text != compte.bio:
		champs["bio"] = champ_bio.text
	if champ_email.text.strip_edges() != compte.email:
		champs["email"] = champ_email.text.strip_edges()
	if case_statut.button_pressed != compte.partage_statut:
		champs["partage_statut"] = case_statut.button_pressed
	if case_serveur.button_pressed != compte.partage_serveur:
		champs["partage_serveur"] = case_serveur.button_pressed

	if champs.is_empty():
		_dire("Rien à enregistrer.", true)
		return

	var pseudo: String = champs.get("pseudo", compte.pseudo)
	if pseudo.length() < PSEUDO_MIN or pseudo.length() > PSEUDO_MAX:
		_dire("Le pseudo doit faire de %d à %d caractères." % [
			PSEUDO_MIN, PSEUDO_MAX
		], false)
		return

	var erreur: String = await compte.mettre_a_jour(champs)
	_dire("Enregistré." if erreur.is_empty() else erreur, erreur.is_empty())


func _deconnecter() -> void:
	await compte.deconnecter()


func _supprimer() -> void:
	if champ_confirmation.text.strip_edges() != compte.pseudo:
		_dire("Le pseudo ne correspond pas.", false)
		return
	var erreur: String = await compte.supprimer_compte()
	if not erreur.is_empty():
		_dire(erreur, false)


## --- Éléments ---

func _titre(contenu: String) -> void:
	var etiquette := Label.new()
	etiquette.text = contenu
	etiquette.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	etiquette.add_theme_color_override("font_color", BLANC)
	corps.add_child(etiquette)


func _paragraphe(contenu: String) -> void:
	var etiquette := Label.new()
	etiquette.text = contenu
	etiquette.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	etiquette.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	etiquette.add_theme_color_override("font_color", BLANC)
	corps.add_child(etiquette)


func _ligne(libelle: String) -> HBoxContainer:
	var ligne := HBoxContainer.new()
	ligne.alignment = BoxContainer.ALIGNMENT_CENTER
	ligne.add_theme_constant_override("separation", ESPACEMENT)
	corps.add_child(ligne)

	var nom := Label.new()
	nom.text = libelle
	nom.custom_minimum_size.x = LARGEUR_LIBELLE
	nom.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	nom.add_theme_color_override("font_color", BLANC)
	ligne.add_child(nom)
	return ligne


func _ligne_lecture(libelle: String, valeur: String) -> void:
	var etiquette := Label.new()
	etiquette.text = valeur
	etiquette.custom_minimum_size.x = LARGEUR_CHAMP
	etiquette.add_theme_color_override("font_color", BLANC)
	_ligne(libelle).add_child(etiquette)


func _ligne_saisie(libelle: String, valeur: String, maximum: int) -> LineEdit:
	var champ := LineEdit.new()
	champ.text = valeur
	champ.max_length = maximum
	champ.custom_minimum_size.x = LARGEUR_CHAMP
	champ.add_theme_color_override("font_color", BLANC)
	_ligne(libelle).add_child(champ)
	return champ


func _case(libelle: String, actif: bool) -> CheckBox:
	var case := CheckBox.new()
	case.text = libelle
	case.button_pressed = actif
	case.add_theme_color_override("font_color", BLANC)

	var ligne := HBoxContainer.new()
	ligne.alignment = BoxContainer.ALIGNMENT_CENTER
	ligne.add_child(case)
	corps.add_child(ligne)
	return case


func _bouton(texte: String, action: Callable, couleur := BLANC) -> void:
	var noeud := Button.new()
	noeud.text = texte
	noeud.pressed.connect(action)
	for etat in ["font_color", "font_hover_color", "font_pressed_color"]:
		noeud.add_theme_color_override(etat, couleur)
	boutons.add_child(noeud)


func _vers(suivant: int) -> void:
	ecran = suivant
	statut_texte = ""
	_afficher()


func _dire(contenu: String, bon: bool) -> void:
	statut_texte = contenu
	statut_bon = bon
	statut.add_theme_color_override("font_color", VERT if bon else ROUGE)
	statut.text = contenu


func _date(horodatage: int) -> String:
	if horodatage <= 0:
		return "—"
	return Time.get_datetime_string_from_unix_time(horodatage, true)
