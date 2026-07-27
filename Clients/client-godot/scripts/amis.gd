extends RefCounted

## Routes « amis » du serveur data. Isole leurs noms : le menu demande
## « accepte cette demande », pas « POST /friends/accept ».
## Contrat : Norms/api_routes.csv, sections amis et profil.

const Data := preload("res://scripts/data.gd")
const Compte := preload("res://scripts/compte.gd")

var data: Data
var compte: Compte


func _init(un_data: Data, un_compte: Compte) -> void:
	data = un_data
	compte = un_compte


## --- Lectures. Renvoient un tableau, vide si l'appel échoue. ---

## [{userid, pseudo, en_ligne?, serveur?}]
## `en_ligne` est ABSENT — pas faux — quand l'ami ne partage pas son statut.
## Les confondre reviendrait à mentir sur sa vie privée.
func liste() -> Array:
	return await _tableau("/friends", "amis")


func recues() -> Array:
	return await _liste_demandes("recues")


func envoyees() -> Array:
	return await _liste_demandes("envoyees")


func bloques() -> Array:
	return await _tableau("/users/blocked", "bloques")


func rechercher(motif: String) -> Array:
	return await _tableau("/users/search?q=" + motif.uri_encode(), "resultats")


## Adresses d'un serveur, de la meilleure à la pire, ou vide si l'annuaire
## refuse de les donner. Il ne liste que les serveurs qu'on a le DROIT de
## rejoindre : un identifiant connu mais absent d'ici veut dire que sa politique
## nous exclut.
func adresses_du_serveur(serveur_id: String) -> Array:
	for serveur in await _tableau("/servers", "serveurs"):
		if serveur.get("serveur_id", "") == serveur_id:
			return serveur.get("adresses", [])
	return []


## --- Actions. Renvoient "" en cas de succès, sinon le message d'erreur. ---

func demander(userid: String) -> String:
	return await _action("/friends/request", userid)


func accepter(userid: String) -> String:
	return await _action("/friends/accept", userid)


func refuser(userid: String) -> String:
	return await _action("/friends/refuse", userid)


func annuler(userid: String) -> String:
	return await _action("/friends/cancel", userid)


func retirer(userid: String) -> String:
	return await _action("/friends/remove", userid)


func bloquer(userid: String) -> String:
	return await _action("/users/block", userid)


func debloquer(userid: String) -> String:
	return await _action("/users/unblock", userid)


## --- Interne ---

## Les deux listes de demandes viennent de la même route : un seul appel serait
## préférable, mais l'appeler deux fois reste plus simple que de porter un cache.
func _liste_demandes(champ: String) -> Array:
	return await _tableau("/friends/requests", champ)


func _tableau(chemin: String, champ: String) -> Array:
	var reponse: Dictionary = await data.get_json(chemin, compte.token)
	if not reponse["ok"]:
		return []
	return reponse["json"].get(champ, [])


func _action(chemin: String, userid: String) -> String:
	var reponse: Dictionary = await data.post_json(
		chemin, {"userid": userid}, compte.token
	)
	if reponse["ok"]:
		return ""
	var precis: String = reponse["json"].get("erreur", "")
	return precis if not precis.is_empty() else "échec de l'opération"
