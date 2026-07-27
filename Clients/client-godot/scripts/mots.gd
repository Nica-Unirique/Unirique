extends RefCounted

## Les 2048 mots BIP39. Extraits de la crate `bip39` elle-même (test
## `extraire_liste_des_mots`), donc forcément identiques à ceux que
## `identity.wasm` valide.
##
## Tout ce fichier est délibérément HORS du WASM : rien n'y demande de primitive
## absente de Godot, et l'autocomplétion réclame la liste côté moteur de toute
## façon. Voir Norms/identity.md §4.

const FICHIER := "res://wordlist.txt"
const NB_MOTS := 24
## 24 mots = 264 bits : 256 d'entropie + 8 de somme de contrôle.
const OCTETS_ENTROPIE := 32
const BITS_PAR_MOT := 11

var mots: PackedStringArray = []
## mot -> rang, pour valider en temps constant plutôt qu'en parcourant 2048 mots.
var rangs := {}


func _init() -> void:
	for mot in FileAccess.get_file_as_string(FICHIER).split("\n", false):
		var propre := mot.strip_edges()
		if propre.is_empty():
			continue
		rangs[propre] = mots.size()
		mots.append(propre)
	if mots.size() != 2048:
		push_error("wordlist.txt : %d mots au lieu de 2048" % mots.size())


func valide(mot: String) -> bool:
	return rangs.has(mot.strip_edges().to_lower())


## Mots commençant par ce préfixe. Saisir 24 mots sans ça est un supplice.
func suggestions(prefixe: String, maximum := 5) -> PackedStringArray:
	var debut := prefixe.strip_edges().to_lower()
	var trouves := PackedStringArray()
	if debut.is_empty():
		return trouves
	for mot in mots:
		if mot.begins_with(debut):
			trouves.append(mot)
			if trouves.size() >= maximum:
				break
	return trouves


## Une phrase de 24 mots. SHA256 suffit ici : c'est pourquoi la génération n'a
## pas besoin du module WASM.
func generer_phrase() -> String:
	return phrase_depuis_entropie(Crypto.new().generate_random_bytes(OCTETS_ENTROPIE))


## Séparé de `generer_phrase` pour être vérifiable avec une entropie connue.
func phrase_depuis_entropie(entropie: PackedByteArray) -> String:
	var hachage := HashingContext.new()
	hachage.start(HashingContext.HASH_SHA256)
	hachage.update(entropie)
	# 256 bits d'entropie donnent 8 bits de contrôle, soit le premier octet.
	var bits := entropie + PackedByteArray([hachage.finish()[0]])

	var choisis := PackedStringArray()
	for rang in NB_MOTS:
		choisis.append(mots[_extraire_bits(bits, rang * BITS_PAR_MOT)])
	return " ".join(choisis)


## Lit BITS_PAR_MOT bits consécutifs à partir de `depart`, poids fort en tête.
func _extraire_bits(octets: PackedByteArray, depart: int) -> int:
	var valeur := 0
	for decalage in BITS_PAR_MOT:
		var position := depart + decalage
		valeur = (valeur << 1) | ((octets[position / 8] >> (7 - position % 8)) & 1)
	return valeur
