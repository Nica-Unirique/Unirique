extends RefCounted

## Sérialisation canonique et hashs de la réplication.
## Spécification : Norms/replication.md
##
## Les 48 octets produits ici sont À LA FOIS ce qu'on transmet et ce qu'on hashe.
## Aucune autre représentation ne fait autorité — surtout pas un état relu depuis
## les nœuds Godot, qui dépendrait de la précision de la build.

const OCTETS_PAR_OBJET := 48

const FNV_BASE := -3750763034362895579   # 0xcbf29ce484222325 en 64 bits signés
const FNV_PREMIER := 1099511628211       # 0x100000001b3


## Encode un objet. L'ordre des champs est celui de la spécification et ne doit
## jamais changer : il est figé par le hash.
static func encoder(
	id: int, position: Vector3, rotation: Quaternion, echelle: Vector3, argb: int
) -> PackedByteArray:
	var octets := PackedByteArray()
	octets.resize(OCTETS_PAR_OBJET)

	octets.encode_u32(0, id)

	octets.encode_float(4, position.x)
	octets.encode_float(8, position.y)
	octets.encode_float(12, position.z)

	octets.encode_float(16, rotation.x)
	octets.encode_float(20, rotation.y)
	octets.encode_float(24, rotation.z)
	octets.encode_float(28, rotation.w)

	octets.encode_float(32, echelle.x)
	octets.encode_float(36, echelle.y)
	octets.encode_float(40, echelle.z)

	octets.encode_u32(44, argb)
	return octets


# --- Lecture d'un objet dans un tampon de plusieurs objets ---

static func id_de(tampon: PackedByteArray, rang: int) -> int:
	return tampon.decode_u32(rang * OCTETS_PAR_OBJET)


static func position_de(tampon: PackedByteArray, rang: int) -> Vector3:
	var base := rang * OCTETS_PAR_OBJET
	return Vector3(
		tampon.decode_float(base + 4),
		tampon.decode_float(base + 8),
		tampon.decode_float(base + 12)
	)


static func rotation_de(tampon: PackedByteArray, rang: int) -> Quaternion:
	var base := rang * OCTETS_PAR_OBJET
	return Quaternion(
		tampon.decode_float(base + 16),
		tampon.decode_float(base + 20),
		tampon.decode_float(base + 24),
		tampon.decode_float(base + 28)
	)


static func echelle_de(tampon: PackedByteArray, rang: int) -> Vector3:
	var base := rang * OCTETS_PAR_OBJET
	return Vector3(
		tampon.decode_float(base + 32),
		tampon.decode_float(base + 36),
		tampon.decode_float(base + 40)
	)


static func couleur_de(tampon: PackedByteArray, rang: int) -> int:
	return tampon.decode_u32(rang * OCTETS_PAR_OBJET + 44)


## Les 48 octets d'un objet, extraits tels quels. C'est eux qu'on hashe.
static func octets_de(tampon: PackedByteArray, rang: int) -> PackedByteArray:
	var base := rang * OCTETS_PAR_OBJET
	return tampon.slice(base, base + OCTETS_PAR_OBJET)


static func nombre_objets(tampon: PackedByteArray) -> int:
	return tampon.size() / OCTETS_PAR_OBJET


# --- Hashs ---

## FNV-1a 64 bits. Les entiers de GDScript débordent en complément à deux, ce qui
## donne exactement les 64 bits de poids faible attendus.
static func fnv1a64(octets: PackedByteArray) -> int:
	var h := FNV_BASE
	for octet in octets:
		h = h ^ octet
		h = h * FNV_PREMIER
	return h


## Hash de la scène = hash des hashs, objets triés par id CROISSANT.
## Le tri n'est pas cosmétique : sans lui, le hash dépendrait de l'ordre
## d'insertion du dictionnaire.
static func hash_scene(hashs: Dictionary) -> int:
	var ids := hashs.keys()
	ids.sort()

	var concatenation := PackedByteArray()
	concatenation.resize(ids.size() * 8)
	var decalage := 0
	for id in ids:
		concatenation.encode_s64(decalage, hashs[id])
		decalage += 8
	return fnv1a64(concatenation)
