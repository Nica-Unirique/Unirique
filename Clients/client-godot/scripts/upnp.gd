extends Node

## Demande à la box d'ouvrir le port du serveur de jeu, et récupère au passage
## l'adresse IPv4 publique — que le client ne peut pas connaître autrement.
##
## Tout le travail se fait dans un THREAD : `UPNP.discover()` diffuse une requête
## sur le réseau et attend les réponses pendant plusieurs secondes. Sur le fil
## principal, le jeu se figerait à chaque publication.
##
## Sert uniquement à l'IPv4. En IPv6 il n'y a pas de NAT à percer — seulement un
## pare-feu, qu'UPnP ne gère pas.

## Plage du NAT opérateur (CGNAT). Une « adresse publique » qui tombe dedans
## n'en est pas une : la box est elle-même derrière un autre NAT, et la
## redirection qu'on vient d'obtenir ne mène nulle part.
const PREFIXES_NON_PUBLICS := ["10.", "192.168.", "172.16.", "172.17.", "172.18.", "169.254."]
const CGNAT_DEBUT := 64
const CGNAT_FIN := 127

var upnp: UPNP
var fil: Thread
var port_ouvert := 0
var _adresse := ""


## Ouvre le port et renvoie l'adresse publique, ou "" si c'est impossible.
## N'échoue jamais bruyamment : sans UPnP on publie simplement une adresse de
## moins, et l'IPv6 reste le meilleur chemin de toute façon.
func ouvrir(port: int) -> String:
	fermer()
	_adresse = ""

	fil = Thread.new()
	if fil.start(_travail.bind(port)) != OK:
		return ""
	# On attend sans bloquer : le jeu continue de tourner pendant la découverte.
	while fil.is_alive():
		await get_tree().process_frame
	fil.wait_to_finish()
	fil = null

	if _adresse.is_empty():
		return ""
	if _est_prive(_adresse):
		# Redirection obtenue, mais elle ne mène qu'au réseau de l'opérateur.
		push_warning("[upnp] adresse externe %s non publique (CGNAT)" % _adresse)
		fermer()
		return ""

	port_ouvert = port
	print("[upnp] port %d ouvert, adresse publique %s" % [port, _adresse])
	return _adresse


## Referme la redirection. Une box la garderait sinon jusqu'à son redémarrage.
func fermer() -> void:
	if upnp == null or port_ouvert == 0:
		upnp = null
		port_ouvert = 0
		return
	upnp.delete_port_mapping(port_ouvert, "UDP")
	upnp = null
	port_ouvert = 0


func _exit_tree() -> void:
	if fil != null and fil.is_alive():
		fil.wait_to_finish()
	fermer()


## Exécuté dans le thread. N'écrit que `upnp` et `_adresse`, lus après
## `wait_to_finish` — donc jamais pendant que le thread tourne.
func _travail(port: int) -> void:
	var appareil := UPNP.new()
	if appareil.discover() != UPNP.UPNP_RESULT_SUCCESS:
		return
	var passerelle := appareil.get_gateway()
	if passerelle == null or not passerelle.is_valid_gateway():
		return

	# ENet parle UDP : une redirection TCP ne servirait à rien.
	# Durée 0 = permanente ; beaucoup de box refusent les durées limitées.
	var ouverture := appareil.add_port_mapping(port, port, "Unirique", "UDP", 0)
	if ouverture != UPNP.UPNP_RESULT_SUCCESS:
		return

	upnp = appareil
	_adresse = appareil.query_external_address()


static func _est_prive(adresse: String) -> bool:
	for prefixe in PREFIXES_NON_PUBLICS:
		if adresse.begins_with(prefixe):
			return true
	# 100.64.0.0/10 : le NAT des opérateurs, à ne pas confondre avec le 100.x
	# public qui existe aussi.
	if not adresse.begins_with("100."):
		return false
	var second := adresse.split(".")[1].to_int()
	return second >= CGNAT_DEBUT and second <= CGNAT_FIN
