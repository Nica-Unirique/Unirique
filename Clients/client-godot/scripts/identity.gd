extends RefCounted

## Accès au module de crypto `identity.wasm`. Norme : Norms/identity.md
##
## Godot n'a ni SHA512 ni Ed25519 : la dérivation passe donc par un module WASM,
## sans état et sans aucun import. Ce fichier n'est que la plomberie de son ABI —
## pas d'allocateur, deux tampons statiques dont on lit l'adresse une fois.

const FICHIER := "res://identity.wasm"

var wasm: Wasm
var memoire: WasmMemory
var entree := 0
var sortie := 0
var capacite := 0
var pret := false


func _init() -> void:
	var fichier := FileAccess.open(FICHIER, FileAccess.READ)
	if fichier == null:
		push_error("identity.wasm introuvable")
		return
	var octets := fichier.get_buffer(fichier.get_length())
	fichier.close()

	wasm = Wasm.new()
	if wasm.load(octets, {}) != OK:
		push_error("identity.wasm illisible")
		return

	memoire = wasm.get_memory()
	entree = wasm.function("input_ptr", [])
	sortie = wasm.function("output_ptr", [])
	capacite = wasm.function("input_size", [])
	pret = true


## Clé publique en hexadécimal (64 caractères), ou "" si la phrase est invalide.
func public_key(phrase: String) -> String:
	var octets := phrase.to_utf8_buffer()
	if not _ecrire(octets):
		return ""
	return _lire(wasm.function("public_key", [octets.size()]))


## Signature en hexadécimal (128 caractères) du message BRUT, ou "".
## Le défi du serveur arrive en hexadécimal : le DÉCODER avant d'appeler ici,
## c'est sur les octets décodés que porte la vérification (Norms/identity.md §2).
func sign(phrase: String, message: PackedByteArray) -> String:
	var octets := phrase.to_utf8_buffer()
	if not _ecrire(octets + message):
		return ""
	return _lire(wasm.function("sign", [octets.size(), message.size()]))


func _ecrire(octets: PackedByteArray) -> bool:
	if not pret:
		return false
	if octets.size() > capacite:
		push_error("identity.wasm : entrée de %d octets, capacité %d" % [
			octets.size(), capacite
		])
		return false
	memoire.seek(entree)
	memoire.put_data(octets)
	return true


func _lire(longueur: int) -> String:
	if longueur <= 0:
		return ""  # le module signale une phrase invalide par -1
	memoire.seek(sortie)
	var lu: Array = memoire.get_data(longueur)
	return (lu[1] as PackedByteArray).get_string_from_utf8()
