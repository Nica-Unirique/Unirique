# Réplication de la scène — protocole

Le serveur fait autorité sur la scène. À chaque tick il envoie **les modifications
uniquement**, accompagnées d'un **hash** de l'état complet. Le client applique, hashe
de son côté, et ne demande des informations supplémentaires que si les deux hashs
diffèrent.

C'est un arbre de Merkle : détecter une divergence coûte 8 octets, la localiser
coûte un nombre d'échanges qui croît très lentement avec le nombre d'objets.

Conséquence : **le canal n'a pas besoin d'être fiable.** Un paquet perdu produit une
divergence, qui est détectée puis réparée. La vérification remplace la garantie de
livraison, pour bien moins cher.

---

## 1. Sérialisation canonique

Un objet répliqué se réduit à **48 octets**, en little-endian, dans cet ordre exact :

| décalage | champ | type |
|---|---|---|
| 0 | id | u32 |
| 4, 8, 12 | position x, y, z | f32 |
| 16, 20, 24, 28 | rotation x, y, z, w | f32 |
| 32, 36, 40 | échelle x, y, z | f32 |
| 44 | couleur ARGB | u32 |

**Ces octets sont à la fois ce qu'on transmet et ce qu'on hashe.** Aucune autre
représentation ne fait autorité.

Le client hashe donc les octets **tels que reçus**, jamais un état relu depuis les
nœuds Godot. On pourrait croire que relire un `Vector3` est équivalent — ses
composantes sont en 32 bits en interne. C'est vrai aujourd'hui, faux dans une build
double précision, et c'est le genre d'hypothèse qui casse silencieusement des années
plus tard.

C'est le seul piège capable de rendre toute l'architecture inutilisable : deux hashs
qui ne correspondent jamais produisent une réparation en boucle infinie.

## 2. Fonction de hash

**FNV-1a 64 bits.** Cinq lignes, aucune dépendance, identique dans n'importe quel
langage.

```
h = 0xcbf29ce484222325
pour chaque octet b :
    h = h XOR b
    h = h × 0x100000001b3     (modulo 2^64)
```

**Ne jamais utiliser `hash()` de Godot** : sa valeur n'est garantie ni entre versions,
ni entre plateformes. Le jour où un serveur écrit dans un autre langage remplacera le
serveur Godot, les hashs devront correspondre au bit près.

## 3. Les niveaux

```
h(objet) = fnv1a64(ses 48 octets)
h(scène) = fnv1a64( h(o1) || h(o2) || ... )    objets triés par id croissant
```

**Le tri est obligatoire.** Un hash de hashs dépend de l'ordre de ses enfants ; un
dictionnaire qui réordonne suffirait à tout invalider.

Les `h(objet)` sont mis en cache : seuls ceux des objets modifiés sont recalculés.
Reste la recombinaison, en O(n) par tick — négligeable pour des milliers d'objets.

**Niveau intermédiaire, plus tard.** Quand la recombinaison coûtera trop cher, on
insère des paquets (par exemple `id % 64`) : la réparation localise en deux étapes au
lieu d'une, et le recalcul tombe à O(n/64). Rien à décider maintenant — l'ajouter ne
change ni le protocole ni le principe.

## 4. Messages

**Serveur → client**

| message | contenu |
|---|---|
| `TICK` | tick u32, destructions (ids), modifications (48 o. chacune), h(scène) |
| `HASHS` | tick, liste de (id, h(objet)) pour **tous** les objets |
| `COMPLET` | tick, état complet des objets demandés |

**Client → serveur**

| message | contenu |
|---|---|
| `DEMANDE_HASHS` | — |
| `DEMANDE_OBJETS` | liste d'ids |

Un seul canal, non fiable.

## 5. Algorithme du client

```
à la réception de TICK :
    appliquer les destructions
    appliquer les modifications
    si comparaison suspendue et tick <= tick_reprise : sortir
    si h(scène) local == h(scène) reçu : sortir
    si aucune réparation en cours :
        envoyer DEMANDE_HASHS
        réparation_en_cours = vrai

à la réception de HASHS :
    manquants  = ids reçus que je n'ai pas
    en_trop    = mes ids absents de la liste
    différents = ids communs dont le hash diffère
    détruire en_trop
    si (manquants + différents) non vide :
        envoyer DEMANDE_OBJETS(manquants + différents)
    sinon :
        réparation_en_cours = faux

à la réception de COMPLET :
    remplacer l'état de chaque objet reçu
    tick_reprise = tick du message
    réparation_en_cours = faux
```

**Le client n'arrête jamais d'appliquer les `TICK` pendant une réparation.** Le jeu ne
se fige pas.

## 6. Le piège de la fraîcheur

Entre la détection au tick N et l'arrivée de la réponse, le serveur a avancé. La
réponse décrit donc un état **plus récent** que celui qui avait été jugé faux.

Sans précaution, le client corrigerait avec des données qui, comparées à son propre
tick courant, sembleraient encore fausses — et il redemanderait en boucle.

D'où `tick_reprise` : après une réparation, le client **suspend la comparaison**
jusqu'à recevoir un `TICK` postérieur à celui de la réponse. À ce moment seulement,
les deux états décrivent le même instant.

C'est le seul mécanisme non évident du protocole, et sans lui l'ensemble oscille.

## 7. Garantie de convergence

Si trois réparations consécutives échouent, le client demande **tout** — un `COMPLET`
sur l'ensemble des objets.

Sans ce filet, un défaut de sérialisation se traduirait par une tempête de requêtes
plutôt que par un état stable et faux, bien plus difficile à diagnostiquer.

## 8. Arrivée d'un joueur

`COMPLET` avec tous les objets, puis les `TICK` normaux. C'est le seul endroit où un
envoi total garde un sens.

> **Provisoire, en attendant `COMPLET`** : à la connexion d'un joueur, le serveur
> oublie ce qu'il a envoyé, ce qui force le tick suivant à tout réémettre. C'est
> correct mais grossier — le renvoi part à **tous** les clients, pas seulement au
> nouveau venu. Acceptable tant que les connexions sont rares.

## 9. Interpolation à l'affichage

Le serveur envoie 20 fois par seconde, l'écran affiche bien plus souvent. Sans rien,
les objets répliqués avanceraient par saccades.

Le client ne pose donc pas l'état reçu : il en fait une **cible**, et parcourt le
chemin sur la durée d'un intervalle.

**Le départ est la position AFFICHÉE**, pas la cible précédente. Un objet dont le
tick suivant arrive en retard, ou dont la cible change en route, repart d'où il est.
Sinon il reculerait d'un cran à chaque changement de direction.

**Départ = arrivée par défaut.** Comme seules les modifications circulent, un objet
absent du tick garde une cible égale à son départ et reste parfaitement immobile.

**Un objet vu pour la première fois part de sa cible** : il apparaît à sa place au
lieu d'y glisser depuis l'origine.

**L'intervalle est mesuré, pas supposé.** Le client fait une moyenne glissante du
temps réellement écoulé entre deux ticks. Il reste juste si le serveur change de
cadence ou ralentit, et rien ne couple sa constante à celle du serveur. Le lissage
évite qu'un seul paquet en retard ne fasse ralentir tous les objets d'un coup.

**Échelle et couleur ne sont pas interpolées** : elles changent par sauts, les lisser
donnerait un fondu au lieu d'un mouvement.

L'interpolation ne touche que l'affichage. Le hash porte toujours sur les octets
**reçus**, jamais sur la position interpolée — sans quoi il ne correspondrait jamais.

## 10. Coûts

| situation | débit |
|---|---|
| scène immobile | 12 octets par tick, soit **240 o/s** à 20 Hz |
| un objet en mouvement | 48 octets par tick, environ 1 ko/s |
| réparation | deux allers-retours, exceptionnels |

## 11. État

| étape | état |
|---|---|
| 1. Sérialisation canonique | **fait** |
| 2. Modifications seules | **fait** |
| 3. Hash et détection, en journal | **fait** — aucune divergence observée |
| 4. Protocole de réparation | à faire |

L'étape 3 devait dire si les divergences étaient rares ou constantes. Elles sont
**absentes** : la sérialisation est exacte des deux côtés. La réparation peut donc
s'écrire en confiance — elle traitera de vraies pertes de paquets, pas un défaut
d'encodage.

Reste également le message `COMPLET`, qui remplacera le renvoi général décrit en
section 8.

## 12. Ce que le hash ne garantit pas

Il garantit que le client reçoit **fidèlement ce que le serveur envoie**. Pas que le
serveur envoie la vérité.

Un défaut d'encodage côté serveur — lire la mauvaise propriété, oublier une
conversion — produit une scène client visiblement fausse **sans aucune divergence**,
puisque les deux côtés s'accordent parfaitement sur une valeur erronée.

C'est arrivé une fois : les objets ont cessé d'être redimensionnés par le `scale` du
nœud, l'encodeur a continué à le lire, et toutes les tailles seraient parties à 1 en
silence. Le hash n'aurait rien signalé.
