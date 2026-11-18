# Deduplicate pour Lightroom Classic

*[English version](README.en.md)*

Module externe pour **Lightroom Classic** (Windows) qui retrouve les photos et vidéos importées plusieurs fois,
les fusionne sans rien perdre de leur classement, et allège les rafales en ne gardant que les meilleurs cadres.

Le module ne supprime jamais de fichier. Les copies écartées sont rassemblées dans une collection
« Doublons à retirer » : c'est vous qui décidez de les retirer du catalogue.

## Ce qu'il fait

- **Trouve les doublons** même renommés ou redatés : empreinte du contenu (les métadonnées réécrites par Lightroom
  ou un autre logiciel sont ignorées), puis comparaison par miniature des copies réduites, recompressées ou tournées.
- **Choisit la copie à garder** : la plus grande image, puis celle qui est retouchée dans Lightroom, puis la mieux
  rangée (les mots qui désignent un dossier mal rangé sont réglables).
- **Réunit tout sur la copie gardée** : collections, mots-clés, note, drapeau, position GPS, titre, légende… Les copies
  virtuelles des copies écartées sont recréées sur elle lors d'une fusion forcée.
- **Montre un rapport HTML avant toute modification** : miniatures, copie gardée et pourquoi, ce qui change dans chaque
  collection. Vous pouvez écarter un groupe, ou en forcer un autre en choisissant la copie à garder.
- **Réduit les rafales** : garde le cadre le plus net de chaque bloc, et protège toujours les photos notées, marquées,
  retouchées, publiées ou rangées dans un album.
- **Vidéos** : copies strictement identiques fusionnées automatiquement ; versions converties ou recoupées
  fusionnables à la main.

## Sécurité

- Rien n'est modifié avant votre confirmation, et le rapport décrit exactement le plan qui sera appliqué.
- Les fichiers sont relus juste avant la fusion : si l'un a changé depuis l'analyse, rien n'est fait.
- Une sauvegarde des collections est écrite et vérifiée avant chaque fusion ; une commande permet de les restaurer.
- Chaque fusion ou réduction est **une seule action Lightroom** : Ctrl+Z l'annule entièrement.
- Le catalogue est lu en lecture seule par Python ; toutes les modifications passent par le SDK Lightroom.

Comme pour tout outil qui touche un catalogue, faites une sauvegarde du catalogue avant la première utilisation.

## Prérequis

- Lightroom Classic sous **Windows** (développé et testé avec Lightroom Classic 15).
- **Python 3.12 ou plus récent** ([python.org](https://www.python.org/downloads/), installation par défaut) : indispensable.
- **ImageMagick 7** : recommandé (comparaison des images de tailles différentes, netteté des rafales, miniatures du rapport).
- **ffmpeg** : facultatif (aperçus des vidéos dans le rapport).

## Installation

1. Téléchargez la dernière version dans [Releases](../../releases) et décompressez-la.
2. Dans Lightroom Classic : **Fichier → Gestionnaire de modules externes → Ajouter**, puis choisissez le dossier
   `lightroom-deduplicate.lrplugin`.
3. Les commandes apparaissent dans **Bibliothèque → Options du module externe**.

La langue de l'interface (français par défaut, ou anglais) se choisit dans **Fichier → Gestionnaire de modules
externes → Deduplicate**.

Le module écrit ses rapports, sauvegardes et journaux à côté du dossier `lightroom-deduplicate.lrplugin` : placez-le
dans un dossier où vous avez le droit d'écrire.

## Premiers pas

1. Ouvrez un dossier ou une collection (ou sélectionnez quelques photos), puis lancez
   **Rechercher les doublons pour fusion…**.
2. Cliquez sur **Ouvrir le rapport** et parcourez les groupes. Cochez « Ne pas fusionner » ou « Fusionner de force » si
   besoin, puis **Copier le code** et collez-le dans Lightroom.
3. Confirmez. Les copies écartées sont dans « Doublons à retirer » ; pour les retirer vraiment, sélectionnez-les dans
   **Catalogue → Toutes les photos**, puis **Suppr → Retirer**.

Le [mode d'emploi complet](lightroom-deduplicate.lrplugin/LISEZ-MOI.md) détaille chaque commande, les règles de
choix, les copies virtuelles, les sauvegardes et la restauration.

## Limites

- Windows uniquement : ImageMagick, ffmpeg et Python sont cherchés à leurs emplacements Windows.
- Interface en français ou en anglais (réglage du module) ; les titres du menu suivent la langue de Lightroom.
- Une copie n'est trouvée que si ses doublons font partie des photos analysées (sélection ou vue courante).

## Module voisin facultatif

Si le module [Albums Google Photos](https://github.com/mtthth/lightroom-google-photos) est installé dans le dossier
voisin `lightroom-google-photos`, les deux partagent l'historique des photos écartées : Google Photos ne propose plus
au téléchargement les photos déjà retirées par Deduplicate.

## Tests

```powershell
node tests/lancer.mjs
```

Les 21 suites Lua et 3 suites Python tournent hors de Lightroom, sur des données synthétiques, avec Node 22+,
Lua 5.3 (`texlua` de MiKTeX ou `lua`) et Python 3.12+. Les variables `LUA` et `PYTHON` permettent de choisir les
exécutables. Elles tournent aussi sur GitHub à chaque envoi (`.github/workflows/tests.yml`).

## Licence

[MIT](LICENSE). Les évolutions sont décrites dans le [journal des versions](CHANGELOG.md).
