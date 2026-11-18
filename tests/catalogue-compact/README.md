# Catalogue compact de recherche de bugs

Ce générateur fabrique 168 médias synthétiques et 40 scénarios : 22 de doublons,
4 de vidéos, 10 de rafales et 4 de manipulation/erreur. Aucune photo personnelle
n'est utilisée. Il nécessite Python, Pillow, NumPy et FFmpeg.

```powershell
python tests/catalogue-compact/generer.py
python tests/catalogue-compact/preparer_environnement.py
```

Les résultats sont dans `sortie/catalogue-compact/`, ignoré par Git. La génération
refuse d'écraser un manifeste existant. Le catalogue est créé dans Lightroom via
**Fichier > Nouveau catalogue**, sous
`sortie/catalogue-compact/Deduplicate-compact/Deduplicate-compact.lrcat`.
Il n'est jamais construit ou modifié directement en SQLite.

Avant de changer de catalogue, désactiver les modules habituels Deduplicate et
Albums Google Photos, qui partagent un historique externe au catalogue. Ajouter
`preparation.lrplugin` et la copie de Deduplicate située sous `environnement/`.
Le module de préparation démarre au prochain lancement de Lightroom. Il importe
les médias via le SDK, applique les états du manifeste et crée les collections,
les mots-clés, les retouches et les copies virtuelles. Ses écritures sont bornées
au chemin exact du catalogue de test. Les commandes de la copie de Deduplicate
sont également protégées par ce contrôle de catalogue.

Le fichier `commande.txt` accepte uniquement `initialiser`, `verifier`, `manquant`,
`modifier`, `restaurer` et `actualiser` (réappliquer les états des copies virtuelles).
Le résultat est écrit dans `resultat-commande.txt` ; le
journal détaille les imports et les copies virtuelles. Une initialisation interrompue
peut être relancée : les étapes déjà enregistrées dans le catalogue sont reconnues.

Les commandes TEST du menu Lightroom rendent E01 manquant, modifient l'EXIF de E02
à taille identique, et restaurent leurs fichiers depuis les copies `.initial`.
Les données de production et le code du module habituel ne sont pas modifiés.

Les collections de scénarios sont sous un parent contenant « Sessions », pour ne
pas protéger toutes les photos des rafales. Les collections servant explicitement
de protection sont séparées. Les attentes et les séquences de test sont dans
`LIRE-MOI.md`, avec le manifeste JSON/Lua et les empreintes SHA-256 des fichiers.
Les gros MP4 sont valides et contiennent une boîte `free` de remplissage ; V04 ne
diffère qu'au centre de cette boîte. Les DNG sont des RAW linéaires RGB synthétiques.

La création du catalogue ne constitue pas une exécution des tests de fusion.
Les publications et les masques IA ne sont pas préconfigurés.

Après préparation, `python tests/catalogue-compact/auditer.py` contrôle les médias
et les états du catalogue en lecture seule et écrit `verification.json`.
Après fermeture de Lightroom, `python tests/catalogue-compact/sauvegarder_initial.py`
conserve une copie vérifiée du catalogue et de ses données dans `etat-initial/`.
Cette sauvegarde inclut son inventaire SHA-256 et les instructions de restauration.

La campagne réelle du 7 novembre 2026 utilise Lightroom Classic 15.6. Elle travaille
dans `execution/Deduplicate-execution.lrcat`, copié depuis `etat-initial/` par
`creer_travail.py`. Ne pas relancer les scripts de génération ou de préparation
sur cette campagne : ils ne servent pas à remettre à zéro un catalogue déjà testé.

`Campagne.lua`, chargé dans la copie isolée de Deduplicate, exécute les vraies
commandes avec les vrais fichiers et le SDK Lightroom. Seules les réponses aux
dialogues sont pilotées. Les requêtes et les états avant/après sont conservés sous
`campagne/`. Les snapshots ne changent ni les sources actives ni la sélection.
Pour la restauration, `RestaurerTest.lua` coche les groupes explicitement choisis
et exécute la vraie commande. Le pilote refuse tout autre catalogue que celui
de travail. Annuler et rétablir ont été déclenchés par les menus natifs.

```powershell
python tests/catalogue-compact/piloter.py identifiant-unique FusionnerDoublons --cas D05
python tests/catalogue-compact/bilan.py
```

Le mode par défaut analyse puis annule la confirmation ; `--mode appliquer` réalise
la fusion ou la réduction dans le catalogue de travail. Les options `--perturber`
et `--manquant` servent uniquement aux fichiers synthétiques E01/E02 et exigent de
restaurer ensuite les octets depuis `.campagne-initial`. Le bilan vérifie les
empreintes des 168 médias et de la sauvegarde initiale.

Six anomalies reproduites sont consignées dans `campagne/bilan.json`, avec les
fichiers de preuves et les points du code à examiner : mots-clés homonymes perdus,
rafales de dossiers distincts mélangées, petit détail modifié accepté comme doublon,
vidéos vierges classées retouchées par le SDK, libellé personnalisé non protecteur,
et exclusions externes persistantes après Annuler. La version 26.11.7 corrige les
quatre priorités hautes ; la version 26.11.8 corrige aussi les vidéos et les libellés
personnalisés. `verifier_correctifs.py` contrôle les preuves des priorités hautes et
`verifier_moyennes.py` celles des deux autres corrections. Les résultats sont dans
`campagne/correctifs.json` et `campagne/correctifs-moyennes.json`.
`VideosTest.lua` lit les réglages réels sans les modifier ; les coupes de test et
leur rétablissement sont réalisés dans l'interface native de Lightroom. Les
paramètres vidéo inconnus restent à vérifier pour éviter une fusion incertaine.
Les 21 suites du dépôt incluent les régressions nouvelles. Les preuves historiques
de `bilan.json` sont conservées.

Pour préparer un nouveau cycle depuis la sauvegarde initiale :

```powershell
python tests/catalogue-compact/nouveau_cycle.py
```

Ce script vérifie les empreintes et crée une copie neuve sous `execution-cycle-*`,
avec son manifeste et son suivi sous `campagne-cycle-*`. Il peut être exécuté
pendant que l'ancien catalogue est ouvert : il ne change ni le manifeste actif,
ni le module isolé, ni son historique. Le statut `prepare_non_active` indique
qu'aucun des 40 scénarios Lightroom n'a encore été exécuté sur cette copie.
L'activation nécessite ensuite de fermer Lightroom, d'archiver les états du
module isolé et d'y charger le manifeste, le code et l'historique initiaux avant
d'ouvrir la nouvelle copie. Les suites automatisées restent distinctes de ces
essais réels dans Lightroom.
