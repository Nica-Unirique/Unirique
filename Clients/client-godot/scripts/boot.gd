extends Node

## Point d'entrée unique de l'exécutable. Un seul binaire, deux rôles :
##   sans argument   -> le CLIENT, qui lance lui-même son serveur local
##   avec --server   -> le SERVEUR de jeu, sans fenêtre
##
## Arguments, après `--` :
##   --server           rôle serveur
##   --port=25000       port d'écoute (serveur) ou de connexion (client)
##   --game=res://...   dossier du jeu
##   --join=ADRESSE     rejoindre un serveur existant au lieu d'en lancer un
##
## Le rôle est un ARGUMENT, pas un binaire séparé : héberger pour des amis et
## jouer en solo empruntent donc exactement le même chemin de code.

const SCENE_CLIENT := "res://scenes/main.tscn"
const SCENE_SERVEUR := "res://scenes/server.tscn"

const PORT_DEFAUT := 25000
const JEU_DEFAUT := "./Games/Hub"
## Annuaire de la plateforme : comptes, amis, serveurs publiés. Exposé en HTTPS
## par Tailscale Funnel. `--data=http://127.0.0.1:8080` pour viser le local.
const SERVEUR_DATA_DEFAUT := "https://unirique-data.tail1bbd46.ts.net"


func _ready() -> void:
	var scene := SCENE_SERVEUR if drapeau("server") else SCENE_CLIENT
	# Différé : pendant `_ready`, l'arbre est encore en train d'ajouter cette
	# scène-ci et refuse qu'on la retire dans le même souffle.
	get_tree().change_scene_to_file.call_deferred(scene)


## --- Lecture des arguments, partagée par le client et le serveur ---

## Valeur de `--nom=valeur`, ou `defaut` si absent.
static func argument(nom: String, defaut: String) -> String:
	var prefixe := "--%s=" % nom
	for morceau in OS.get_cmdline_user_args():
		if morceau.begins_with(prefixe):
			return morceau.substr(prefixe.length())
	return defaut


## Présence de `--nom`.
static func drapeau(nom: String) -> bool:
	return OS.get_cmdline_user_args().has("--%s" % nom)


static func port() -> int:
	return int(argument("port", str(PORT_DEFAUT)))


static func jeu() -> String:
	return argument("game", JEU_DEFAUT)


## Sans barre finale : les chemins de routes commencent par « / ».
static func serveur_data() -> String:
	return argument("data", SERVEUR_DATA_DEFAUT).rstrip("/")


## --- Emplacement des jeux ---
##
## Les jeux vivent À CÔTÉ de l'exécutable, pas dans le `.pck` : on ne peut pas
## ajouter un jeu dans un pck à l'exécution, et une plateforme doit pouvoir en
## installer. Ils sont donc désignés en relatif (`./Games/Hub`).

static func racine_jeux() -> String:
	if OS.has_feature("editor"):
		return ProjectSettings.globalize_path("res://")
	return OS.get_executable_path().get_base_dir()


## Chemin absolu d'un jeu désigné en relatif. Un chemin déjà absolu (ou `res://`)
## est rendu tel quel.
static func chemin_jeu(relatif: String) -> String:
	if relatif.begins_with("res://") or relatif.is_absolute_path():
		return relatif
	return racine_jeux().path_join(relatif.trim_prefix("./"))


## Un jeu = un dossier avec `client.wasm`, `server.wasm`, ou les deux. Aucun des
## deux, et ce n'est pas un jeu.
static func est_un_jeu(dossier: String) -> bool:
	return (
		FileAccess.file_exists(dossier.path_join("client.wasm"))
		or FileAccess.file_exists(dossier.path_join("server.wasm"))
	)
