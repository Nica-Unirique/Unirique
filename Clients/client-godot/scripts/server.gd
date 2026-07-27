extends "res://scripts/wasm_host.gd"

## Serveur de jeu : même hôte WASM que le client, sans fenêtre ni affichage.
## Il fait tourner `server.wasm` (world game-server) et fournit `interface server`.
##
## Lancé par le client (qui héberge) ou à la main pour un serveur dédié :
##   unirique --headless --xr-mode off -- --server --port=25000 --game=res://games/hub

## Un jeu = un DOSSIER à côté de l'exécutable. Le serveur y cherche `server.wasm`.
const FICHIER_SERVEUR := "server.wasm"

## Avec `--auto-quit` : s'arrête faute de joueurs. Le client hébergeant le passe,
## pour qu'un plantage du client ne laisse pas un serveur vivre indéfiniment.
## Un serveur dédié, lui, doit rester en écoute même vide : il ne le passe pas.
const DELAI_INACTIVITE := 30.0

const Replication := preload("res://scripts/replication.gd")
const Boot := preload("res://scripts/boot.gd")

## Fréquence d'envoi de la scène aux clients. Le jeu simule à la fréquence
## d'image, la réplication est volontairement plus lente.
const REPLICATION_HZ := 20.0
## Cadence de simulation du serveur. Sans limite il consommerait un cœur entier ;
## c'est SA décision, pas le réglage d'affichage d'un joueur.
const FPS_SERVEUR := 60

## L'avatar appartient à la PLATEFORME, pas au jeu. C'est ici qu'il est créé et
## déplacé, une seule fois, plutôt que réimplémenté par chaque `.wasm`.
const VITESSE := 5.0
const VITESSE_SAUT := 7.0
## Plus forte que la gravité réelle : à l'échelle d'un jeu, 9,8 donne des sauts
## flottants. C'est un réglage de ressenti, pas de physique.
const GRAVITE := 20.0
const TAILLE_JOUEUR := Vector3(0.8, 1.8, 0.8)
const HAUTEUR_APPARITION := 2.0
const COULEURS_JOUEUR := [0xFF3399FF, 0xFF33CC66, 0xFFCC5533, 0xFFCCCC33]
const NB_CODES := 7

## Valeurs d'entrée de chaque joueur : un PackedFloat32Array de NB_CODES, 0.0..1.0.
## La présence d'une clé = un joueur connecté (sert aussi à player_count).
var entrees := {}
## Direction du regard de chaque joueur, en radians autour de l'axe vertical.
var lacets := {}
## Objet de scène qui porte l'avatar de chaque joueur.
var objets_joueur := {}
var prochaine_couleur := 0
var temps_depuis_envoi := 0.0

var auto_quitter := false
var temps_sans_joueur := 0.0

var tick := 0
## Derniers octets envoyés par objet : la référence pour savoir ce qui a changé.
var etat_envoye := {}
## Hash de ces octets, mis en cache pour ne pas tout recalculer chaque tick.
var hashs := {}


func _ready() -> void:
	Engine.max_fps = FPS_SERVEUR
	auto_quitter = Boot.drapeau("auto-quit")

	var port := Boot.port()
	var jeu := Boot.jeu()

	if not _ouvrir_reseau(port):
		return

	var dossier := Boot.chemin_jeu(jeu)
	if not Boot.est_un_jeu(dossier):
		push_error("Pas de jeu dans %s : ni client.wasm ni server.wasm" % jeu)
		return
	if not charger(dossier.path_join(FICHIER_SERVEUR), _imports_server()):
		return
	print("Jeu serveur chargé : ", jeu)


## Tout le serveur tourne en pas FIXE. `move_and_slide` exige le pas physique,
## et un serveur gagne à simuler à cadence constante plutôt qu'à la vitesse de
## la machine qui l'héberge.
func _physics_process(delta: float) -> void:
	_surveiller_inactivite(delta)

	# Les avatars d'abord : le jeu doit lire des positions déjà à jour.
	_deplacer_joueurs(delta)
	mettre_a_jour(delta)

	var intervalle := 1.0 / REPLICATION_HZ
	temps_depuis_envoi += delta
	if temps_depuis_envoi < intervalle:
		return
	# On RETRANCHE l'intervalle au lieu de remettre à zéro : sinon on jetterait
	# le dépassement à chaque fois, et la cadence réelle dériverait vers la
	# durée d'image supérieure. C'est ce qui faisait saccader l'interpolation.
	temps_depuis_envoi -= intervalle
	if temps_depuis_envoi > intervalle:
		temps_depuis_envoi = 0.0  # gros retard : on repart proprement
	_envoyer_scene()


## N'envoie que ce qui a changé depuis le dernier tick, plus le hash de la scène
## entière. Un objet immobile ne coûte donc rien. Voir Norms/replication.md.
func _envoyer_scene() -> void:
	if entrees.is_empty():
		return  # personne de connecté

	tick += 1
	var modifications := PackedByteArray()
	var presents := {}

	for id in entities:
		if sync_modes.get(id, 0) != 1:
			continue
		presents[id] = true
		var octets := _encoder(id)
		if etat_envoye.get(id, PackedByteArray()) == octets:
			continue
		etat_envoye[id] = octets
		hashs[id] = Replication.fnv1a64(octets)
		modifications.append_array(octets)

	var destructions := _recenser_destructions(presents)
	rpc("recevoir_tick", tick, destructions, modifications, Replication.hash_scene(hashs))


func _encoder(id: int) -> PackedByteArray:
	var noeud: Node3D = entities[id]
	# La taille vient du maillage, pas du scale du nœud, qui vaut toujours 1.
	return Replication.encoder(
		id, noeud.position, noeud.quaternion, mailles[id].mesh.size,
		colors.get(id, 0xFFFFFFFF)
	)


## Les objets qu'on envoyait et qui n'existent plus. Les oublier ici aussi, sinon
## on les redéclarerait détruits à chaque tick.
func _recenser_destructions(presents: Dictionary) -> PackedInt64Array:
	var destructions := PackedInt64Array()
	for id in etat_envoye.keys():
		if presents.has(id):
			continue
		destructions.append(id)
		etat_envoye.erase(id)
		hashs.erase(id)
	return destructions


## Reçue par les clients uniquement. Déclarée ici pour apparier le RPC.
@rpc("authority", "unreliable_ordered")
func recevoir_tick(
	_tick: int, _destructions: PackedInt64Array, _modifications: PackedByteArray, _hash: int
) -> void:
	pass


## --- Réseau ---

## Filet contre les serveurs fantômes : un client qui plante ne tue pas son
## serveur, qui vivrait alors indéfiniment en tenant son port. Le compteur court
## aussi avant la première connexion, donc un serveur lancé pour rien s'éteint.
func _surveiller_inactivite(delta: float) -> void:
	if not auto_quitter:
		return
	if not entrees.is_empty():
		temps_sans_joueur = 0.0
		return
	temps_sans_joueur += delta
	if temps_sans_joueur >= DELAI_INACTIVITE:
		print("Aucun joueur depuis %d s : arrêt du serveur." % DELAI_INACTIVITE)
		get_tree().quit()


## Le port est choisi par qui nous lance : il l'a sondé libre avant. Échouer ici
## est donc une vraie anomalie, pas une course à absorber.
func _ouvrir_reseau(port: int) -> bool:
	var pair := ENetMultiplayerPeer.new()
	var erreur := pair.create_server(port)
	if erreur != OK:
		push_error("Port %d indisponible (erreur %d)" % [port, erreur])
		get_tree().quit(1)
		return false

	multiplayer.multiplayer_peer = pair
	multiplayer.peer_connected.connect(_joueur_arrive)
	multiplayer.peer_disconnected.connect(_joueur_part)
	print("Serveur en écoute sur le port ", port)
	return true


func _joueur_arrive(id: int) -> void:
	var vide := PackedFloat32Array()
	vide.resize(NB_CODES)
	entrees[id] = vide
	objets_joueur[id] = _creer_avatar()
	print("Joueur connecté : ", id, " — avatar ", objets_joueur[id])

	# Provisoire, en attendant le message COMPLET : oublier ce qu'on a envoyé
	# force le prochain tick à tout réémettre, sinon le nouveau venu ne recevrait
	# que les objets qui bougent et ignorerait tout le reste.
	etat_envoye.clear()

	# Le client doit savoir lequel des avatars est le sien, pour y accrocher sa
	# caméra. Information de plateforme : elle ne passe pas par le contrat.
	rpc_id(id, "recevoir_avatar", objets_joueur[id])

	if wasm != null:
		wasm.function("player_join", [id, objets_joueur[id]])


func _joueur_part(id: int) -> void:
	var objet: int = objets_joueur.get(id, 0)
	print("Joueur déconnecté : ", id)

	# Prévenir AVANT de détruire : pendant `player_leave`, le jeu doit encore
	# pouvoir lire l'objet. L'inverse lui donnerait un identifiant mort.
	if wasm != null:
		wasm.function("player_leave", [id, objet])

	if objet != 0:
		_destroy(objet)
	entrees.erase(id)
	lacets.erase(id)
	objets_joueur.erase(id)


## --- Avatar ---

## Seul objet de la scène qui n'est pas statique : il se déplace, donc il glisse
## le long des obstacles au lieu de s'y planter.
func _creer_avatar() -> int:
	var objet := creer_objet(CharacterBody3D.new())
	_set_scale(objet, TAILLE_JOUEUR.x, TAILLE_JOUEUR.y, TAILLE_JOUEUR.z)
	_set_color(objet, COULEURS_JOUEUR[prochaine_couleur % COULEURS_JOUEUR.size()])
	# On apparaît en l'air : la gravité pose l'avatar sur le sol, quelle que
	# soit la hauteur à laquelle le jeu l'a construit.
	_set_position(objet, 0.0, HAUTEUR_APPARITION, 4.0)
	_set_sync(objet, 1)  # autorité serveur
	prochaine_couleur += 1
	return objet


func _deplacer_joueurs(delta: float) -> void:
	for joueur in objets_joueur:
		_deplacer_joueur(joueur, delta)


func _deplacer_joueur(joueur: int, delta: float) -> void:
	var corps: CharacterBody3D = entities[objets_joueur[joueur]]

	# L'avatar fait face au regard du joueur. La rotation est répliquée, donc
	# les autres te voient te tourner.
	corps.quaternion = Quaternion(Vector3.UP, lacets.get(joueur, 0.0))

	# Déplacement relatif au REGARD : la direction voulue est tournée par
	# l'orientation de l'avatar.
	# `limit_length` et non `normalize` : une entrée analogique à mi-course garde
	# sa magnitude (marche lente), la diagonale reste plafonnée à 1.
	var voulu := _direction_voulue(joueur).limit_length(1.0)
	var direction := corps.quaternion * voulu

	corps.velocity.x = direction.x * VITESSE
	corps.velocity.z = direction.z * VITESSE
	corps.velocity.y = _vitesse_verticale(joueur, corps, delta)
	corps.move_and_slide()


func _vitesse_verticale(joueur: int, corps: CharacterBody3D, delta: float) -> float:
	if not corps.is_on_floor():
		return corps.velocity.y - GRAVITE * delta
	if _input_value(joueur, CODE_SAUT) >= 0.5:
		return VITESSE_SAUT
	# Au sol sans saut : une petite vitesse vers le bas, sinon `is_on_floor`
	# devient faux dès la première pente et l'avatar sautille.
	return -1.0


## Direction demandée, dans le repère de l'avatar. Chaque axe est la différence
## des deux entrées opposées : analogique par construction dès que les valeurs
## cessent d'être 0/1.
func _direction_voulue(joueur: int) -> Vector3:
	var voulu := Vector3.ZERO
	voulu.x = _input_value(joueur, CODE_DROITE) - _input_value(joueur, CODE_GAUCHE)
	voulu.z = _input_value(joueur, CODE_BAS) - _input_value(joueur, CODE_HAUT)
	return voulu


## Appelé par chaque client à chaque image. Non fiable : une entrée perdue est
## remplacée par la suivante quelques millisecondes plus tard.
##
## Le lacet accompagne les touches parce qu'il EST une entrée : c'est la
## direction du regard, et le déplacement en dépend.
@rpc("any_peer", "unreliable_ordered")
func recevoir_entrees(valeurs: PackedFloat32Array, lacet: float) -> void:
	var id := multiplayer.get_remote_sender_id()
	if not entrees.has(id):
		return
	# Un client malveillant pourrait envoyer une taille inattendue : on ne garde
	# que si le compte est bon, sinon on ignore ce paquet.
	if valeurs.size() == NB_CODES:
		entrees[id] = valeurs
	lacets[id] = lacet


## Envoyée aux clients uniquement. Déclarée ici pour apparier le RPC.
@rpc("authority", "reliable")
func recevoir_avatar(_objet: int) -> void:
	pass


## --- interface server ---

func _imports_server() -> Dictionary:
	return {
		"server.input_value":   [self, "_input_value"],
		"server.player_count":  [self, "_player_count"],
	}


## Valeur d'une entrée d'un joueur, 0.0..1.0, telle que le client l'a envoyée —
## analogique comprise. L'autorité fait confiance au client pour ses entrées,
## pas pour sa position : c'est le serveur qui applique le déplacement.
func _input_value(player: int, code: int) -> float:
	var valeurs: PackedFloat32Array = entrees.get(player, PackedFloat32Array())
	if code < 0 or code >= valeurs.size():
		return 0.0
	return valeurs[code]


func _player_count() -> int:
	return entrees.size()
