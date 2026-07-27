extends "res://scripts/wasm_host.gd"

## Client : l'hôte WASM commun, plus l'affichage, le menu et les entrées locales.

## Un jeu = un DOSSIER à côté de l'exécutable. Le client y cherche `client.wasm`,
## le serveur `server.wasm`.
const GAMES := [
	"./Games/Hub",
	"./Games/Collect",
]
const FICHIER_CLIENT := "client.wasm"

## Sans `--join`, le client héberge : il lance son propre serveur et s'y connecte.
const ADRESSE_LOCALE := "127.0.0.1"
## Le serveur local met un instant à démarrer ; inutile de frapper avant.
const DELAI_DEMARRAGE := 1.0
const DELAI_ESSAI := 0.5
const ESSAIS_MAX := 20
## Temps laissé à UNE adresse pour aboutir. ENet, lui, met une trentaine de
## secondes à conclure qu'une adresse ne répond pas — et il ne le dit pas
## toujours. Avec cinq IPv6 devant l'IPv4 qui marche, s'en remettre à lui
## laissait le joueur plus de deux minutes devant un écran noir.
const DELAI_TENTATIVE := 3.0
## Ports testés à partir de celui demandé. Le serveur précédent peut tenir
## encore le sien : on prend le suivant plutôt que d'attendre qu'il meure.
const PORTS_TESTES := 16

const Replication := preload("res://scripts/replication.gd")
const Boot := preload("res://scripts/boot.gd")
const Data := preload("res://scripts/data.gd")
const Compte := preload("res://scripts/compte.gd")
const Annonce := preload("res://scripts/annonce.gd")
const VrRig := preload("res://scripts/vr.gd")
const Inputs := preload("res://scripts/input.gd")

## Caméra à la PREMIÈRE personne, sur écran comme en VR.
## Hauteur des yeux, en fraction de la demi-hauteur de l'avatar : elle suit donc
## sa taille sans qu'on ait à la connaître.
const PART_YEUX := 0.8
## Marge devant le visage. La caméra est posée juste DEVANT la tête plutôt que
## dedans : on garde ainsi son corps visible sans voir l'intérieur du volume.
const MARGE_VISAGE := 0.15
const TANGAGE_MIN := -1.4
const TANGAGE_MAX := 1.4
## Radians par pixel de souris, pour une sensibilité réglée à 50.
const SENSIBILITE_BASE := 0.003

## Durée sur laquelle on rejoint l'état reçu. Doit correspondre à REPLICATION_HZ
## du serveur : plus court, l'objet arrive et attend ; plus long, il traîne.
const INTERVALLE_REPLICATION := 0.05

var current := 0
var menu: Node3D
var camera: Camera3D
var environnement: Environment
## Correspondance identifiant serveur -> identifiant local. Les objets répliqués
## sont des objets comme les autres : ils vivent dans `entities` et passent par
## le même code. Seule leur numérotation vient d'ailleurs.
var ids_serveur := {}
## Hash des octets reçus, par identifiant serveur. Sert à comparer notre scène
## à celle du serveur sans jamais relire l'état des nœuds Godot.
var hashs := {}

## Interpolation : on va de `depart` vers `arrivee` en un intervalle. Le serveur
## envoie 20 fois par seconde, l'écran affiche bien plus souvent — sans ça, les
## objets répliqués avanceraient par saccades.
var depart_position := {}
var arrivee_position := {}
var depart_rotation := {}
var arrivee_rotation := {}
var avancement := 1.0
## Temps réellement écoulé entre deux ticks reçus, lissé. On ne suppose pas la
## cadence du serveur : on la mesure. Le client reste juste même si le serveur
## tourne à une autre fréquence ou ralentit.
var intervalle_mesure := INTERVALLE_REPLICATION
var temps_depuis_tick := 0.0

## Regard du joueur. Le lacet part au serveur — il décide du déplacement. Le
## tangage reste local : il ne sert qu'au cadrage.
var lacet := 0.0
var tangage := -0.2
var sensibilite := SENSIBILITE_BASE
var inverser_tangage := false
## Identifiant SERVEUR de mon avatar, 0 tant que le serveur ne l'a pas dit.
var mon_avatar := 0
var vr: VrRig
var inputs: Inputs
var data: Data
var compte: Compte
var annonce: Annonce
## Front montant de l'action `menu` : un appui = une bascule.
var menu_arme := true

## Serveur lancé par ce client. -1 = aucun (on a rejoint un serveur distant).
var serveur_local := -1
## Identifiant d'annuaire du serveur DISTANT qu'on rejoint, "" sinon. Quand on
## héberge, c'est `annonce` qui renseigne la présence ; ici c'est à nous, sinon
## nos amis nous verraient en ligne mais nulle part.
var serveur_rejoint := ""
## Vrai quand c'est NOUS qui hébergeons. Le serveur suit alors le jeu courant.
var heberge := false
var jeu_courant := ""
var adresse_serveur := ADRESSE_LOCALE
var port_serveur := Boot.PORT_DEFAUT
var essais_connexion := 0
## Incrémenté à chaque changement de destination : un essai de connexion en
## attente qui ne correspond plus est abandonné au lieu de joindre l'ancienne.
var session := 0
## Adresses encore à essayer pour joindre le serveur d'un ami, dans l'ordre.
var replis: Array = []


## L'ordre est contraint : le menu lit `compte` dans son `_ready`, et `compte`
## a besoin de `data`.
func _ready() -> void:
	_build_scene()
	# Après _build_scene : le rig VR existe, input le lit pour ses bindings VR.
	inputs = Inputs.new(vr)

	# L'annuaire est interrogé en parallèle : il n'héberge aucune partie, donc
	# son silence ne doit rien empêcher. On joue en local sans lui.
	data = Data.new()
	add_child(data)
	data.verifier()

	compte = Compte.new()
	compte.data = data
	add_child(compte)
	# Un jeton mémorisé a pu être révoqué ailleurs : on le revalide plutôt que
	# d'afficher un compte connecté qui ne l'est plus.
	compte.valider_session()

	annonce = Annonce.new()
	annonce.data = data
	annonce.compte = compte
	add_child(annonce)

	menu = preload("res://scripts/menu.gd").new()
	# Propriétés posées AVANT add_child : le menu les lit dans son _ready.
	menu.vr = vr
	menu.compte = compte
	add_child(menu)
	menu.rejoindre_serveur.connect(_rejoindre_adresse)

	Settings.applied.connect(_apply_settings)
	_apply_settings()

	_load_game(0)
	_demarrer_reseau()


## Ce que le client possède : la caméra, l'environnement et le regard.
func _apply_settings() -> void:
	camera.fov = Settings.get_value("display.fov")
	environnement.ssao_enabled = Settings.get_value("display.ssao")
	# 50 est la valeur neutre : le réglage multiplie la sensibilité de base.
	sensibilite = SENSIBILITE_BASE * Settings.get_value("controls.mouse_sensitivity") / 50.0
	inverser_tangage = Settings.get_value("controls.invert_y")


func _build_scene() -> void:
	_construire_camera()

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55.0, -35.0, 0.0)
	add_child(light)

	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.05, 0.06, 0.08)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.35, 0.37, 0.42)
	we.environment = env
	add_child(we)
	environnement = env


## VR si un casque répond, écran sinon. Aucune bascule à régler : la présence
## du matériel décide.
func _construire_camera() -> void:
	vr = preload("res://scripts/vr.gd").new()
	add_child(vr)

	if vr.demarrer():
		camera = vr.camera
		print("VR active")
		return

	var cam := Camera3D.new()
	add_child(cam)
	camera = cam


func _load_game(index: int) -> void:
	var jeu: String = GAMES[index]
	var dossier := Boot.chemin_jeu(jeu)
	# Un des deux modules peut manquer, pas les deux : un dossier sans aucun
	# n'est pas un jeu.
	if not Boot.est_un_jeu(dossier):
		push_error("Pas de jeu dans %s : ni client.wasm ni server.wasm" % jeu)
		return
	if not charger(dossier.path_join(FICHIER_CLIENT), _imports_client()):
		return
	current = index
	print("Jeu chargé : ", jeu)

	# Si on héberge, le serveur suit : l'ancien s'arrête, un nouveau démarre sur
	# ce jeu. Chez un ami, on ne touche à rien — c'est lui qui décide du jeu.
	if heberge:
		rejoindre_local(jeu)
	else:
		jeu_courant = jeu


func _process(delta: float) -> void:
	_basculer_menu()

	if not menu.ouvert and Input.is_action_just_pressed("ui_focus_next"):
		_load_game((current + 1) % GAMES.size())
		return

	_regler_souris()
	_tourner_en_vr(delta)
	_envoyer_entrees()

	# Le jeu tourne TOUJOURS — jamais de pause (multijoueur).
	mettre_a_jour(delta)
	_interpoler(delta)
	_placer_camera()


## Un appui sur l'action `menu` bascule le menu. Lu directement dans `inputs`,
## hors de la porte du menu, sinon on ne pourrait plus le refermer.
func _basculer_menu() -> void:
	var presse := inputs.value_action("menu") >= 0.5
	if presse and menu_arme:
		menu.basculer()
	menu_arme = not presse


## --- Regard et caméra ---

## Souris capturée pour jouer, libérée dès que le menu s'ouvre. Sans objet en VR.
func _regler_souris() -> void:
	if vr.actif:
		return
	var voulu := (
		Input.MOUSE_MODE_VISIBLE if menu.ouvert else Input.MOUSE_MODE_CAPTURED
	)
	if Input.mouse_mode != voulu:
		Input.mouse_mode = voulu


## Rotation au joystick droit. Le tangage, lui, appartient au casque.
func _tourner_en_vr(delta: float) -> void:
	if not vr.actif or menu.ouvert:
		return
	lacet -= vr.entree_rotation() * vr.VITESSE_ROTATION * delta


func _unhandled_input(evenement: InputEvent) -> void:
	if menu.ouvert:
		return
	var souris := evenement as InputEventMouseMotion
	if souris == null:
		return

	lacet -= souris.relative.x * sensibilite
	var vertical := souris.relative.y * sensibilite
	tangage = clampf(
		tangage + (vertical if inverser_tangage else -vertical),
		TANGAGE_MIN, TANGAGE_MAX
	)


## Première personne : on se place dans l'avatar. Tant que le serveur ne l'a pas
## nommé, la caméra ne bouge pas.
func _placer_camera() -> void:
	var local := _objet_avatar()
	if local == 0:
		return

	var centre: Vector3 = entities[local].position
	var demi := _get_scale_y(local) * 0.5
	var devant := _devant(local)

	if vr.actif:
		# L'origine XR se cale aux PIEDS : le casque fournit la tête, y compris
		# quand le joueur se baisse ou se déplace dans sa pièce.
		vr.position = centre - Vector3.UP * demi + devant
		vr.quaternion = Quaternion(Vector3.UP, lacet)
		return

	camera.position = centre + Vector3.UP * (demi * PART_YEUX) + devant
	camera.basis = Basis.from_euler(Vector3(tangage, lacet, 0.0))


## Décalage qui sort la caméra du volume de l'avatar, dans l'axe du CORPS et non
## du regard : sinon tourner la tête en VR ferait glisser le monde.
func _devant(local: int) -> Vector3:
	var distance := _get_scale_z(local) * 0.5 + MARGE_VISAGE
	return Quaternion(Vector3.UP, lacet) * (Vector3.FORWARD * distance)


## L'objet LOCAL qui porte mon avatar. 0 tant que le serveur ne l'a pas nommé
## ou que sa première réplication n'est pas arrivée.
func _objet_avatar() -> int:
	if mon_avatar == 0 or not ids_serveur.has(mon_avatar):
		return 0
	var local: int = ids_serveur[mon_avatar]
	return local if entities.has(local) else 0


## Le serveur nous dit lequel des avatars répliqués est le nôtre. Fiable :
## le message ne part qu'une fois.
@rpc("authority", "reliable")
func recevoir_avatar(objet: int) -> void:
	mon_avatar = objet
	print("Mon avatar : ", objet)


## Envoie les 6 touches au serveur, packées dans un seul entier.
func _envoyer_entrees() -> void:
	if multiplayer.multiplayer_peer == null:
		return
	# La connexion est asynchrone : sans cette garde, on envoie pendant la
	# poignée de main et Godot rejette le RPC « peer not connected ».
	if multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return
	if multiplayer.get_unique_id() == 1:
		return  # on EST le serveur : personne à qui envoyer

	# Les 7 valeurs d'entrée, une par code du contrat.
	var valeurs := PackedFloat32Array()
	valeurs.resize(Inputs.ACTIONS.size())
	for code in Inputs.ACTIONS.size():
		valeurs[code] = _input_value(code)

	# En VR, le regard c'est la rotation du corps PLUS celle de la tête.
	rpc_id(1, "recevoir_entrees", valeurs, lacet + vr.lacet_casque())


## Reçue par le serveur uniquement. Déclarée ici parce que Godot exige la même
## signature des deux côtés pour apparier un RPC.
@rpc("any_peer", "unreliable_ordered")
func recevoir_entrees(_valeurs: PackedFloat32Array, _lacet: float) -> void:
	pass


## --- Connexion au serveur ---

func _demarrer_reseau() -> void:
	multiplayer.connected_to_server.connect(_connecte)
	multiplayer.connection_failed.connect(_connexion_echouee)
	multiplayer.server_disconnected.connect(_serveur_perdu)

	var distant := Boot.argument("join", "")
	if distant.is_empty():
		rejoindre_local(Boot.jeu())
	else:
		rejoindre_distant(distant, Boot.port())


## Héberge un jeu : lance le serveur local dessus puis s'y connecte. Le serveur
## naît ICI et pas au démarrage de l'exe — quitter un ami pour revenir en local
## le relance, changer de jeu le remplace.
## `jeu` est relatif à l'exécutable, ex. "./Games/Hub".
func rejoindre_local(jeu: String) -> void:
	quitter()
	heberge = true
	jeu_courant = jeu
	adresse_serveur = ADRESSE_LOCALE
	port_serveur = _port_libre()
	_lancer_serveur_local()
	# Publié seulement maintenant : le port n'était pas connu avant.
	annonce.publier(port_serveur, jeu)
	_reessayer(DELAI_DEMARRAGE)


## Premier port disponible à partir de celui demandé. On sonde avec le même type
## de socket que le vrai serveur, pour que le test soit fidèle.
func _port_libre() -> int:
	var base := Boot.port()
	for decalage in PORTS_TESTES:
		var sonde := ENetMultiplayerPeer.new()
		if sonde.create_server(base + decalage) == OK:
			sonde.close()
			return base + decalage
	push_warning("Aucun port libre à partir de %d" % base)
	return base


## Rejoint le serveur d'un ami. L'annuaire en donne plusieurs adresses, de la
## meilleure à la pire : IPv6 globale d'abord (aucun NAT à traverser), replis
## ensuite. On les essaie dans l'ordre.
func _rejoindre_adresse(serveur_id: String, adresses: Array) -> void:
	quitter()
	# Après `quitter`, qui l'efface : on entre chez quelqu'un, on ne quitte pas.
	serveur_rejoint = serveur_id
	replis.clear()
	for brute in adresses:
		var coupe := _couper_adresse(brute)
		if not coupe.is_empty():
			replis.append(coupe)
	if replis.is_empty():
		push_warning("Aucune adresse exploitable")
		return
	_essayer_repli_suivant()


## « [2a01:cb00::1]:25000 » ou « 192.168.1.10:25000 » -> {hote, port}.
## Les crochets ne sont pas décoratifs : sans eux, impossible de distinguer le
## séparateur de port des deux-points d'une IPv6.
func _couper_adresse(brute: String) -> Dictionary:
	var separateur := brute.rfind(":")
	if separateur < 0 or not brute.substr(separateur + 1).is_valid_int():
		return {}
	var hote := brute.substr(0, separateur)
	if hote.begins_with("[") and hote.ends_with("]"):
		hote = hote.substr(1, hote.length() - 2)
	if hote.is_empty():
		return {}
	return {"hote": hote, "port": int(brute.substr(separateur + 1))}


func _essayer_repli_suivant() -> void:
	if replis.is_empty():
		push_warning("Aucune des adresses n'a répondu")
		return
	var suivante: Dictionary = replis[0]
	replis.remove_at(0)
	# Pas `rejoindre_distant` : il appellerait `quitter`, qui effacerait les
	# replis restants. Ici on ne change que de cible, dans la même tentative.
	session += 1
	essais_connexion = 0
	adresse_serveur = suivante["hote"]
	port_serveur = suivante["port"]
	print("Tentative sur ", adresse_serveur, ":", port_serveur)
	_essayer_connexion(session)


## Rejoint le serveur de quelqu'un d'autre : rien à héberger.
func rejoindre_distant(adresse: String, port: int) -> void:
	quitter()
	adresse_serveur = adresse
	port_serveur = port
	_essayer_connexion(session)


## Quitte le serveur courant et oublie tout ce qui en venait. Arrête le serveur
## local s'il y en avait un : il n'existe que le temps qu'on y joue.
func quitter() -> void:
	session += 1
	essais_connexion = 0
	# Abandon délibéré : on renonce aussi aux adresses de secours en attente.
	replis.clear()
	heberge = false
	mon_avatar = 0
	serveur_rejoint = ""

	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
	_tout_retirer()
	if annonce != null:
		annonce.arreter()
	_arreter_serveur_local()


## Relance le MÊME exécutable avec `--server`. Un serveur local et un serveur
## dédié sont donc strictement le même programme.
func _lancer_serveur_local() -> void:
	var arguments := PackedStringArray(["--headless", "--xr-mode", "off"])
	# Depuis l'éditeur, l'exécutable est Godot : il faut lui désigner le projet.
	if OS.has_feature("editor"):
		arguments.append("--path")
		arguments.append(ProjectSettings.globalize_path("res://"))
	arguments.append("--")
	arguments.append("--server")
	arguments.append("--port=%d" % port_serveur)
	arguments.append("--game=%s" % jeu_courant)
	# Qu'il s'éteigne seul si nous disparaissons sans avoir pu le tuer (plantage).
	arguments.append("--auto-quit")

	serveur_local = OS.create_process(OS.get_executable_path(), arguments)
	if serveur_local < 0:
		push_error("Impossible de lancer le serveur local")
		return
	print("Serveur local lancé (pid ", serveur_local, ") sur ", jeu_courant)


func _essayer_connexion(pour_session: int) -> void:
	if pour_session != session:
		return  # une autre destination a été demandée entre-temps
	essais_connexion += 1
	var pair := ENetMultiplayerPeer.new()
	if pair.create_client(adresse_serveur, port_serveur) != OK:
		_echec_tentative(DELAI_ESSAI)
		return
	multiplayer.multiplayer_peer = pair
	# On ne compte pas sur ENet pour renoncer : c'est nous qui décidons quand
	# cette adresse a eu sa chance.
	get_tree().create_timer(DELAI_TENTATIVE).timeout.connect(
		_expirer_tentative.bind(session, essais_connexion), CONNECT_ONE_SHOT
	)


## Cette adresse n'a pas abouti dans le temps imparti. Les deux gardes écartent
## les minuteries périmées : on a pu changer de cible (session) ou déjà relancer
## une tentative (essai) entre-temps.
func _expirer_tentative(pour_session: int, pour_essai: int) -> void:
	if pour_session != session or pour_essai != essais_connexion:
		return
	if multiplayer.multiplayer_peer == null:
		return
	if multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		return
	print("Sans réponse : ", adresse_serveur, ":", port_serveur)
	multiplayer.multiplayer_peer = null
	_echec_tentative(DELAI_ESSAI)


## Un échec est un échec, qu'il vienne du refus immédiat de `create_client` ou
## d'un délai réseau écoulé : dans les deux cas cette adresse-ci ne répond pas,
## et c'est à la suivante de tenter sa chance.
##
## Les distinguer a coûté une session de test. Une machine sans IPv6 fait
## échouer `create_client` SUR-LE-CHAMP ; ce chemin-là réessayait la même
## adresse morte vingt fois puis renonçait, sans jamais atteindre l'IPv4 du
## même réseau local qui, elle, marchait.
func _echec_tentative(delai: float) -> void:
	if not replis.is_empty():
		_essayer_repli_suivant()
		return
	_reessayer(delai)


## Insiste sur l'adresse COURANTE. C'est ce qu'il faut pour notre serveur local,
## qui met un instant à ouvrir son port — pas pour un serveur distant, où c'est
## `_echec_tentative` qui décide.
func _reessayer(delai: float) -> void:
	if essais_connexion >= ESSAIS_MAX:
		push_warning("Serveur injoignable : %s:%d" % [adresse_serveur, port_serveur])
		return
	get_tree().create_timer(delai).timeout.connect(
		_essayer_connexion.bind(session), CONNECT_ONE_SHOT
	)


func _connecte() -> void:
	print("Connecté au serveur, joueur ", multiplayer.get_unique_id())
	# Seulement MAINTENANT : on y est vraiment. L'annoncer dès la demande de
	# connexion reviendrait à se dire chez un ami avant d'avoir su l'y joindre —
	# et les adresses de repli sont justement là parce que ça arrive.
	if not serveur_rejoint.is_empty():
		compte.serveur_courant = serveur_rejoint
		compte.signaler_presence()


func _connexion_echouee() -> void:
	multiplayer.multiplayer_peer = null
	# Une IPv6 injoignable ne le deviendra pas en réessayant vingt fois.
	_echec_tentative(DELAI_ESSAI)


## Le serveur local est notre processus fils : il ne doit pas nous survivre.
func _arreter_serveur_local() -> void:
	if serveur_local < 0:
		return
	OS.kill(serveur_local)
	print("Serveur local arrêté (pid ", serveur_local, ")")
	serveur_local = -1


func _exit_tree() -> void:
	_arreter_serveur_local()


func _notification(quoi: int) -> void:
	if quoi == NOTIFICATION_WM_CLOSE_REQUEST:
		_arreter_serveur_local()


func _serveur_perdu() -> void:
	push_warning("Serveur perdu")
	multiplayer.multiplayer_peer = null
	_tout_retirer()
	# Ne pas laisser nos amis nous croire encore là-bas : l'hôte a fermé, et
	# l'annuaire n'a aucun moyen de l'apprendre autrement que par nous.
	if not serveur_rejoint.is_empty():
		serveur_rejoint = ""
		compte.serveur_courant = ""
		compte.signaler_presence()


## --- Réception de la scène ---

## Le serveur n'envoie que ce qui a changé, plus le hash de sa scène entière.
## On applique, on hashe de notre côté, et on compare. Voir Norms/replication.md.
@rpc("authority", "unreliable_ordered")
func recevoir_tick(
	tick: int, destructions: PackedInt64Array, modifications: PackedByteArray, hash_serveur: int
) -> void:
	_mesurer_intervalle()
	_figer_etat_affiche()
	_appliquer_destructions(destructions)
	_appliquer_modifications(modifications)
	temps_depuis_tick = 0.0
	avancement = 0.0

	# Étape 3 : on mesure la fréquence des divergences avant d'écrire la
	# réparation. Corriger avant de savoir, ce serait déboguer deux choses.
	if Replication.hash_scene(hashs) != hash_serveur:
		print("[replication] divergence au tick ", tick)


## Le nouveau départ de chaque objet est là où il est actuellement AFFICHÉ, pas
## là où il devait arriver : sinon un objet interrompu en cours de route
## reviendrait en arrière. Départ = arrivée par défaut, donc un objet non
## modifié reste immobile.
func _figer_etat_affiche() -> void:
	for id_serveur in arrivee_position:
		depart_position[id_serveur] = _position_affichee(id_serveur)
		depart_rotation[id_serveur] = _rotation_affichee(id_serveur)
		arrivee_position[id_serveur] = depart_position[id_serveur]
		arrivee_rotation[id_serveur] = depart_rotation[id_serveur]


func _appliquer_destructions(destructions: PackedInt64Array) -> void:
	for id_serveur in destructions:
		if not ids_serveur.has(id_serveur):
			continue
		_destroy(ids_serveur[id_serveur])
		ids_serveur.erase(id_serveur)
		hashs.erase(id_serveur)
		_oublier_interpolation(id_serveur)


func _appliquer_modifications(modifications: PackedByteArray) -> void:
	for rang in Replication.nombre_objets(modifications):
		var id_serveur := Replication.id_de(modifications, rang)
		_poser_immediat(_id_local(id_serveur), modifications, rang)
		_viser(id_serveur, modifications, rang)
		# Le hash porte sur les octets REÇUS, jamais sur ce que Godot en a fait.
		hashs[id_serveur] = Replication.fnv1a64(
			Replication.octets_de(modifications, rang)
		)


## Fixe la cible de l'objet. Un objet vu pour la première fois part de sa cible :
## il apparaît à sa place au lieu d'y glisser depuis l'origine.
func _viser(id_serveur: int, tampon: PackedByteArray, rang: int) -> void:
	var position := Replication.position_de(tampon, rang)
	var rotation := Replication.rotation_de(tampon, rang)

	if not arrivee_position.has(id_serveur):
		depart_position[id_serveur] = position
		depart_rotation[id_serveur] = rotation

	arrivee_position[id_serveur] = position
	arrivee_rotation[id_serveur] = rotation


func _oublier_interpolation(id_serveur: int) -> void:
	depart_position.erase(id_serveur)
	arrivee_position.erase(id_serveur)
	depart_rotation.erase(id_serveur)
	arrivee_rotation.erase(id_serveur)


## L'objet local qui représente l'objet serveur donné, créé à la première vue.
func _id_local(id_serveur: int) -> int:
	if ids_serveur.has(id_serveur):
		return ids_serveur[id_serveur]
	var local := _spawn()
	ids_serveur[id_serveur] = local
	return local


## Ce qui n'est pas interpolé : échelle et couleur. Elles changent rarement et
## par sauts — les lisser donnerait un fondu, pas un mouvement.
## Position et rotation passent par `_interpoler`.
func _poser_immediat(local: int, tampon: PackedByteArray, rang: int) -> void:
	var echelle := Replication.echelle_de(tampon, rang)
	_set_scale(local, echelle.x, echelle.y, echelle.z)
	_set_color(local, Replication.couleur_de(tampon, rang))


## --- Interpolation ---

## Moyenne glissante de l'écart réel entre deux ticks. Lissée, sinon une seule
## arrivée en retard ferait ralentir tous les objets d'un coup.
func _mesurer_intervalle() -> void:
	if temps_depuis_tick <= 0.0:
		return
	intervalle_mesure = lerpf(intervalle_mesure, temps_depuis_tick, 0.1)


func _interpoler(delta: float) -> void:
	temps_depuis_tick += delta
	avancement = minf(temps_depuis_tick / intervalle_mesure, 1.0)

	for id_serveur in arrivee_position:
		if not ids_serveur.has(id_serveur):
			continue
		var local: int = ids_serveur[id_serveur]
		var position := _position_affichee(id_serveur)
		var rotation := _rotation_affichee(id_serveur)
		# Toujours les mêmes fonctions : un objet répliqué se déplace comme
		# n'importe quel autre.
		_set_position(local, position.x, position.y, position.z)
		_set_rotation(local, rotation.x, rotation.y, rotation.z, rotation.w)


func _position_affichee(id_serveur: int) -> Vector3:
	var depart: Vector3 = depart_position[id_serveur]
	return depart.lerp(arrivee_position[id_serveur], avancement)


func _rotation_affichee(id_serveur: int) -> Quaternion:
	var depart: Quaternion = depart_rotation[id_serveur]
	return depart.slerp(arrivee_rotation[id_serveur], avancement)


func _tout_retirer() -> void:
	for id_serveur in ids_serveur.keys():
		_destroy(ids_serveur[id_serveur])
	ids_serveur.clear()
	hashs.clear()
	_vider_interpolation()


## Changer de jeu vide `entities` : la correspondance devient caduque.
func vider() -> void:
	super()
	ids_serveur.clear()
	hashs.clear()
	_vider_interpolation()


func _vider_interpolation() -> void:
	depart_position.clear()
	arrivee_position.clear()
	depart_rotation.clear()
	arrivee_rotation.clear()
	avancement = 1.0
	temps_depuis_tick = 0.0
	intervalle_mesure = INTERVALLE_REPLICATION


## --- interface client ---

func _imports_client() -> Dictionary:
	return {
		"client.input_value": [self, "_input_value"],
	}


## Valeur d'une entrée locale, 0.0..1.0. Toute la logique de sources et de
## remappage est dans `input.gd` ; ici on ne garde que la porte du menu.
func _input_value(code: int) -> float:
	# Menu ouvert : le jeu continue, mais il ne reçoit plus les entrées.
	if menu != null and menu.ouvert:
		return 0.0
	return inputs.value(code)
