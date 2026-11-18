# Deduplicate pour Lightroom Classic

Le plugin `lightroom-deduplicate` regroupe les commandes de fusion des doublons et de réduction des rafales.

## Installation

Dans Lightroom Classic : Fichier → Gestionnaire de modules externes → Ajouter → dossier `lightroom-deduplicate.lrplugin`.

Prérequis (Windows) :
- **Python 3.12 ou plus récent** ([python.org](https://www.python.org/downloads/), installation par défaut),
  indispensable : il lit les collections du catalogue en lecture seule et tient le cache des analyses.
- **ImageMagick 7**, recommandé : il compare les images de tailles différentes et produit les miniatures du rapport.
- **ffmpeg**, facultatif : aperçus des vidéos dans le rapport (installation winget, `C:\ffmpeg` ou Program Files).

L’historique des photos mises de côté est `photos-traitees.txt`, à côté du dossier du module. Si le module
[Albums Google Photos](https://github.com/mtthth/lightroom-google-photos) est installé dans le dossier voisin
`lightroom-google-photos`, les deux modules partagent son fichier : au premier lancement, Deduplicate y réunit
son propre historique sans le supprimer, et Google Photos ne propose plus au téléchargement les photos déjà
écartées. Après mise à jour des modules, redémarrez Lightroom pour arrêter les anciennes synchronisations.

Dans le Gestionnaire de modules externes, les réglages du module définissent la langue de l'interface (français par
défaut, ou anglais : dialogues et rapports, dès la commande suivante ; les titres du menu suivent la langue de
Lightroom), et les mots qui désignent un dossier
mal rangé (par défaut « désordre, mal rang ») ou un dossier de téléchargements (par défaut « manquantes ») : pour
choisir la copie gardée, ces dossiers passent après les dossiers nommés, datés ou d’année.

**Mise à jour depuis une version antérieure à 1.0 (26.11.9 ou avant).** L’identifiant du module est devenu
`io.github.mtthth.deduplicate` (il était `fr.matthieu.deduplicate`). Lightroom le voit comme un nouveau module :
retirez l’ancien du Gestionnaire de modules externes avant d’ajouter celui-ci. Au premier lancement, le texte
à ignorer pour les rafales est repris de l’ancienne version, et l’historique des photos écartées repart de
`photos-traitees.txt`, qui ne change pas. Les opérations faites avec l’ancienne version ne s’annulent plus
avec Ctrl+Z. Si une annulation faite juste avant la mise à jour n’a pas encore été reportée dans l’historique,
le module le signale et ne touche à rien : réinstallez alors l’ancienne version quelques secondes, puis revenez
à celle-ci.

## Commandes

Dans Lightroom : Bibliothèque → Options du module externe → …

**Annuler / Rétablir.** Chaque fusion automatique, fusion forcée et réduction de rafales constitue une seule
action Lightroom : **Ctrl+Z** restaure les collections, métadonnées et mots-clés antérieurs. **Rétablir** réapplique
l'opération. L'état des exclusions est inclus dans cette action et conservé dans le catalogue ;
`photos-traitees.txt` en est le miroir, synchronisé après Annuler / Rétablir et avant toute nouvelle analyse.
Les éditions volontaires du fichier texte sont conservées comme base des opérations suivantes. Les nouvelles
actions enregistrent un journal des ajouts et retraits propres à chaque opération : les exclusions ajoutées
ou retirées par un autre module sur d'autres chemins restent conservées lors des Annuler / Rétablir successifs.
Une métadonnée interne sur un original concerné suit l'action Annuler / Rétablir ;
les propriétés globales du catalogue seules ne sont pas annulées par Lightroom.
Pour rétablir les exclusions d'une fusion plus ancienne, utilisez sa sauvegarde avec la commande de restauration.
Une annulation d'une action antérieure à la migration de l'historique ne peut pas être synchronisée
automatiquement avec l'historique commun : le module signale cette situation pour éviter de perdre des exclusions.

### Fusionner les doublons…

Une même photo importée plusieurs fois (dossier « Désordre », copies `-2`, `-3`, `(2)`, versions `-Modifier`…).

**Vidéos aussi.** La recherche automatique fusionne les copies de fichiers vidéo strictement identiques,
même renommées ou de plus de 64 Mo. Le début et la fin servent de préfiltre pour les gros fichiers ;
l'identité est ensuite vérifiée sur tous les octets des candidats. Une vidéo convertie, recompressée,
recoupée ou dont le conteneur a changé se fusionne avec **Fusionner de force la sélection…** : choisissez la
version à garder. Les collections et métadonnées sont réunies comme pour les photos ; les réglages et
les coupes vidéo restent sur leur version d'origine.
Les bornes de coupe et les réglages vidéo sont vérifiés directement : une seule copie retouchée est gardée,
plusieurs copies retouchées restent à vérifier. Une lecture incomplète ou un réglage inconnu empêche la fusion
automatique ; le seul indicateur général « retouchée » de Lightroom ne suffit pas pour les vidéos.

**Sur quelles photos ?** Sur les photos **sélectionnées** s'il y en a au moins deux, sinon sur toutes les photos
**affichées** dans la grille (le dossier ou la collection ouverte). Une boîte l'annonce avant de commencer. Une copie
n'est trouvée que si ses doublons sont aussi dans ces photos : sélectionnez une année, un dossier parent…

La commande calcule d'abord une empreinte du contenu de toutes les photos de la portée : une empreinte identique
signale un doublon, quel que soit le nom ou la date. Pour les contenus différents, elle cherche aussi les variantes de
même nom d'origine (suffixes de copie ou de retouche ignorés : `-2`, `(2)`, `-Modifier`, `_filtered`, DxO…) et de même
date, puis compare les images par une miniature ImageMagick de 16 × 16 pixels :

- empreinte identique : doublons, on garde un seul fichier ;
- même vue en plus petit ou recompressée (miniature 16 × 16, même forme, mêmes couleurs) : groupe **à vérifier**,
  avec la plus grande proposée comme gardée. La miniature peut masquer un petit texte ou une retouche locale :
  ces variantes exigent un choix de fusion forcée dans le rapport ;
- même vue tournée d'un quart ou d'un demi-tour (copie redressée par Picasa ou une visionneuse, l'original
  restant par exemple dans `Originals`) : groupe **à vérifier** « orientations différentes ». Le module ne sait
  pas laquelle est bien orientée : gardez-la par une fusion forcée ;
- version dont le nom annonce une retouche (`_filtered`, `-Modifier`, DxO…) et qui montre la même vue : groupe
  **à vérifier** « version retouchée d'après son nom ». Elle n'est jamais fusionnée par défaut, mais le rapport la
  propose : cochez « Fusionner de force » et choisissez la copie à garder si la retouche peut être perdue. Une
  empreinte exacte identique reste un simple doublon ;
- image différente mais de même cadrage (exposition, teinte, recompression plus forte…) : les deux sont gardées et
  listées dans « Versions conservées à part ». Le rapport propose quand même de les fusionner de force, en
  choisissant la copie à garder ;
- cadrage trop différent de la plus grande (fort recadrage, redressement, ou simplement une autre image de même
  nom et de même date) : les deux sont gardées et n'apparaissent pas dans le rapport.

Option **« Comparer aussi les images de mêmes dimensions »** (cochée si ImageMagick est installé) : une copie
renommée et redatée (export, recompression : `PPD-001.jpg` et `img20211101_20185594.jpg`) n'a ni le nom ni la date
de l'original. Les images aux dimensions exactement identiques, à la rotation près, sont donc aussi comparées par
miniature. Ces rapprochements restent toujours **à vérifier** (« noms différents ») et ne sont jamais listés comme
versions distinctes. La première analyse d'une grande portée est plus longue : une miniature par image qui partage
ses dimensions avec une autre, gardée ensuite dans le cache.

Pour les JPEG, l'empreinte conserve les tables de décodage, les dimensions, le flux compressé, le profil couleur
ICC, le segment Adobe et l'orientation effective (EXIF et XMP, 0 valant 1). Les autres métadonnées (dates,
logiciel, mots-clés, IPTC, vignette EXIF, commentaires) sont ignorées : un fichier dont Lightroom ou un autre
logiciel a seulement réécrit les métadonnées reste un doublon exact. Un EXIF ou un XMP dont l'orientation est
illisible est conservé entier, par prudence. Dans chaque groupe final, toutes les images doivent
ressembler directement à la copie gardée : une chaîne de ressemblances insuffisante laisse le groupe « à vérifier ».

**Relances rapides.** `cache-analyses.sqlite3`, à côté du module, conserve les empreintes et les
signatures de comparaison. À chaque relance, les fichiers sont contrôlés par leur taille, leurs dates précises
et leur identité de fichier. Un changement de ces attributs, ou une absence de fichier, invalide l'entrée. Un
changement du code de calcul invalide les résultats concernés ; une mise à jour d'ImageMagick invalide les
signatures. Les erreurs de lecture ne sont jamais mises en cache. Un cache inaccessible ou endommagé entraîne
un recalcul normal, signalé dans le diagnostic. Le premier passage remplit le cache ; les suivants profitent
des résultats enregistrés, y compris quand la portée change mais recouvre les mêmes fichiers.

Après confirmation de la fusion, les fichiers de **tous les groupes à appliquer** sont relus sans ce cache.
Les empreintes intégrales des grosses vidéos et les signatures ayant justifié une fusion par ressemblance
sont revérifiées. Un écart ou un fichier illisible interrompt toute la fusion avant la sauvegarde et avant
la première modification du catalogue : il faut relancer l'analyse. Le cache accélère ainsi la préparation
du rapport ; la vérification finale reste nécessaire. Le journal distingue les résultats réutilisés,
les nouveaux calculs, les écritures du cache et la phase de revalidation avant fusion.
Le fichier de cache peut être supprimé lorsque les recherches sont arrêtées : il sera reconstruit.

La copie gardée est la plus grande image, puis celle qui est retouchée dans Lightroom, puis celle qui a une date de
prise de vue (une vidéo réencodée en perd souvent), puis la mieux rangée. Elle prend
la place des autres dans leurs collections et récupère mots-clés, note, drapeau, position GPS, et les champs de texte
(titre, légende, auteur, lieu, ville, pays…) qu'elle n'a pas. Les autres copies vont dans la collection
« Doublons à retirer » (jamais supprimées par le module). Elles restent visibles dans les dossiers tant qu'elles
sont dans le catalogue. Pour terminer le retrait : sélectionner uniquement les copies écartées dans
**Catalogue → Toutes les photos**, puis **Suppr → Retirer**. Suppr depuis une collection peut simplement les sortir
de cette collection.
La fusion conserve la vue courante : elle n'ouvre pas automatiquement « Doublons à retirer ».
Les chemins, noms et dates des copies retirées sont aussi conservés dans l'historique `photos-traitees.txt` (voir
« Installation »). Avec le module Albums Google Photos, « Recréer les albums » ignore ces photos même après vidage de
la collection. Pour les prendre de nouveau en compte, retirez leur ligne de l'historique.
Une nouvelle recherche des doublons compare encore ces copies déjà écartées, mais ne les garde jamais : si l'une
d'elles réapparaît dans une collection à côté d'une autre copie, le groupe est proposé (badge « déjà écartée ») et
la copie écartée rejoint de nouveau « Doublons à retirer ». Si elle a la meilleure image, le groupe reste « à
vérifier ». Un groupe déjà fusionné, sans rien à transférer, n'est pas repris.

**Rapport HTML avant toute modification.** Après l'analyse, le module écrit `rapport-doublons\index.html` et propose
de le voir (bouton « Voir le rapport », il s'ouvre dans le navigateur) avant que vous confirmiez. Pour chaque groupe : les
miniatures des copies, la copie gardée et pourquoi (« la plus grande image », « retouchée dans Lightroom », « dossier
mieux rangé »…), ce qui est retiré, les collections que la copie gardée rejoint ou que les copies retirées quittent,
les mots-clés, la note, le drapeau, les textes et la position GPS recopiés. Il montre aussi les groupes « à vérifier »
(rien n'est fait pour eux) et les versions conservées à part. Les chiffres clés (copies retirées, Go libérés,
collections modifiées) ouvrent la page, et une barre de filtre cherche par nom ou dossier. Le rapport est construit à partir du même plan
que celui qui est appliqué ensuite : il ne peut pas annoncer autre chose. Seuls vos choix (voir ci-dessous) le modifient,
et ils sont récapitulés avant la fusion. Les miniatures sont des aperçus JPEG de
220 pixels écrits dans `rapport-doublons\vignettes\` (réutilisés d'un rapport à l'autre ; case à décocher dans la
boîte de départ pour s'en passer). Le détail est aussi dans `doublons.csv`.

**Écarter ou forcer un groupe depuis le rapport.** Chaque groupe proposé a une case **Ne pas fusionner** ; chaque
groupe « à vérifier » et chaque groupe de versions conservées à part a une case **Fusionner de force**, avec un
bouton « garder celle-ci » sous chaque copie (par défaut, celle qui serait gardée). Un groupe de versions forcé
reprend un groupe proposé dont il contient toutes les copies ; s'il n'en partage qu'une partie, cochez « Ne pas
fusionner » sur l'autre groupe. Les groupes « à vérifier » et de versions qui ont une photo en commun (des
copies identiques et une autre version de la même photo, par exemple) sont réunis en un seul groupe dès
l'analyse : forcé, il ne garde qu'une copie. La barre du haut permet d'écarter d'un coup les groupes affichés par le
filtre, ou de les fusionner tous (les groupes « à vérifier » et de versions sont alors fusionnés de force avec la
copie choisie), de n'afficher que vos choix, et de **copier le code** de vos choix, par exemple
`DEDUP 1a2b3c4d · non 12 45 · force 3 9:2` (« 9:2 » : garder la 2ᵉ copie du groupe 9). Collez ce code dans la
boîte « Résultat de la recherche » de Lightroom avant de cliquer sur « Fusionner » ; sans code, le rapport est
appliqué tel quel. Le code porte l'identifiant de l'analyse : un code copié depuis un autre rapport est refusé.
Le navigateur garde les cases cochées tant que l'analyse retrouve les mêmes groupes.
Un code refusé ramène à la saisie du code. Si vous avez fermé la boîte sans fusionner, relancez « Rechercher les
doublons pour fusion… » et cliquez sur « Reprendre la dernière analyse » : le rapport et la saisie du code
reviennent sans tout recomparer. Seuls les chemins, les métadonnées et les collections sont relus, puis les
fichiers sont revérifiés avant la fusion. Si le catalogue a changé au point que le rapport ne correspond plus,
la reprise est refusée. Cette analyse reste en mémoire jusqu'à la fermeture de Lightroom, un rechargement du
module, une nouvelle analyse ou une fusion.
Avant toute modification, un récapitulatif liste les groupes écartés et, pour chaque groupe forcé, ce qui n'est
pas transféré : retouches Lightroom, publications des copies écartées, ou copie écartée plus grande que la
gardée. Il annonce aussi les copies virtuelles recréées (voir ci-dessous). Les groupes forcés passent par la même
vérification des fichiers, la même sauvegarde des collections et la même action Ctrl+Z que les autres.
`doublons.csv` est réécrit avec les décisions finales.

**Copies virtuelles des copies écartées.** Retirer une photo du catalogue retire aussi ses copies virtuelles.
Une fusion forcée (depuis le rapport ou par **Fusionner de force la sélection…**) les recrée donc sur la copie
gardée, comme vous le feriez à la main. Pour chaque copie virtuelle d'une copie écartée, le module crée une copie
virtuelle de la gardée avec le même nom de copie. Il lui applique les réglages de développement de l'ancienne (la
température et la teinte d'une balance des blancs « Telle quelle » ou « Auto » sont recalculées pour le fichier
gardé). Elle rejoint aussi les collections de l'ancienne et en reçoit les métadonnées, selon les mêmes règles que
la copie gardée. L'ancienne quitte ses collections pour « Doublons à retirer », où elle suit son original, et
figure dans la sauvegarde des collections. Après la fusion, les réglages de chaque nouvelle copie sont relus et
comparés. Le bilan liste les réglages qui diffèrent, à vérifier avant de retirer les copies écartées.
L'historique de développement, les instantanés et les publications des anciennes ne sont pas repris. Les copies
virtuelles de vidéos ne sont pas recréées. Celles qui sont déjà dans une collection « à retirer » ne le sont pas
non plus, ni celles qui font partie de la sélection d'une fusion forcée. Le SDK crée une copie virtuelle à partir
de la sélection : la copie gardée doit être affichée dans la grille, et la sélection d'origine est rétablie
ensuite. Chaque création est une action Lightroom distincte, avant la fusion. Ctrl+Z annule d'abord la fusion :
les nouvelles copies restent alors sur la copie gardée, sans les réglages des anciennes, jusqu'aux Ctrl+Z suivants.

Les groupes non fusionnés sont mémorisés dans `groupes-refuses.txt`, à côté du dossier du module : une ligne par
groupe, avec la date et les chemins de ses fichiers. Aux analyses suivantes, un groupe qui réunit deux fichiers
d'une même ligne reste « à vérifier » (« vous avez choisi de ne pas fusionner ces fichiers le … »). Pour revenir sur
ce choix, fusionnez le groupe de force, ou supprimez sa ligne du fichier. Ctrl+Z ne lève pas un refus.

Les collections, leurs noms/parents et les publications des photos candidates sont lus en une opération SQLite
en lecture seule (`mode=ro` et `query_only`), avec Python 3.12 ou plus récent installé depuis python.org (pour
l'utilisateur ou pour tous, ou dans `C:\Python3xx`). La structure du catalogue et la présence de toutes les photos sont vérifiées : une lecture
incomplète ou une structure inconnue arrête l'analyse. Cette lecture ne modifie aucune photo et n'ajoute aucune
étape d'annulation. Les modifications de fusion utilisent toujours le SDK Lightroom, après confirmation.
La commande **Tester la vitesse du catalogue…** mesure ces lectures sur les photos sélectionnées (100 maximum)
et enregistre le résultat dans `diagnostic-catalogue.txt`, à côté du dossier du module.
Pendant la recherche et la fusion forcée, un journal détaillé est écrit respectivement dans
`diagnostic-lectures-doublons.txt` et `diagnostic-lectures-fusion-forcee.txt`. La durée de la lecture groupée
y est enregistrée. Les anciennes sessions SDK détaillent également les photos, collections et appels.
Les sessions successives sont ajoutées au journal.
Le journal commence dès le lancement de la commande. Il chronomètre la portée,
l'historique, les empreintes, la vérification complète des gros fichiers, la comparaison des versions,
les retouches, les collections/publications, les métadonnées, les décisions, les miniatures, les rapports,
la sauvegarde et la fusion. Les attentes de confirmation sont identifiées séparément du temps d'analyse.
Les compteurs indiquent les photos réellement traitées, les réutilisations de cache et les écritures prévues.

### Retrouver les collections avant une fusion

Avant chaque prochaine fusion automatique ou forcée, le module relit les appartenances courantes et écrit un
fichier texte horodaté dans `sauvegardes-fusions/`, à côté du module. Ce fichier conserve, pour les copies
gardées **et** écartées, le chemin du fichier, l'identifiant de photo, son rôle et toutes les collections ordinaires
d'origine avec leur hiérarchie complète. L'écriture est vérifiée avant toute modification du catalogue ; une
sauvegarde impossible interrompt la fusion. Ces fichiers sont indépendants du rapport et restent conservés.

**Restaurer les collections avant fusion ou rafales…** permet de choisir une sauvegarde puis de cocher les groupes à restaurer (boutons « Tous » / « Aucun » pour toutes les pages), de réajouter les appartenances
d'origine et de recréer les collections/ensembles disparus. Les copies restaurées sortent des collections de
retrait si elles n'y étaient pas à l'origine ; les autres appartenances actuelles restent conservées. Cette
restauration est annulable par Ctrl+Z et synchronise les exclusions de l'historique. Les sauvegardes antérieures
à la sélection par groupe ne contiennent pas les limites des groupes et restent restaurables uniquement en entier. Une photo retirée du
catalogue doit être réimportée avant la restauration ; les copies virtuelles disparues nécessitent une
restauration du catalogue. Les retouches, fichiers et anciennes valeurs des métadonnées ne sont pas sauvegardés
par ce récapitulatif. Une sauvegarde ne prouve pas que la fusion a été appliquée : elle est écrite avant celle-ci.

### Fusionner de force la sélection…

Pour fusionner un groupe que la détection automatique ne reconnaît pas : sélectionnez ses photos, puis lancez la
commande dans **Bibliothèque → Options du module externe**. Le SDK Lightroom ne permet pas d'ajouter une commande
au menu du clic droit. La commande considère toute la sélection comme une seule photo, sans comparer les fichiers.
Elle propose la plus grande résolution (lue dans le catalogue Lightroom), puis la meilleure note, puis le nom le
plus simple. Les dimensions, la note et le poids sont visibles pour chaque choix. Si les dimensions sont incomplètes,
la note et le nom priment ; le poids du fichier départage les égalités. La proposition peut être changée.
Le récapitulatif liste explicitement tous les albums après fusion, y compris ceux où la photo gardée se trouve déjà,
avec leur chemin complet (année comprise), puis les autres collections ordinaires. Les métadonnées sont réunies :
note maximale, union des mots-clés, drapeau retenu prioritaire sur rejeté, textes et GPS déjà renseignés conservés,
champs vides complétés. L'accès à l'historique est vérifié avant toute modification du catalogue.
Cette commande force aussi la fusion de versions `_filtered`, `-Modifier` ou ayant des retouches Lightroom :
la confirmation « Fusionner de force » avertit pour chaque copie écartée que ses éventuelles retouches Lightroom
ne sont pas vérifiées et ne seront pas transférées ; elle signale aussi les appartenances publiées. Ces éléments
restent sur les copies écartées tant qu'elles sont au catalogue ; leur retrait ultérieur fera perdre ces éléments.
Les copies virtuelles des copies écartées sont recréées sur la gardée (voir « Copies virtuelles des copies
écartées »). Une copie virtuelle dont l'original est également sélectionné ne peut pas être la
gardée, puisque retirer son original la retirerait aussi. Une virtuelle dont l'original est déjà dans une collection
« à retirer » ne peut pas non plus être gardée : rétablissez d'abord son original. Les copies virtuelles écartées n'excluent pas leur
fichier source de l'historique. Les copies fusionnées rejoignent « Doublons à retirer » et leurs fichiers sont
mémorisés dans `photos-traitees.txt`. La vue courante reste affichée après la fusion.
Si la photo gardée avait déjà été mise à retirer, la fusion la rétablit : elle sort de « Doublons à retirer » et de
« Rafales à retirer », et son chemin est enlevé des exclusions de `photos-traitees.txt`. L'ancien historique est
conservé dans un fichier `.bak`. La commande vérifie que la gardée n'est plus dans une collection de retrait
avant d'annoncer la réussite. Pour réparer un ancien groupe où toutes les copies avaient été écartées, relancer
la fusion forcée sur le groupe et confirmer la photo à garder.

### Réduire les rafales…

Avant chaque réduction confirmée, une sauvegarde horodatée des collections de toutes les photos concernées
est créée et vérifiée dans `sauvegardes-rafales/`. Si elle échoue, la réduction est interrompue. Utilisez
**Restaurer les collections avant fusion ou rafales…** pour restaurer les collections et les exclusions.
La restauration retire aussi le mot-clé « Rafale traitée » des photos des groupes sélectionnés, pour permettre
leur réanalyse. La sauvegarde ne contient pas les autres mots-clés, retouches ou fichiers. Une sauvegarde peut
exister même si la réduction échoue ensuite.

Un journal `diagnostic-rafales.txt`, à côté du module, conserve les sessions successives avec leurs dates,
les durées des grandes étapes, les attentes de confirmation et des compteurs. Il permet d’identifier une étape lente,
même si l’analyse est interrompue.


Affichez un dossier ou une collection, puis lancez la commande (réglages : 1 cadre sur 4, sous-dossiers).

- Une rafale = au moins 3 cadres à une seconde d'écart au plus, avec des numéros de fichier voisins (RAW + JPEG et
  copies `-2` comptent pour un cadre).
- Chaque rafale est découpée en blocs de 4 cadres ; on garde le plus net de chaque bloc (netteté mesurée par
  ImageMagick).
- Sont toujours gardés, en plus : les cadres dans une collection protégée (les albums
  Google comptent), notés, avec drapeau ou libellé (y compris personnalisé, sans couleur dans le jeu actif),
  retouchés dans Lightroom, avec copies virtuelles, publiés, ou
  qui ont une version retouchée dans un éditeur externe.
- Les collections dont le nom ou un ensemble parent contient « sessions » ne protègent pas les photos, sans distinction
  de casse. Ce texte est modifiable dans **Fichier > Gestionnaire de modules externes > Deduplicate** ; laissez-le vide
  pour désactiver cette exception. Les époques et les collections à retirer restent aussi exclues des protections.
  Les autres protections restent actives. Si les photos mises de côté sont ensuite retirées du catalogue, elles
  disparaissent aussi de leurs collections.
- Les autres cadres (tous leurs fichiers) vont dans la collection « Rafales à retirer » après confirmation. Avant
  confirmation, « Voir le rapport » ouvre `rapport-rafales/index.html`, avec les miniatures, les décisions et les
  raisons des protections. Le détail est aussi écrit dans `rafales.csv`. Rien n'est supprimé par le module.
- Toutes les photos des rafales traitées reçoivent le mot-clé « Rafale traitée » (non exporté) : une relance les
  ignore, même une fois la collection vidée. Pour retraiter une rafale, ôtez ce mot-clé de ses photos.
- Les fichiers des cadres retirés sont aussi inscrits dans l'historique `photos-traitees.txt`. Le module
  les ignore lors des prochaines réductions et « Recréer les albums » ne les réintroduit pas après vidage de la
  collection. Pour les reprendre en compte, retirez leurs lignes du fichier ; pour retraiter la rafale, ôtez aussi le
  mot-clé « Rafale traitée » de toutes ses photos.
- Ctrl+Z annule ensemble la mise à l'écart, le mot-clé et l'historique. La vue courante reste affichée.

## Tests

Depuis la racine du dépôt, `node tests/lancer.mjs` lance les 21 suites Lua et 3 suites Python hors de Lightroom.
Elles utilisent Node 22+, Lua 5.3 (`texlua` de MiKTeX ou `lua`) et Python 3.12+ sous Windows. Les variables `LUA` et `PYTHON`
permettent de préciser les exécutables. Le code et les tests sont copiés dans un dossier temporaire : aucun
catalogue personnel, historique, rapport ou cache réel n’est utilisé.

Les tests de Google Photos et leurs mutations se lancent depuis le dépôt voisin
[`lightroom-google-photos`](https://github.com/mtthth/lightroom-google-photos), avec son propre lanceur.
