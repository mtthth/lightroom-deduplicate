# Journal des versions

Les numéros suivent le [versionnage sémantique](https://semver.org/lang/fr/) : majeure.mineure.correctif.
Les versions privées antérieures étaient numérotées par date (jusqu'à 26.11.9).

## 1.0.2

- Vouvoiement dans toute l'interface (dialogues, messages, rapport HTML) et dans la documentation.

## 1.0.1

- Python est aussi cherché dans le PATH, en dernier recours : une installation faite par un autre moyen que
  l'installeur de python.org (winget, environnement virtuel…) est trouvée.

## 1.0.0 — première version publique

- Identifiant du module : `io.github.mtthth.deduplicate` (auparavant `fr.matthieu.deduplicate`). Le texte à ignorer
  pour les rafales est repris de l'ancienne version ; voir « Mise à jour » dans le
  [mode d'emploi](lightroom-deduplicate.lrplugin/LISEZ-MOI.md).
- Le module fonctionne seul : le module Albums Google Photos voisin devient facultatif.
- Les mots qui désignent un dossier mal rangé ou un dossier de téléchargements sont réglables dans le Gestionnaire
  de modules externes.
- Python est cherché aussi dans l'installation python.org par défaut (pour l'utilisateur) et dans Program Files.
- Rapport des doublons : filtre « vidéos seulement » ; les versions au cadrage trop éloigné de la plus grande (fort
  recadrage, autre image de même nom et de même date) ne sont plus proposées.
- Vérification avant fusion : une image qui échoue est relue une seconde fois, et la cause de l'échec est précisée.
- Miniatures et aperçus vidéo : deux tâches simultanées n'utilisent plus les mêmes fichiers temporaires.
