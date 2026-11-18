# Grand catalogue synthétique

Préparation autonome de 10 000 médias, 1 438 cas et 144 copies virtuelles prévues,
sans lire de photos personnelles. Environ 1 à 2 Gio de médias sont attendus.

```powershell
python tests/catalogue-grand/generer.py
python tests/catalogue-grand/verifier.py
```

Le générateur refuse une destination existante. Les fichiers et les modules
isolés restent sous `sortie/catalogue-grand/`, ignoré par Git. Les 168 médias du
compact sont copiés physiquement : les perturbations futures resteront séparées.
Les 9 832 autres médias comprennent 4 000 scènes uniques, 1 200 fichiers dans
300 groupes exacts, 1 200 variantes proches, 2 400 vues de rafales, 200 paires
RAW+JPEG, 200 paires vidéo et 232 fichiers de métadonnées contradictoires.
Les grandes vidéos de seuil du compact sont conservées ; les autres vidéos sont
courtes, avec des boîtes MP4 `free` propres à chaque paire.

Le statut `medias_prepares_import_lightroom_en_attente` ne signifie pas qu'un
catalogue Lightroom a été créé. Aucune base `.lrcat` n'est écrite par ces scripts.
Les contrôles de fichiers ne constituent pas des tests de fusion dans Lightroom.

Quand l'accès à Windows est rétabli :

1. Fermer proprement le catalogue en cours et désactiver les modules habituels
   Deduplicate et Albums Google Photos ainsi que ceux du compact.
2. Créer dans Lightroom le catalogue au chemin exact donné par `manifest.json` :
   `sortie/catalogue-grand/Deduplicate-grand/Deduplicate-grand.lrcat`.
3. Refuser la recherche d'adresses. Ajouter `preparation.lrplugin` et la copie
   de Deduplicate sous `environnement/lightroom-deduplicate/`. Ne pas activer
   le module Google Photos voisin : il sert uniquement de disposition isolée
   pour l'historique.
4. Importer le dossier `medias/` et tous ses sous-dossiers avec l'import natif,
   en mode **Ajouter**. Décocher l'exclusion des doublons et des images rejetées,
   ne pas appliquer de paramètre de développement ni de métadonnées et utiliser
   des aperçus Minimum. Vérifier que RAW et JPEG sont traités séparément et que
   10 000 originaux sont présents. Rétablir les options habituelles de la boîte
   d'import après cet ajout.
5. Copier `commande-a-lancer.txt` vers `commande.txt` (contenu : `initialiser`).
   La préparation vérifie d'abord la présence de tous les médias déjà importés,
   applique les états par lots de 25, puis crée les copies virtuelles.
   Attendre `OK initialiser` dans `resultat-commande.txt` ; vérifier 10 000
   originaux et 144 copies virtuelles dans `etat-sdk.tsv`.
6. Exécuter `python tests/catalogue-compact/auditer.py --racine sortie/catalogue-grand`,
   puis fermer Lightroom et sauvegarder cet état initial avant les essais destructifs.

Les lots d'états achevés sont marqués dans le catalogue avec une empreinte du
manifeste pour permettre une reprise sans réappliquer les lots terminés. Une
note attendue de zéro est conservée sans envoyer de note nulle explicite au SDK.
Après une interruption, vérifier les copies virtuelles avant de relancer : leur
création et l'enregistrement de leur marqueur sont deux opérations SDK distinctes.
Les attentes du manifeste sont des critères à tester, pas des résultats acquis.
Les publications, les masques IA et les services réseau restent hors de ce jeu.

L'inventaire `etat-sdk.tsv` du grand catalogue utilise une lecture SDK groupée
pour les chemins, notes, marqueurs, dates et nombres d'originaux/copies. Ses deux
dernières colonnes de collections/mots-clés restent vides : les hiérarchies et
appartenances correspondantes sont vérifiées en détail par l'audit SQLite en
lecture seule, consigné dans `verification.json`.

## Campagne réelle sur une copie

`creer_execution.py` copie le catalogue fermé depuis `etat-initial/`, installe le
pilote SDK dans le module isolé et borne ses commandes au nouveau catalogue.
Ouvrir cette copie dans Lightroom, puis lancer `campagne.py` : analyses à froid
et à chaud, contrôle des 1 438 périmètres, fusion en volume, réduction des
rafales, Annuler/Rétablir et restauration de tous les groupes.

Après cette phase, `actualiser_pilote.py` groupe les lectures de sélection du
pilote et recharge celui-ci entre deux requêtes. `cas_limites.py` exécute les
séquences ciblées : copies virtuelles recréées, refus persistants, choix de la
gardée, fichier absent ou modifié après analyse et libellé personnalisé.
`verifier_resultats.py` produit le bilan et les limites de couverture.

Les résultats sont conservés sous `execution-<date>/preuves/`. Les états
SQLite sont lus avec `mode=ro` et `query_only=ON` ; toutes les modifications de
catalogue passent par les commandes réelles du module et le SDK Lightroom.
Le pilote remplace uniquement les réponses aux dialogues et capture les plans.
Les états enregistrés permettent une reprise sans rejouer une écriture déjà
achevée. Les différences internes de sérialisation du développement sont
conservées et expliquées séparément des comparaisons des paramètres de rendu.
