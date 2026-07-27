extends VBoxContainer

## Sous-menu CONNEXION — le 7e. Autonome : pas de rectangle dans le menu
## principal, aucune connaissance des autres sous-menus. Seule son ouverture
## vient de l'extérieur, quand un sous-menu protégé exige un compte.
##
## Il porte tout l'assistant : création d'un compte et connexion à un existant.
## Norme de l'identité : Norms/identity.md
##
##   ACCUEIL --creer--> EXPLICATION -> PHRASE -> VERIFICATION --> compte créé
##           --entrer--> SAISIE ----------------------------------> connecté

enum { ACCUEIL, EXPLICATION, PHRASE, VERIFICATION, SAISIE }

const Compte := preload("res://scripts/compte.gd")
const Mots := preload("res://scripts/mots.gd")
const GrilleMots := preload("res://scripts/grille_mots.gd")

const ESPACEMENT := 16
const TAILLE_MESSAGE := 20
## Boutons de choix : empilés et de largeur égale, comme un vrai menu.
const LARGEUR_CHOIX := 260

const ROUGE := Color(1.0, 0.5, 0.5)

## Injecté par menu.gd avant `add_child`.
var compte: Compte
var mots: Mots

var ecran := ACCUEIL
## La phrase montrée à l'écran PHRASE, comparée à la ressaisie.
var phrase_generee := ""
var grille: GrilleMots
## Survit à `_afficher`, qui reconstruit tout le reste.
var statut_texte := ""
var occupe := false

var message: Label
var corps: CenterContainer
var statut: Label
var boutons: HBoxContainer


func _ready() -> void:
	mots = Mots.new()
	add_theme_constant_override("separation", ESPACEMENT)

	message = Label.new()
	message.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	message.add_theme_font_size_override("font_size", TAILLE_MESSAGE)
	add_child(message)

	corps = CenterContainer.new()
	corps.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(corps)

	statut = Label.new()
	statut.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	statut.modulate = ROUGE
	add_child(statut)

	boutons = HBoxContainer.new()
	boutons.alignment = BoxContainer.ALIGNMENT_CENTER
	boutons.add_theme_constant_override("separation", ESPACEMENT)
	add_child(boutons)

	compte.change.connect(_afficher)
	_afficher()


## Appelé par le menu à chaque ouverture : on repart de l'accueil, et la phrase
## d'une création abandonnée ne traîne pas en mémoire.
func reinitialiser() -> void:
	ecran = ACCUEIL
	phrase_generee = ""
	statut_texte = ""
	_afficher()


## Échap : reculer d'un écran plutôt que fermer le sous-menu. Vrai si consommé.
func retour() -> bool:
	if occupe or ecran == ACCUEIL:
		return false
	_vers(ACCUEIL if ecran in [EXPLICATION, SAISIE] else _precedent())
	return true


func _precedent() -> int:
	return EXPLICATION if ecran == PHRASE else PHRASE


## --- Écrans ---

func _afficher() -> void:
	for ancien in corps.get_children():
		ancien.queue_free()
	for ancien in boutons.get_children():
		ancien.queue_free()
	grille = null

	if compte.connecte:
		message.text = "Connecté."
	else:
		match ecran:
			ACCUEIL: _ecran_accueil()
			EXPLICATION: _ecran_explication()
			PHRASE: _ecran_phrase()
			VERIFICATION: _ecran_grille("Ressaisis les 24 mots pour confirmer.",
				"Revoir la phrase", PHRASE, "Créer le compte", _creer)
			SAISIE: _ecran_grille("Saisis les 24 mots de ton compte.",
				"Retour", ACCUEIL, "Se connecter", _connecter)

	statut.text = statut_texte


## Les deux choix sont l'écran lui-même, pas une barre de navigation : ils vont
## au centre, empilés.
func _ecran_accueil() -> void:
	message.text = "Cette section demande un compte."
	var colonne := VBoxContainer.new()
	colonne.add_theme_constant_override("separation", ESPACEMENT)
	colonne.custom_minimum_size.x = LARGEUR_CHOIX
	corps.add_child(colonne)
	_bouton_dans(colonne, "Créer un compte", _vers.bind(EXPLICATION))
	_bouton_dans(colonne, "Se connecter", _vers.bind(SAISIE))


func _ecran_explication() -> void:
	# Retours à la ligne explicites : le panneau est large, le texte s'étalerait
	# sur toute sa largeur et deviendrait pénible à lire.
	message.text = (
		"Ton compte est une phrase de 24 mots.\n"
		+ "\n"
		+ "Elle seule permet de s'y reconnecter.\n"
		+ "Personne ne peut la régénérer, pas même Unirique.\n"
		+ "\n"
		+ "La perdre, c'est perdre le compte.\n"
		+ "Note-la sur papier et garde-la en lieu sûr."
	)
	_bouton("Retour", _vers.bind(ACCUEIL))
	_bouton("Générer ma phrase", _generer)


func _ecran_phrase() -> void:
	message.text = "Note ces 24 mots, dans l'ordre."
	_construire_grille(phrase_generee.split(" "), false)
	_bouton("Retour", _vers.bind(EXPLICATION))
	_bouton("Je les ai notés", _vers.bind(VERIFICATION))


## VERIFICATION et SAISIE partagent la même grille : ressaisir sa phrase et
## saisir celle d'un compte existant, c'est le même geste.
func _ecran_grille(
	texte: String, retour_texte: String, retour_ecran: int,
	valider_texte: String, valider: Callable
) -> void:
	message.text = texte
	_construire_grille(PackedStringArray(), true)
	_bouton(retour_texte, _vers.bind(retour_ecran))
	_bouton(valider_texte, valider)


## --- Grille de 24 mots (composant partagé) ---

func _construire_grille(contenu: PackedStringArray, modifiable: bool) -> void:
	grille = GrilleMots.new()
	grille.construire(mots, contenu, modifiable)
	corps.add_child(grille)


## --- Actions ---

func _generer() -> void:
	phrase_generee = mots.generer_phrase()
	_vers(PHRASE)


func _creer() -> void:
	if grille.phrase() != phrase_generee:
		statut_texte = "La phrase ne correspond pas."
		statut.text = statut_texte
		return
	_debut("Création du compte…")
	var erreur: String = await compte.creer_compte(phrase_generee)
	_fin(erreur)


func _connecter() -> void:
	_debut("Connexion…")
	var erreur: String = await compte.connecter(grille.phrase())
	_fin(erreur)


## Pendant l'appel réseau : boutons figés, pour ne pas lancer deux inscriptions.
func _debut(attente: String) -> void:
	occupe = true
	statut_texte = attente
	statut.modulate = Color.WHITE
	statut.text = attente
	for bouton in boutons.get_children():
		bouton.disabled = true


## Le succès n'affiche rien : il déclenche `compte.change`, qui rafraîchit cet
## écran et fait sortir le menu vers le sous-menu initialement demandé.
func _fin(erreur: String) -> void:
	occupe = false
	statut.modulate = ROUGE
	statut_texte = erreur
	if not erreur.is_empty():
		_afficher()


## Barre de navigation, en bas.
func _bouton(texte: String, action: Callable) -> void:
	_bouton_dans(boutons, texte, action)


func _bouton_dans(parent: Control, texte: String, action: Callable) -> void:
	var noeud := Button.new()
	noeud.text = texte
	noeud.pressed.connect(action)
	parent.add_child(noeud)


func _vers(suivant: int) -> void:
	ecran = suivant
	statut_texte = ""
	_afficher()
