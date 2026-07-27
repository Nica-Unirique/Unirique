extends Node

## Session du compte. Norme : Norms/identity.md
##
## L'identité est décentralisée : la phrase de 24 mots EST le compte. Le serveur
## n'en détient rien qui permette de se faire passer pour nous — il ne connaît
## que la clé publique. Perdre la phrase, c'est perdre le compte.

const Identity := preload("res://scripts/identity.gd")
const Data := preload("res://scripts/data.gd")

## En clair pour la bêta. Dette assumée : à chiffrer avant toute ouverture.
const FICHIER := "user://compte.json"

## Doit rester cohérent avec `presence.ping_intervalle_secondes` de config.csv,
## côté serveur, où le seuil `en_ligne_seuil_secondes` vaut douze fois ça.
##
## Ce couplage a déjà mordu : la valeur a été portée à 120 ici pendant que le
## seuil serveur restait à 60, et les joueurs clignotaient entre en ligne et
## hors ligne. Changer l'une sans l'autre casse la présence en silence.
const PING_SECONDES := 5.0

signal change

## Injecté par client.gd avant `add_child`.
var data: Data

var identity: Identity
var phrase := ""
var userid := ""
var pseudo := ""
var bio := ""
var email := ""
## Ce que les amis ont le droit de voir. Sans ces réglages, la liste d'amis ne
## pourrait jamais afficher « ne partage pas ».
var partage_statut := true
var partage_serveur := true
## Horodatage Unix.
var date_creation := 0
var token := ""
var connecte := false

## Identifiant du serveur de jeu où l'on est, "" si aucun. Posé par `annonce`.
## C'est la SEULE information de lieu qu'on transmette : l'annuaire, qui connaît
## la politique du serveur, décide ensuite qui a le droit de la voir. Envoyer
## davantage divulguerait ce que le serveur voulait taire.
var serveur_courant := ""

var minuteur: Timer


func _ready() -> void:
	identity = Identity.new()
	minuteur = Timer.new()
	minuteur.wait_time = PING_SECONDES
	minuteur.timeout.connect(_pinguer)
	add_child(minuteur)
	_charger()


## --- État ---

func a_un_compte() -> bool:
	return not phrase.is_empty()


func cle_publique() -> String:
	return identity.public_key(phrase)


## --- Création et connexion ---

## Déclare une NOUVELLE identité puis ouvre la session. Le serveur attribue
## userid et pseudo — on ne les choisit pas à l'inscription.
func creer_compte(nouvelle_phrase: String) -> String:
	var publique := identity.public_key(nouvelle_phrase)
	if publique.is_empty():
		return "phrase invalide"

	var reponse: Dictionary = await data.post_json("/auth/register", {"cle_publique": publique})
	if not reponse["ok"]:
		return _message(reponse, "inscription refusée")
	return await connecter(nouvelle_phrase)


## Ouvre la session d'un compte EXISTANT : défi, signature, jeton.
func connecter(sa_phrase: String) -> String:
	var publique := identity.public_key(sa_phrase)
	if publique.is_empty():
		return "phrase invalide"

	var defi: Dictionary = await data.post_json("/auth/challenge", {"cle_publique": publique})
	if not defi["ok"]:
		return _message(defi, "défi refusé")

	# Le serveur vérifie sur les octets DÉCODÉS du défi, pas sur son texte
	# hexadécimal. Signer la chaîne donnerait une signature toujours rejetée.
	var message := _depuis_hex(defi["json"].get("defi", ""))
	if message.is_empty():
		return "défi illisible"

	var signature := identity.sign(sa_phrase, message)
	if signature.is_empty():
		return "signature impossible"

	var session: Dictionary = await data.post_json("/auth/login", {
		"cle_publique": publique, "signature": signature,
	})
	if not session["ok"]:
		return _message(session, "connexion refusée")

	phrase = sa_phrase
	token = session["json"].get("token", "")
	userid = session["json"].get("userid", "")
	connecte = true
	_sauver()
	# `/auth/login` ne renvoie pas le pseudo : c'est le serveur qui l'attribue,
	# on va le chercher là où il est publié.
	await _lire_profil()
	_regler_presence()
	change.emit()
	return ""


## Revalide le jeton mémorisé. Un jeton peut avoir été révoqué ailleurs :
## le croire sur parole afficherait un compte connecté qui ne l'est plus.
func valider_session() -> void:
	if token.is_empty():
		return
	connecte = await _lire_profil()
	if not connecte:
		token = ""
	_regler_presence()
	change.emit()


## `/me` : le profil complet, dont le pseudo attribué par le serveur. Sert aussi
## de test du jeton — s'il est révoqué, la route refuse.
func _lire_profil() -> bool:
	var moi: Dictionary = await data.get_json("/me", token)
	if not moi["ok"]:
		return false
	var profil: Dictionary = moi["json"]
	userid = profil.get("userid", userid)
	pseudo = profil.get("pseudo", pseudo)
	bio = profil.get("bio", "")
	# `email` est nul côté serveur quand il n'est pas renseigné.
	var courriel = profil.get("email")
	email = courriel if courriel is String else ""
	partage_statut = profil.get("partage_statut", true)
	partage_serveur = profil.get("partage_serveur", true)
	date_creation = profil.get("date_creation", 0)
	return true


## --- Profil ---

## Met à jour les champs FOURNIS uniquement : le serveur ignore les absents.
## Renvoie "" en cas de succès, sinon son message (pseudo pris, trop long…).
func mettre_a_jour(champs: Dictionary) -> String:
	var reponse: Dictionary = await data.post_json("/me/update", champs, token)
	if not reponse["ok"]:
		return _message(reponse, "modification refusée")
	await _lire_profil()
	change.emit()
	return ""


## Efface le compte du SERVEUR. L'identité, elle, survit : la phrase permettrait
## de se réinscrire — mais avec un nouvel identifiant, sans les amis.
func supprimer_compte() -> String:
	# Le serveur exige la signature de « delete:<userid> » : personne ne peut
	# supprimer un compte à la place de son porteur, pas même avec le jeton.
	var preuve := identity.sign(phrase, ("delete:" + userid).to_utf8_buffer())
	if preuve.is_empty():
		return "signature impossible"

	var reponse: Dictionary = await data.post_json(
		"/me/delete", {"signature": preuve}, token
	)
	if not reponse["ok"]:
		return _message(reponse, "suppression refusée")

	phrase = ""
	oublier()
	return ""


## Efface la session locale sans rien demander au serveur.
func oublier() -> void:
	userid = ""
	pseudo = ""
	bio = ""
	email = ""
	token = ""
	connecte = false
	_regler_presence()
	DirAccess.remove_absolute(FICHIER)
	change.emit()


func deconnecter() -> void:
	if not token.is_empty():
		await data.post_json("/auth/logout", {}, token)
	token = ""
	pseudo = ""
	connecte = false
	_regler_presence()
	_sauver()
	change.emit()


## --- Présence ---

## Sans ces pings, on n'apparaît jamais en ligne pour nos amis : le serveur ne
## garde la présence qu'en RAM, et l'oublie faute de nouvelles.
func _regler_presence() -> void:
	if not connecte:
		minuteur.stop()
		return
	# Immédiatement, sinon on resterait hors ligne le temps du premier délai.
	_pinguer()
	minuteur.start()


## Annonce sa présence sans attendre le prochain battement. À appeler quand le
## lieu change : sinon un ami nous verrait encore nulle part pendant un cycle.
func signaler_presence() -> void:
	await _pinguer()


func _pinguer() -> void:
	if not connecte:
		return
	# Sans serveur : champ absent, pas de valeur sentinelle. C'est la convention
	# du serveur data — absent veut dire « rien à en dire ».
	var corps := {}
	if not serveur_courant.is_empty():
		corps["serveur"] = serveur_courant
	await data.post_json("/presence/heartbeat", corps, token)


## --- Stockage local ---

func _charger() -> void:
	var fichier := FileAccess.open(FICHIER, FileAccess.READ)
	if fichier == null:
		return
	var decode = JSON.parse_string(fichier.get_as_text())
	fichier.close()
	if typeof(decode) != TYPE_DICTIONARY:
		return
	phrase = decode.get("phrase", "")
	userid = decode.get("userid", "")
	token = decode.get("token", "")


func _sauver() -> void:
	var fichier := FileAccess.open(FICHIER, FileAccess.WRITE)
	if fichier == null:
		push_error("compte.json : écriture impossible")
		return
	fichier.store_string(JSON.stringify({
		"phrase": phrase, "userid": userid, "token": token,
	}, "  "))
	fichier.close()


## --- Interne ---

## Le message d'erreur du serveur s'il en donne un, le nôtre sinon.
func _message(reponse: Dictionary, defaut: String) -> String:
	var precis: String = reponse["json"].get("erreur", "")
	if precis.is_empty():
		return defaut
	return precis


func _depuis_hex(texte: String) -> PackedByteArray:
	if texte.is_empty() or texte.length() % 2 != 0:
		return PackedByteArray()
	var octets := PackedByteArray()
	for rang in texte.length() / 2:
		octets.append(texte.substr(rang * 2, 2).hex_to_int())
	return octets
