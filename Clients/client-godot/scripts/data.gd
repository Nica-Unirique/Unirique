extends Node

## Client HTTP du serveur data : le SEUL endroit qui connaisse son adresse et la
## forme de ses réponses. Contrat des routes : Norms/api_routes.csv
##
## Le serveur data est l'annuaire de la plateforme (comptes, amis, serveurs
## publiés). Il n'héberge aucune partie : les serveurs de jeu restent chez les
## joueurs. Il peut donc être injoignable sans empêcher de jouer en local.

const Boot := preload("res://scripts/boot.gd")

## Version d'API que ce client sait parler, comparée à celle de `/version`.
const VERSION_API := "1.0"
## Court : un serveur data muet ne doit pas figer le démarrage du client.
const DELAI_SECONDES := 5.0

## Émis après chaque vérification. `compatible` est faux si le serveur répond
## mais dans une version d'API que nous ne savons pas parler.
signal verifie(joignable: bool, compatible: bool)

var adresse := ""
var joignable := false
var compatible := false
var version_serveur := ""


func _ready() -> void:
	adresse = Boot.serveur_data()


## Interroge `/health` puis `/version`. Le résultat vit dans `joignable`,
## `compatible` et `version_serveur`.
func verifier() -> void:
	var sante := await get_json("/health")
	joignable = sante["ok"]
	if not joignable:
		compatible = false
		print("[data] injoignable : ", adresse)
		verifie.emit(false, false)
		return

	var version := await get_json("/version")
	version_serveur = version["json"].get("version", "")
	compatible = version_serveur == VERSION_API
	if compatible:
		print("[data] joignable : ", adresse, " (API ", version_serveur, ")")
	else:
		# On ne bloque pas : certaines routes resteront utilisables. Mais il faut
		# le savoir, sinon les erreurs suivantes seraient incompréhensibles.
		push_warning("[data] API %s côté serveur, %s attendue" % [
			version_serveur, VERSION_API
		])
	verifie.emit(true, compatible)


## GET d'une route JSON. `token` non vide authentifie la requête.
func get_json(chemin: String, token := "") -> Dictionary:
	return await _appel(HTTPClient.METHOD_GET, chemin, "", token)


## POST JSON. `token` non vide authentifie la requête.
func post_json(chemin: String, corps: Dictionary, token := "") -> Dictionary:
	return await _appel(HTTPClient.METHOD_POST, chemin, JSON.stringify(corps), token)


## Renvoie toujours la même forme :
##   ok    : le serveur a répondu avec un code 2xx et du JSON lisible
##   code  : code HTTP, 0 si le serveur n'a pas répondu du tout
##   json  : le corps décodé, vide si `ok` est faux
##
## Les erreurs du serveur data arrivent sous la forme { "erreur": "..." } : le
## corps reste donc lisible même quand `ok` est faux.
func _appel(methode: int, chemin: String, corps: String, token: String) -> Dictionary:
	# Un HTTPRequest par appel : le nœud n'en gère qu'un à la fois, et le
	# partager créerait des collisions dès qu'on enchaîne les requêtes.
	var requete := HTTPRequest.new()
	requete.timeout = DELAI_SECONDES
	add_child(requete)

	var entetes := PackedStringArray(["Content-Type: application/json"])
	if not token.is_empty():
		entetes.append("Authorization: Bearer " + token)

	var echec := {"ok": false, "code": 0, "json": {}}
	if requete.request(adresse + chemin, entetes, methode, corps) != OK:
		requete.queue_free()
		return echec

	var reponse: Array = await requete.request_completed
	requete.queue_free()

	# reponse = [result, code, en-têtes, corps]
	if reponse[0] != HTTPRequest.RESULT_SUCCESS:
		return echec

	var code: int = reponse[1]
	var decode = JSON.parse_string((reponse[3] as PackedByteArray).get_string_from_utf8())
	if typeof(decode) != TYPE_DICTIONARY:
		return {"ok": false, "code": code, "json": {}}
	return {"ok": code >= 200 and code < 300, "code": code, "json": decode}
