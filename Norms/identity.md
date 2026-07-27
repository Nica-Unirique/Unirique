# Identité Unirique — norme

L'identité est **décentralisée** : une phrase secrète de 24 mots BIP39 est le seul
secret. Elle dérive une paire de clés Ed25519 ; la clé publique **est** le compte.
Il n'y a **aucun mot de passe**, et le serveur ne détient rien qui permette de se
faire passer pour un utilisateur.

**Ce document fait foi.** L'implémentation WASM (`Norms/identity/Rust/`) n'en est
qu'une commodité, destinée aux moteurs dépourvus de primitives cryptographiques —
Godot n'a ni SHA512 ni Ed25519. Un moteur qui en dispose (C#, C++, JS) implémente
directement cette norme et ignore le module.

---

## 1. Dérivation

**Figée. Ne doit jamais changer** : en changer rendrait irrécupérable tout compte
existant.

```
phrase (24 mots, anglais)
  --PBKDF2-HMAC-SHA512, 2048 tours, sel "mnemonic" + mot de passe VIDE-->
graine (64 octets)
  --graine[0..32]-->
clé privée Ed25519 (32 octets)
  --Ed25519-->
clé publique (32 octets), transmise en hexadécimal minuscule
```

Deux points méritent d'être explicités :

**Le mot de passe BIP39 est vide.** La phrase seule constitue l'identité.

**`graine[0..32]` est un choix maison**, ce n'est pas SLIP-0010. C'est
cryptographiquement sain — 32 octets de sortie PBKDF2 forment une graine Ed25519
uniforme, et 24 mots portent 256 bits d'entropie là où la courbe n'en exploite
que ~128. La contrepartie est l'absence d'interopérabilité : aucun portefeuille
tiers ne retrouvera cette clé depuis la phrase. C'est assumé.

Les 32 octets restants de la graine sont **jetés**. Ils serviraient de *chain
code* dans BIP32 pour dériver plusieurs clés ; Unirique n'en a besoin que d'une.

## 2. Connexion (défi-signature)

```
1. POST /auth/challenge  { cle_publique }        -> { defi }   defi = nonce HEXA
2. le client DÉCODE le defi depuis l'hexadécimal
3. il signe les OCTETS DÉCODÉS
4. POST /auth/login      { cle_publique, signature }  -> { token, userid }
```

**L'étape 2 est le piège.** Le serveur vérifie la signature sur
`hex::decode(nonce)`, pas sur la chaîne hexadécimale. Signer le texte du défi
produit une signature valide en apparence, systématiquement rejetée en 401.

La signature circule en hexadécimal minuscule (128 caractères, 64 octets).

## 3. Vecteurs de test

Toute réimplémentation doit reproduire ces valeurs **exactement**. Sinon elle
n'ouvrira pas les mêmes comptes.

**Phrase de référence** (entropie 256 bits à zéro, vecteur officiel BIP39) :

```
abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon
abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon
abandon abandon abandon art
```

| étape | valeur attendue |
|---|---|
| graine (64 o.) | `408b285c123836004f4b8842c89324c1f01382450c0d439af345ba7fc49acf70` `5489c6fc77dbd4e3dc1dd8cc6bc9f043db8ada1e243c4a0eafb290d399480840` |
| clé privée | les 32 premiers octets ci-dessus |
| **clé publique** | `1de352e44cd333672593f2334a730e180aaf290de89aa16d480de594e34e2961` |

**Contrôle indépendant** — même entropie sur 128 bits, 12 mots
(`abandon …  about`), graine attendue :

```
5eb00bbddcf069084889a8ab9155568165f5c453ccb85e70811aaed6f6da5fc1
9a5ac40b389cd370d086206dec8aa6c43daea6690f20ad3d8d48b2d2ce9e38e4
```

Ce second vecteur valide l'implémentation PBKDF2 contre une référence
**distincte** de celle qu'on verrouille. S'il passe, le premier est fiable.

## 4. Ce qui n'est pas dans le module WASM

Volontairement laissé au moteur, parce qu'aucune primitive cryptographique
absente n'y est requise :

| | pourquoi côté moteur |
|---|---|
| liste des 2048 mots | nécessaire de toute façon pour l'**autocomplétion** de la saisie |
| validation d'un mot | simple recherche dans cette liste |
| génération d'une phrase | SHA256 (disponible partout) + découpage en groupes de 11 bits |

Une génération bâclée ne peut pas passer inaperçue : le checksum sera faux et
`public_key` rejettera la phrase dès la création du compte.

## 5. ABI du module WASM

`Norms/identity/Rust/` → `identity.wasm`. **Sans état, sans aucun import** :
n'importe quel moteur le charge sans rien câbler.

Aucun allocateur : deux tampons statiques de taille fixe, dont l'hôte lit
l'adresse une fois pour toutes.

| export | rôle |
|---|---|
| `input_ptr() -> i32` | adresse du tampon d'entrée |
| `output_ptr() -> i32` | adresse du tampon de sortie |
| `input_size() -> i32` | capacité du tampon d'entrée (1024) |
| `public_key(phrase_len) -> i32` | longueur écrite en sortie, ou `-1` |
| `sign(phrase_len, message_len) -> i32` | longueur écrite en sortie, ou `-1` |

Protocole d'appel :

1. écrire les octets à `input_ptr()` — pour `sign`, la phrase **puis** le message
2. appeler la fonction avec les longueurs
3. lire la réponse à `output_ptr()`, sur la longueur renvoyée

La phrase est en UTF-8 ; le message de `sign` est **brut** (défi déjà décodé).
`-1` signale une phrase invalide, des longueurs hors bornes, ou une sortie trop
grande.

## 6. Stockage local

`compte.json` : `phrase`, `userid`, `token`. **En clair pour la bêta** — c'est
une dette assumée, à chiffrer avant toute ouverture au public.

Perdre la phrase, c'est perdre le compte : personne ne peut la régénérer.
