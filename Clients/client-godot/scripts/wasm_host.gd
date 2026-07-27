extends Node3D

## Hôte WASM commun au client et au serveur : tout `interface scene` du contrat.
##
## Les deux côtés manipulent la même scène, donc partagent ce code — une seule
## implémentation, impossible qu'elles divergent. Ce qui les distingue (entrées
## locales d'un côté, entrées par joueur de l'autre) est fourni par l'héritier
## via le paramètre `imports` de `charger()`.

## Codes d'entrée du contrat.
const CODE_GAUCHE := 0
const CODE_DROITE := 1
const CODE_HAUT := 2
const CODE_BAS := 3
const CODE_ACTION := 4
const CODE_RETOUR := 5
const CODE_SAUT := 6

var wasm: Wasm = null
var entities := {}
## Mode de réplication par objet : 0 local, 1 serveur->clients, 2 client->serveur.
var sync_modes := {}
## Couleur ARGB telle que le jeu l'a posée. Gardée telle quelle : la relire
## depuis le matériau ferait un aller-retour en float, donc une perte.
var colors := {}
## Un objet est un CORPS (position, rotation) portant un maillage (échelle,
## couleur) et une forme de collision. Les trois sont indexés par le même id.
var mailles := {}
var formes := {}
var next_id := 1


## Charge un module WASM et appelle son `start()`. `imports` complète la table
## des fonctions de `scene` avec celles propres au côté.
##
## Un fichier ABSENT est légal : un jeu peut n'avoir que son client ou que son
## serveur. On tourne alors sans module — la plateforme continue de gérer les
## avatars, la physique et la réplication. Seul un fichier illisible est une
## erreur : là, quelque chose est cassé.
func charger(chemin: String, imports: Dictionary) -> bool:
	vider()

	if not FileAccess.file_exists(chemin):
		print("Aucun module ici : ", chemin)
		return true

	var fichier := FileAccess.open(chemin, FileAccess.READ)
	if fichier == null:
		push_error("WASM illisible : " + chemin)
		return false
	var octets := fichier.get_buffer(fichier.get_length())
	fichier.close()

	var table := _imports_scene()
	table.merge(imports)

	wasm = Wasm.new()
	wasm.load(octets, {"functions": table})
	wasm.function("start", [])
	return true


func mettre_a_jour(dt: float) -> void:
	if wasm != null:
		wasm.function("update", [dt])


func vider() -> void:
	for id in entities.keys():
		var noeud = entities[id]
		if is_instance_valid(noeud):
			noeud.queue_free()
	entities.clear()
	mailles.clear()
	formes.clear()
	sync_modes.clear()
	colors.clear()
	next_id = 1


func _imports_scene() -> Dictionary:
	return {
		"scene.object_spawn":        [self, "_spawn"],
		"scene.object_destroy":      [self, "_destroy"],
		"scene.object_set_position": [self, "_set_position"],
		"scene.object_set_rotation": [self, "_set_rotation"],
		"scene.object_set_scale":    [self, "_set_scale"],
		"scene.object_set_color":    [self, "_set_color"],
		"scene.object_set_sync":     [self, "_set_sync"],
		"scene.log":                 [self, "_log"],

		"scene.object_get_position_x": [self, "_get_position_x"],
		"scene.object_get_position_y": [self, "_get_position_y"],
		"scene.object_get_position_z": [self, "_get_position_z"],
		"scene.object_get_rotation_x": [self, "_get_rotation_x"],
		"scene.object_get_rotation_y": [self, "_get_rotation_y"],
		"scene.object_get_rotation_z": [self, "_get_rotation_z"],
		"scene.object_get_rotation_w": [self, "_get_rotation_w"],
		"scene.object_get_scale_x":    [self, "_get_scale_x"],
		"scene.object_get_scale_y":    [self, "_get_scale_y"],
		"scene.object_get_scale_z":    [self, "_get_scale_z"],
		"scene.object_get_color":      [self, "_get_color"],
	}


# ---------- interface scene ----------

## Tout objet est solide. Le contrat n'a pas de notion de solidité : c'est la
## règle par défaut, et elle évite qu'un jeu ait à y penser.
func _spawn() -> int:
	return creer_objet(StaticBody3D.new())


## Enregistre un corps comme objet de scène et lui attache son maillage et sa
## forme. Le serveur passe un CharacterBody3D pour les avatars — c'est le seul
## endroit où le type de corps diffère.
func creer_objet(corps: Node3D) -> int:
	# Maillage et forme sont dimensionnés par leur propre `size`, jamais par le
	# scale du nœud. Une seule sémantique des deux côtés, et aucune dépendance
	# aux valeurs par défaut de Godot — c'est ce qui les faisait diverger.
	var boite := BoxMesh.new()
	boite.size = Vector3.ONE
	var maille := MeshInstance3D.new()
	maille.mesh = boite
	maille.material_override = StandardMaterial3D.new()
	corps.add_child(maille)

	var pave := BoxShape3D.new()
	pave.size = Vector3.ONE
	var forme := CollisionShape3D.new()
	forme.shape = pave
	corps.add_child(forme)

	add_child(corps)

	var id := next_id
	next_id += 1
	entities[id] = corps
	mailles[id] = maille
	formes[id] = forme
	sync_modes[id] = 0
	colors[id] = 0xFFFFFFFF
	return id


func _destroy(id: int) -> void:
	if not entities.has(id):
		return
	var noeud = entities[id]
	if is_instance_valid(noeud):
		noeud.queue_free()
	entities.erase(id)
	mailles.erase(id)
	formes.erase(id)
	sync_modes.erase(id)
	colors.erase(id)


func _set_position(id: int, x: float, y: float, z: float) -> void:
	if entities.has(id):
		entities[id].position = Vector3(x, y, z)


func _set_rotation(id: int, x: float, y: float, z: float, w: float) -> void:
	if entities.has(id):
		entities[id].quaternion = Quaternion(x, y, z, w)


## L'échelle est la TAILLE du maillage et de la forme, jamais le scale d'un
## nœud : un corps physique redimensionné se comporte mal dans Godot, et deux
## mécanismes différents finiraient toujours par diverger.
func _set_scale(id: int, x: float, y: float, z: float) -> void:
	if not entities.has(id):
		return
	var dimensions := Vector3(x, y, z)
	mailles[id].mesh.size = dimensions
	formes[id].shape.size = dimensions


func _set_color(id: int, argb: int) -> void:
	if not entities.has(id):
		return
	colors[id] = argb
	var a := float((argb >> 24) & 0xFF) / 255.0
	var r := float((argb >> 16) & 0xFF) / 255.0
	var g := float((argb >> 8) & 0xFF) / 255.0
	var b := float(argb & 0xFF) / 255.0
	mailles[id].material_override.albedo_color = Color(r, g, b, a)


func _set_sync(id: int, mode: int) -> void:
	if entities.has(id):
		sync_modes[id] = mode


func _log(valeur: float) -> void:
	print("[jeu] ", valeur)


# ---------- relecture ----------
#
# Sur le SERVEUR, ces valeurs sont autoritaires. Sur le CLIENT, elles sont ce
# qui est AFFICHÉ, donc interpolé et en léger retard. Un objet inconnu rend 0.

func _get_position_x(id: int) -> float:
	return entities[id].position.x if entities.has(id) else 0.0


func _get_position_y(id: int) -> float:
	return entities[id].position.y if entities.has(id) else 0.0


func _get_position_z(id: int) -> float:
	return entities[id].position.z if entities.has(id) else 0.0


func _get_rotation_x(id: int) -> float:
	return entities[id].quaternion.x if entities.has(id) else 0.0


func _get_rotation_y(id: int) -> float:
	return entities[id].quaternion.y if entities.has(id) else 0.0


func _get_rotation_z(id: int) -> float:
	return entities[id].quaternion.z if entities.has(id) else 0.0


## Rend 1.0 par défaut : c'est la rotation identité, la seule valeur neutre.
func _get_rotation_w(id: int) -> float:
	return entities[id].quaternion.w if entities.has(id) else 1.0


func _get_scale_x(id: int) -> float:
	return mailles[id].mesh.size.x if entities.has(id) else 0.0


func _get_scale_y(id: int) -> float:
	return mailles[id].mesh.size.y if entities.has(id) else 0.0


func _get_scale_z(id: int) -> float:
	return mailles[id].mesh.size.z if entities.has(id) else 0.0


func _get_color(id: int) -> int:
	return colors.get(id, 0)
