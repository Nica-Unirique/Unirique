extends Node

## Publie NOTRE serveur de jeu local dans l'annuaire, et le maintient vivant.
##
## C'est le client qui annonce, pas le serveur de jeu : lui n'a pas de compte,
## donc pas de jeton. Le serveur data ne connaît d'un serveur que ce qu'on lui
## en dit ici — nom, adresse, jeu, et sa politique de visibilité.
##
## Contrat : Norms/api_routes.csv, section serveurs_jouables.

const Data := preload("res://scripts/data.gd")
const Compte := preload("res://scripts/compte.gd")
const Upnp := preload("res://scripts/upnp.gd")

## Le serveur data oublie un serveur après `serveurs_jouables.heartbeat_seuil_
## secondes` (30 s). On ping trois fois plus souvent, pour survivre à deux pertes.
const PING_SECONDES := 10.0

## Injectés par client.gd avant `add_child`.
var data: Data
var compte: Compte

## Ce qu'on nous demande de publier, indépendamment de notre capacité à le faire
## maintenant. Cette mémoire est le cœur du dispositif : le serveur local naît
## au démarrage, AVANT que la session ne soit ouverte, et une tentative unique
## arriverait donc toujours trop tôt. La demande, elle, attend son heure.
var port_demande := 0
var jeu_demande := ""

## Identifiant attribué par l'annuaire, "" tant qu'on ne publie pas.
var serveur_id := ""
## Visibilité sous laquelle on s'est déclaré. Sans ça, on ne saurait pas
## distinguer un apply qui la périme d'un apply sur la qualité graphique — et on
## se redéclarerait à chaque passage dans les réglages.
var visibilite_publiee := ""
## Vrai le temps d'un aller-retour avec l'annuaire. Une reconsidération peut
## survenir pendant cette attente ; sans ce drapeau on se déclarerait deux fois,
## et l'entrée orpheline resterait visible jusqu'à son oubli.
var en_cours := false

var minuteur: Timer
var upnp: Upnp


func _ready() -> void:
	minuteur = Timer.new()
	minuteur.wait_time = PING_SECONDES
	minuteur.timeout.connect(_pinguer)
	add_child(minuteur)

	upnp = Upnp.new()
	add_child(upnp)

	# Publier dépend de trois entrées : la session, `server.publish` et
	# `server.visibility`. On se rebranche sur chacune plutôt que de choisir le
	# bon moment pour tester — un moment juste n'existe pas ici.
	compte.change.connect(_reconsiderer)
	Settings.applied.connect(_reconsiderer)


## Demande la publication du serveur local. Elle sera honorée dès que possible :
## tout de suite si la session est ouverte, à son ouverture sinon.
func publier(port: int, jeu: String) -> void:
	_depublier()
	port_demande = port
	jeu_demande = jeu
	_tenter()


## Les gardes vivent ICI et nulle part ailleurs. Un refus n'est jamais définitif :
## `_reconsiderer` repassera quand sa cause aura disparu.
func _tenter() -> void:
	if port_demande == 0 or en_cours or not serveur_id.is_empty():
		return
	# Se taire a déjà coûté une session de test : personne ne voyait l'hôte, et
	# rien n'expliquait pourquoi. Un refus doit dire son motif.
	if not compte.connecte:
		print("[annonce] pas de session : publication remise à l'ouverture")
		return
	if not Settings.get_value("server.publish"):
		print("[annonce] réglage server.publish désactivé : serveur non publié")
		return

	if not await _enregistrer(adresses_joignables(port_demande)):
		return

	# UPnP ensuite, en arrière-plan : la découverte prend jusqu'à vingt secondes,
	# et échoue sur bien des réseaux. L'attendre retarderait d'autant le moment
	# où nos amis nous voient — alors qu'on est déjà joignable en IPv6 et sur le
	# réseau local.
	if Settings.get_value("server.upnp"):
		_completer_par_upnp()


## Rejoue la décision de publier. Appelée à chaque changement d'une entrée dont
## elle dépend, et sans effet si rien de pertinent n'a bougé.
func _reconsiderer() -> void:
	var devrait := port_demande != 0 and compte.connecte \
		and bool(Settings.get_value("server.publish"))
	var publie := not serveur_id.is_empty()
	var perimee: bool = publie and visibilite_publiee != Settings.get_value(
		"server.visibility"
	)

	# Retirer d'abord, ajouter ensuite : couper le partage en pleine partie doit
	# nous faire disparaître tout de suite, pas au prochain lancement.
	if publie and (not devrait or perimee):
		_depublier()
		publie = false
	if devrait and not publie:
		_tenter()


## Une fois le port ouvert, on se redéclare avec l'adresse publique en plus.
## L'ancienne entrée n'est plus entretenue : l'annuaire l'oubliera seul.
func _completer_par_upnp() -> void:
	var attendu := port_demande
	var publique := await upnp.ouvrir(attendu)
	if publique.is_empty():
		return
	# On a pu arrêter, changer de serveur ou cesser de publier pendant la
	# découverte — vingt secondes laissent le temps de bien des choses.
	if serveur_id.is_empty() or port_demande != attendu:
		upnp.fermer()
		return
	await _enregistrer(adresses_joignables(attendu, publique))


func _enregistrer(adresses: PackedStringArray) -> bool:
	if adresses.is_empty():
		push_warning("[annonce] aucune adresse réseau utilisable")
		return false

	# Lue avant l'envoi et retenue après : c'est bien SOUS cette visibilité-là
	# qu'on figure dans l'annuaire, quoi que le réglage devienne ensuite.
	var visibilite: String = Settings.get_value("server.visibility")
	en_cours = true
	var reponse: Dictionary = await data.post_json("/servers/register", {
		"nom": "Serveur de %s" % compte.pseudo,
		"adresses": adresses,
		"jeu": jeu_demande,
		"visibilite": visibilite,
	}, compte.token)
	en_cours = false

	if not reponse["ok"]:
		push_warning("[annonce] publication refusée : %s" % reponse["json"].get(
			"erreur", "raison inconnue"
		))
		return false

	serveur_id = reponse["json"].get("serveur_id", "")
	visibilite_publiee = visibilite
	# La présence ne transmet QUE cet identifiant : c'est l'annuaire, qui connaît
	# la politique du serveur, qui décide ensuite à qui le révéler.
	compte.serveur_courant = serveur_id
	# Sans ça, nos amis nous verraient encore nulle part jusqu'au battement
	# suivant — et le bouton Rejoindre resterait éteint pour rien.
	await compte.signaler_presence()
	minuteur.start()
	print("[annonce] serveur publié : %s (%d adresses)" % [
		serveur_id, adresses.size()
	])
	return true


## On quitte le serveur : plus rien à publier, ni maintenant ni plus tard.
## L'annuaire oubliera l'entrée de lui-même au bout de son seuil. Aucune route de
## retrait n'existe, et c'est cohérent : un hôte qui plante ne pourrait pas
## l'appeler non plus.
func arreter() -> void:
	port_demande = 0
	jeu_demande = ""
	_depublier()


## Cesse d'entretenir la publication mais GARDE la demande : une session qui se
## ferme puis se rouvre, un partage qu'on rallume, et l'on republie sans que le
## joueur ait eu à quitter son monde.
func _depublier() -> void:
	minuteur.stop()
	# Refermer la redirection : une box la garderait sinon jusqu'à son
	# redémarrage, laissant un port ouvert vers plus rien.
	if upnp != null:
		upnp.fermer()
	var publiait := not serveur_id.is_empty()
	serveur_id = ""
	visibilite_publiee = ""
	compte.serveur_courant = ""
	# Dire tout de suite qu'on n'y est plus, plutôt que d'y paraître encore
	# jusqu'au battement suivant.
	if publiait:
		compte.signaler_presence()


func _pinguer() -> void:
	if serveur_id.is_empty():
		return
	var reponse: Dictionary = await data.post_json("/servers/heartbeat", {
		"serveur_id": serveur_id,
		"nb_joueurs": 1,  # le compte réel viendra du serveur de jeu
	}, compte.token)

	# L'annuaire a pu nous oublier (redémarrage, seuil dépassé). On se redéclare
	# vraiment — l'ancien code se contentait d'arrêter, en promettant l'inverse
	# dans son commentaire, et le serveur ne revenait jamais.
	if not reponse["ok"]:
		push_warning("[annonce] heartbeat refusé : on se redéclare")
		_depublier()
		_tenter()


## Préfixes des réseaux privés IPv4, par ordre de préférence. Prendre la
## première adresse venue ne marche pas : une machine a souvent des cartes
## virtuelles (VM, VPN) dont l'adresse ne mène nulle part.
const PREFIXES_PRIVES := ["192.168.", "10.", "172.16.", "172.17.", "172.18."]


## Toutes les adresses où l'on peut être joint, de la meilleure à la pire :
##   1. IPv6 globale  — pas de NAT du tout, connexion directe
##   2. IPv4 publique — passe partout, mais exige que le port soit ouvert
##   3. IPv4 privée   — seulement entre machines du même réseau
##
## Une liste, et pas la meilleure seule : un ami sans IPv6 doit pouvoir passer
## par autre chose, et les IPv6 globales sont souvent temporaires — publier
## celles qu'on a laisse au client le soin d'en trouver une qui répond.
static func adresses_joignables(port: int, publique := "") -> PackedStringArray:
	var trouvees := PackedStringArray()
	# Notation standard : les crochets lèvent l'ambiguïté des deux-points.
	for adresse in ipv6_globales():
		trouvees.append("[%s]:%d" % [adresse, port])
	if not publique.is_empty():
		trouvees.append("%s:%d" % [publique, port])
	var privee := ipv4_privee()
	if not privee.is_empty():
		trouvees.append("%s:%d" % [privee, port])
	return trouvees


## Plage publique de Tailscale : globale en apparence, mais joignable seulement
## depuis le même tailnet. La publier ferait perdre plusieurs secondes en
## tentatives vouées à l'échec pour un ami qui n'y est pas.
const PREFIXE_TAILSCALE := "2620:9b:"


## IPv6 routables sur internet. On écarte le lien-local `fe80::` (valable sur un
## seul segment réseau), l'unique-local `fd00::/8` (réseaux privés) et la boucle
## locale : aucun ne mène à nous depuis l'extérieur.
static func ipv6_globales() -> PackedStringArray:
	var trouvees := PackedStringArray()
	for adresse in IP.get_local_addresses():
		if not adresse.contains(":"):
			continue
		var minuscule := adresse.to_lower()
		if minuscule.begins_with("fe80:") or minuscule.begins_with("fd"):
			continue
		if minuscule.begins_with(PREFIXE_TAILSCALE) or _est_boucle_locale(minuscule):
			continue
		trouvees.append(adresse)
	return trouvees


## `::1` s'écrit de plusieurs façons — Godot rend la forme étendue
## `0:0:0:0:0:0:0:1`. On compare donc la valeur, pas le texte.
static func _est_boucle_locale(adresse: String) -> bool:
	return adresse.replace(":", "").replace("0", "") == "1"


static func ipv4_privee() -> String:
	var candidates := PackedStringArray()
	for adresse in IP.get_local_addresses():
		if adresse.contains(":") or adresse.begins_with("127."):
			continue
		# 169.254.x.x : APIPA, attribuée faute de DHCP — l'interface n'est
		# reliée à rien. La publier donnerait une adresse injoignable.
		if adresse.begins_with("169.254."):
			continue
		candidates.append(adresse)

	for prefixe in PREFIXES_PRIVES:
		for adresse in candidates:
			if adresse.begins_with(prefixe):
				return adresse
	return candidates[0] if candidates.size() > 0 else ""
