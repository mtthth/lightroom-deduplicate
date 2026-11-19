-- Fusionne les doublons des photos sélectionnées (ou, sans sélection, des photos affichées) : une même
-- photo importée plusieurs fois depuis des dossiers différents, ou existant en plusieurs tailles.
--
-- 0. Portée : les photos sélectionnées s'il y en a au moins deux, sinon toutes les photos affichées dans la
--    grille (dossier, collection…). Une copie n'est trouvée que si ses doublons sont dans cette portée.
--    Les photos déjà écartées par une fusion précédente (historique partagé) restent comparées, mais
--    seulement comme copies à écarter : un groupe sans autre copie, ou dont la fusion ne changerait
--    plus rien, n'est pas proposé.
-- 1. Empreinte exacte de chaque photo de la portée (voir Empreintes.lua) : deux contenus identiques
--    sont regroupés même si leurs noms ou leurs dates diffèrent.
--    Vidéos incluses : identité du fichier entier, vérifiée intégralement pour les gros candidats.
-- 2. Pour les photos dont l'empreinte diffère, recherche de variantes de même nom d'origine
--    (suffixes « -2 », « (2) », « -Modifier », « _filtered », DxO… ; séparateurs « - », « _ » et nom doublé
--    ignorés, voir Doublons.cleNom) et de même date de prise de vue.
-- 3. Ces variantes sont comparées par une miniature 16 × 16 (ImageMagick, voir Vignettes.lua et
--    Similitude.lua) : si elles montrent la même vue, l'une est une copie réduite ou recompressée.
--    Une version dont le nom annonce une retouche et qui montre la même vue est proposée dans le
--    rapport, mais reste « à vérifier » : elle n'est fusionnée que par une fusion forcée (sauf
--    empreinte exacte identique). Les retouches Lightroom restent protégées séparément par Doublons.lua.
-- 4. Pour chaque groupe, choix de la copie à garder (voir Doublons.lua) et plan de ce qui change
--    (Doublons.effets).
-- 5. Rapport HTML (rapport-doublons\index.html, voir RapportHtml.lua) : groupe par groupe, avec des
--    miniatures, la copie gardée et pourquoi, et ce qui change dans les collections et les métadonnées.
--    Il est construit à partir du même plan que celui qui est appliqué ensuite. Le détail est aussi écrit
--    dans doublons.csv.
--    Chaque groupe y porte une case « Ne pas fusionner » ou, s'il est « à vérifier », « Fusionner de
--    force » ; le code de ces choix est collé dans la boîte de confirmation (voir Choix.lua). Les groupes
--    non fusionnés sont mémorisés dans groupes-refuses.txt et restent « à vérifier » aux analyses suivantes.
-- 6. Après confirmation, la copie gardée prend la place des autres dans leurs collections (sauf
--    les collections dynamiques, qui se recalculent seules) et récupère ce qui lui manque :
--    mots-clés, note (la plus haute), drapeau, position GPS, et les champs de texte
--    listés dans Doublons.CHAMPS_TEXTE quand elle n'a rien dans le champ. Les autres copies quittent leurs
--    collections et sont rassemblées dans la collection « Doublons à retirer ».
--    Ne sont pas recopiés : réglages de développement (une copie retouchée dans Lightroom est
--    toujours la gardée, sinon le groupe reste « à vérifier »), instantanés, piles, collections
--    publiées (groupe « à vérifier »), fichiers annexes sur le disque (.xmp, .on1). Une copie écartée
--    avec des copies virtuelles laisse aussi le groupe « à vérifier » ; fusionné de force, ses copies
--    virtuelles sont recréées sur la copie gardée (voir CopiesVirtuelles.lua).
-- Le module laisse les copies écartées au catalogue. Leur retrait volontaire se termine en les
-- sélectionnant dans « Toutes les photos », puis Suppr → Retirer.

local LrApplication = import 'LrApplication'
local LrBinding = import 'LrBinding'
local LrDate = import 'LrDate'
local LrDialogs = import 'LrDialogs'
local LrFileUtils = import 'LrFileUtils'
local LrFunctionContext = import 'LrFunctionContext'
local LrHttp = import 'LrHttp'
local LrPathUtils = import 'LrPathUtils'
local LrProgressScope = import 'LrProgressScope'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'
-- Modules en mémoire périmés après une mise à jour : demander de recharger le module (Fraicheur.lua).
if not dofile(LrPathUtils.child(_PLUGIN.path, 'Fraicheur.lua')).verifier() then return end

-- Ces lecteurs sans état doivent suivre les mises à jour du module même si Lightroom
-- conserve d'anciens require() pendant qu'une tâche précédente termine son annulation.
local Catalogue = dofile(LrPathUtils.child(_PLUGIN.path, 'Catalogue.lua'))
local TraceLectures = dofile(LrPathUtils.child(_PLUGIN.path, 'TraceLectures.lua'))
local CollectionsRapides = dofile(LrPathUtils.child(_PLUGIN.path, 'CollectionsRapides.lua'))
local CopiesVirtuelles = dofile(LrPathUtils.child(_PLUGIN.path, 'CopiesVirtuelles.lua'))
local SauvegardeCollections = dofile(LrPathUtils.child(_PLUGIN.path, 'SauvegardeCollections.lua'))
local CacheAnalyses = dofile(LrPathUtils.child(_PLUGIN.path, 'CacheAnalyses.lua'))
local RevalidationFichiers = dofile(LrPathUtils.child(_PLUGIN.path, 'RevalidationFichiers.lua'))
local Annulation = require 'Annulation'
local Choix = require 'Choix'
local Csv = require 'Csv'
local DerniereAnalyse = require 'DerniereAnalyse'
local Doublons = require 'Doublons'
local T = require('Langue').t
Doublons.reglerDossiers(import('LrPrefs').prefsForPlugin())   -- mots des dossiers mal rangés (Reglages.lua)
local Epoques = require 'Epoques'
local Empreintes = dofile(LrPathUtils.child(_PLUGIN.path, 'Empreintes.lua'))
local Historique = require 'Historique'
local Parallele = require 'Parallele'
local Rafales = require 'Rafales'
local RapportHtml = require 'RapportHtml'
local Similitude = require 'Similitude'
local RetouchesVideo = require 'RetouchesVideo'
local Vignettes = dofile(LrPathUtils.child(_PLUGIN.path, 'Vignettes.lua'))
local ApercuVideo = dofile(LrPathUtils.child(_PLUGIN.path, 'ApercuVideo.lua'))

local TAILLE_LOT = 1000
local LOT_ECRITURE = 10   -- groupes fusionnés entre deux rafraîchissements de la barre de progression
local PARALLELE = 4   -- miniatures calculées en même temps
local PARALLELE_APERCUS = 8   -- génération des JPEG du rapport
local GRANDE_PORTEE = 20000
local COLLECTION_DOUBLONS = Doublons.COLLECTION
-- Collections « à retirer » : la copie gardée ne les rejoint jamais.
local CORBEILLES = { [Doublons.COLLECTION] = true, [Rafales.COLLECTION] = true }
local DOSSIER_PROJET = LrPathUtils.parent(_PLUGIN.path)
local RAPPORT = LrPathUtils.child(DOSSIER_PROJET, 'doublons.csv')
local REFUS = LrPathUtils.child(DOSSIER_PROJET, 'groupes-refuses.txt')
local HISTORIQUE = require('HistoriqueCommun').chemins()
local DOSSIER_RAPPORT = LrPathUtils.child(DOSSIER_PROJET, 'rapport-doublons')
local RAPPORT_HTML = LrPathUtils.child(DOSSIER_RAPPORT, 'index.html')
local DOSSIER_APERCUS = LrPathUtils.child(DOSSIER_RAPPORT, 'vignettes')

local parLots = Parallele.parLots

local function nomFichier(chemin)
  return chemin:match('[^/\\]+$') or chemin
end

local function nombre(n)
  return (tostring(n):reverse():gsub('(%d%d%d)', '%1 '):reverse():gsub('^ ', ''))
end

-- Boîte de départ : confirme la portée de la recherche. Renvoie { miniatures }, { reprise = true } si
-- l'utilisateur reprend l'analyse encore en mémoire (reprise : sa description, ou nil), ou nil s'il renonce.
local function demanderPortee(contexte, portee, magickDispo, reprise)
  local nb = #portee.photos
  if nb < 2 and reprise then
    local reponse = LrDialogs.confirm(T('Fusionner les doublons', 'Merge duplicates'), T('Il faut au moins deux photos pour une nouvelle '
      .. 'analyse : sélectionnez-en plusieurs, ou affichez un dossier ou une collection.\n\n',
      'A new analysis needs at least two photos: select several, or show a folder or a collection.\n\n') .. reprise,
      T('Reprendre la dernière analyse', 'Resume the last analysis'))
    return reponse == 'ok' and { reprise = true } or nil
  end
  if nb < 2 then
    LrDialogs.message(T('Fusionner les doublons', 'Merge duplicates'),
      T('Il faut au moins deux photos : sélectionnez-en plusieurs, ou affichez un dossier ou une collection.',
        'At least two photos are needed: select several, or show a folder or a collection.'), 'info')
    return nil
  end
  local f = LrView.osFactory()
  local proprietes = LrBinding.makePropertyTable(contexte)
  proprietes.miniatures = magickDispo
  proprietes.memesDimensions = magickDispo
  local description
  if portee.genre == 'selection' then
    description = string.format(T('Chercher les doublons parmi les %s photos sélectionnées.', 'Look for duplicates among the %s selected photos.'), nombre(nb))
  else
    description = string.format(T('Aucune sélection (ou une seule photo) : chercher les doublons parmi les %s photos '
      .. 'affichées%s.', 'No selection (or a single photo): look for duplicates among the %s photos shown%s.'), nombre(nb),
      portee.nom and T(' (« ' .. portee.nom .. ' »)', ' (“' .. portee.nom .. '”)') or '')
  end
  local texte = description .. T('\n\nUne copie n’est trouvée que si ses doublons sont aussi dans ces photos. '
    .. 'Les vidéos sont incluses : seules les copies de fichiers identiques sont fusionnées automatiquement. '
    .. 'Pour une version convertie ou recompressée, utilisez la fusion de force. '
    .. 'Rien n’est modifié avant que vous ayez vu le rapport et confirmé.'
    .. '\n\nLes images de mêmes dimensions peuvent aussi être comparées par miniature, même si leur nom et '
    .. 'leur date diffèrent : plus long à la première analyse, et toujours à vérifier dans le rapport.',
    '\n\nA copy is only found if its duplicates are also among these photos. '
    .. 'Videos are included: only copies of identical files are merged automatically. '
    .. 'For a converted or recompressed version, use the forced merge. '
    .. 'Nothing changes until you have seen the report and confirmed.'
    .. '\n\nImages with the same dimensions can also be compared by thumbnail, even if their name and '
    .. 'date differ: slower on the first analysis, and always to be checked in the report.')
  if nb > GRANDE_PORTEE then
    texte = texte .. T('\n\nC’est beaucoup de photos : l’analyse peut durer plusieurs minutes.', '\n\nThat is a lot of photos: the analysis may take several minutes.')
  end
  local colonne = { bind_to_object = proprietes, spacing = f:control_spacing() }
  colonne[#colonne + 1] = f:static_text { title = texte, width = 480, height_in_lines = nb > GRANDE_PORTEE and 12 or 10 }
  colonne[#colonne + 1] = f:checkbox {
    title = magickDispo and T('Miniatures dans le rapport HTML (un peu plus long)', 'Thumbnails in the HTML report (a little slower)')
      or T('Miniatures dans le rapport HTML (ImageMagick est introuvable)', 'Thumbnails in the HTML report (ImageMagick not found)'),
    value = LrView.bind('miniatures'), enabled = magickDispo,
  }
  colonne[#colonne + 1] = f:checkbox {
    title = T('Comparer aussi les images de mêmes dimensions (copies renommées ou redatées)', 'Also compare images with the same dimensions (renamed or re-dated copies)'),
    value = LrView.bind('memesDimensions'), enabled = magickDispo,
  }
  if reprise then
    colonne[#colonne + 1] = f:separator { fill_horizontal = 1 }
    colonne[#colonne + 1] = f:static_text { title = reprise, width = 480, height_in_lines = 4 }
  end
  local reponse = LrDialogs.presentModalDialog {
    title = T('Fusionner les doublons', 'Merge duplicates'), contents = f:column(colonne), actionVerb = T('Analyser', 'Analyse'),
    otherVerb = reprise and T('Reprendre la dernière analyse', 'Resume the last analysis') or nil,
  }
  if reponse == 'other' then return { reprise = true } end
  if reponse ~= 'ok' then return nil end
  return { miniatures = proprietes.miniatures and true or false,
    memesDimensions = magickDispo and proprietes.memesDimensions and true or false }
end

-- Les photos de la portée (hors copies virtuelles), avec taille, date et chemin. Celles de
-- l'historique sont marquées dejaEcartee : elles ne seront jamais gardées.
-- Renvoie nil si l'utilisateur annule.
local function lireCopies(catalogue, photos, progression, historique)
  local copies = {}
  local complet = parLots(photos, TAILLE_LOT, function(lot, _, fin)
    if progression:isCanceled() then return false end
    progression:setCaption(string.format(T('Lecture des photos : %d / %d', 'Reading photos: %d / %d'), fin, #photos))
    local brutes = catalogue:batchGetRawMetadata(lot,
      { 'path', 'fileSize', 'dateTimeOriginal', 'isVirtualCopy', 'countVirtualCopies', 'isVideo', 'fileFormat',
        'dimensions' })
    for _, photo in ipairs(lot) do
      local b = brutes[photo] or {}
      local dimensions = type(b.dimensions) == 'table' and b.dimensions or {}
      if not b.isVirtualCopy and b.path and b.fileSize then
        copies[#copies + 1] = {
          photo = photo, id = photo.localIdentifier, chemin = b.path, taille = b.fileSize,
          date = b.dateTimeOriginal, virtuelles = b.countVirtualCopies or 0,
          video = b.isVideo or b.fileFormat == 'VIDEO' or Empreintes.estVideo(b.path),
          dejaEcartee = Historique.contient(historique, b.path),
          largeurCatalogue = tonumber(dimensions.width), hauteurCatalogue = tonumber(dimensions.height),
        }
      end
    end
    progression:setPortionComplete(fin, #photos)
  end)
  return complet and copies or nil
end

-- Images distinctes d'un groupe de candidats : une classe par empreinte, avec ses copies.
local function classesDuGroupe(groupe)
  local classes, parEmpreinte = {}, {}
  for _, c in ipairs(groupe) do
    if c.empreinte then
      local classe = parEmpreinte[c.empreinte]
      if not classe then
        classe = { copies = {}, octets = 0 }
        parEmpreinte[c.empreinte] = classe
        classes[#classes + 1] = classe
      end
      table.insert(classe.copies, c)
      classe.octets = math.max(classe.octets, c.taille or 0)
    end
  end
  return classes
end

-- Rapprochement par dimensions : deux images dont une copie au moins est un cadre voisin de l'autre dans
-- une même série (rafale, prises successives) ne sont pas la même photo, même si leurs miniatures se
-- ressemblent.
local function classesCompatibles(a, b)
  for _, x in ipairs(a.copies) do
    for _, y in ipairs(b.copies) do
      if Rafales.prisesDistinctes(x, y) then return false end
    end
  end
  return true
end

local function calculerMiniature(classe, cache)
  local chemin = classe.copies[1].chemin
  local vignette = cache:obtenir('S', chemin)
  if not vignette then
    vignette = Vignettes.signature(chemin)
    cache:retenir('S', chemin, vignette)
  end
  if vignette then
    classe.signature, classe.largeur, classe.hauteur = vignette.signature, vignette.largeur, vignette.hauteur
    classe.pixels = vignette.largeur * vignette.hauteur
  end
end

-- Cherche les groupes de copies d'une même photo. Renvoie nil si l'utilisateur annule, sinon
--   groupes : listes de copies à départager (même image, ou même vue en plus petit) ;
--   differents : candidats qui restent à part (images différentes : versions retouchées…) ;
--   illisibles : fichiers qui n'ont pas pu être lus ;
--   sansMiniature : images dont ImageMagick n'a pas pu faire de miniature (conservées) ;
--   magickAbsent : vrai si des comparaisons de vues étaient utiles mais ImageMagick est introuvable.
local function chercherGroupes(copies, progression, diagnostic, cache, options)
  options = options or {}
  -- L'empreinte exacte est indépendante du nom et de la date : on la calcule pour toute la portée.
  -- Le cache évite de relire deux entrées Lightroom qui pointent vers le même chemin.
  local empreintesParChemin = {}
  local chemins = {}
  for _, c in ipairs(copies) do chemins[#chemins + 1] = c.chemin end
  progression:setCaption(string.format(T('Contrôle des fichiers et lecture du cache : %d photos', 'Checking files and reading the cache: %d photos'), #copies))
  diagnostic:mesurer('cache_empreintes_chargement', { photos = #copies }, function() cache:charger('F', chemins) end)
  local finEmpreintes = diagnostic:debutEtape('empreintes', { photos = #copies })
  local lectures, reutilisees, octets = 0, 0, 0
  local tempsLecture, tempsYield, tempsProgression = 0, 0, 0
  local illisibles = 0
  for fait, c in ipairs(copies) do
    if progression:isCanceled() then return nil end
    local debutProgression = LrDate.currentTime()
    progression:setCaption(string.format(T('Empreinte des photos : %d / %d', 'Fingerprinting photos: %d / %d'), fait, #copies))
    progression:setPortionComplete(fait, #copies)
    tempsProgression = tempsProgression + LrDate.currentTime() - debutProgression
    c.octets = c.taille
    local cleChemin = c.chemin:gsub('/', '\\'):lower()
    local empreinte = empreintesParChemin[cleChemin]
    if empreinte == nil then
      empreinte = cache:obtenir('F', c.chemin)
      if empreinte then reutilisees = reutilisees + 1
      else
        lectures = lectures + 1
        octets = octets + (c.taille or 0)
        local debutLecture = LrDate.currentTime()
        local ok, resultat = LrTasks.pcall(Empreintes.empreinte, c.chemin, c.video)
        tempsLecture = tempsLecture + LrDate.currentTime() - debutLecture
        empreinte = ok and resultat or false
        cache:retenir('F', c.chemin, empreinte or nil)
      end
      empreintesParChemin[cleChemin] = empreinte
    else
      reutilisees = reutilisees + 1
    end
    c.empreinte = empreinte ~= false and empreinte or nil
    if not c.empreinte then illisibles = illisibles + 1 end
    local debutYield = LrDate.currentTime()
    LrTasks.yield()
    tempsYield = tempsYield + LrDate.currentTime() - debutYield
  end
  finEmpreintes('ok', { lectures = lectures, reutilisees = reutilisees, octets_fichiers = octets, illisibles = illisibles,
    lecture_s = string.format('%.3f', tempsLecture), yield_s = string.format('%.3f', tempsYield),
    progression_s = string.format('%.3f', tempsProgression) })
  diagnostic:mesurer('cache_enregistrement', { phase = 'empreintes' }, function() cache:enregistrer() end)

  -- Le début et la fin servent seulement de préfiltre pour les gros fichiers. Deux vidéos peuvent
  -- partager ces morceaux et différer au milieu : lire tous les octets des seuls candidats.
  local gros = Doublons.grouper(copies, function(c)
    return c.empreinte and c.empreinte:match('^gros:') and c.empreinte or nil
  end)
  local completes, total, fait = {}, 0, 0
  for _, groupe in ipairs(gros) do total = total + #groupe end
  local finGros = diagnostic:debutEtape('verification_integrale_gros_fichiers', { photos = total })
  local cheminsGros = {}
  for _, g in ipairs(gros) do for _, c in ipairs(g) do cheminsGros[#cheminsGros + 1] = c.chemin end end
  cache:charger('G', cheminsGros)
  for _, groupe in ipairs(gros) do
    for _, c in ipairs(groupe) do
      if progression:isCanceled() then return nil end
      fait = fait + 1
      progression:setCaption(string.format(T('Vérification complète des gros fichiers : %d / %d', 'Full check of large files: %d / %d'), fait, total))
      progression:setPortionComplete(fait, total)
      local cleChemin = c.chemin:gsub('/', '\\'):lower()
      if completes[cleChemin] == nil then
        completes[cleChemin] = cache:obtenir('G', c.chemin)
        if not completes[cleChemin] then
          local ok, resultat = LrTasks.pcall(Empreintes.empreinteComplete, c.chemin,
            function() return progression:isCanceled() end)
          completes[cleChemin] = ok and resultat or false
          cache:retenir('G', c.chemin, completes[cleChemin] or nil)
        end
      end
      if progression:isCanceled() then return nil end
      c.empreinte = completes[cleChemin] or nil
      if not c.empreinte then illisibles = illisibles + 1 end
    end
  end
  finGros('ok', { photos = fait })
  -- Un préfiltre resté seul n'est jamais une preuve d'identité entre deux chemins.
  for _, c in ipairs(copies) do
    if c.empreinte and c.empreinte:match('^gros:') then
      c.empreinte = c.empreinte .. '|' .. c.chemin:gsub('/', '\\'):lower()
    end
  end

  local candidats = Doublons.grouper(copies, function(c)
    -- Une image du clip ne suffit pas à comparer sa durée, ses autres images et sa bande-son.
    if c.video then return nil end
    local extension = (c.chemin:match('%.([^%./\\]*)$') or ''):lower()
    return Doublons.cleNom(c.chemin) .. '.' .. extension .. '|'
      .. (c.date and string.format('%d', math.floor(c.date)) or '')
  end)
  local analyses = {}
  for _, groupe in ipairs(candidats) do
    -- Un fichier dont le nom annonce une retouche (« -Modifier », « _filtered », « DxO_… ») est comparé
    -- comme les autres : s'il montre la même vue, le groupe est proposé dans le rapport mais reste
    -- « à vérifier » (Doublons.decider), donc jamais fusionné sans fusion forcée.
    analyses[#analyses + 1] = { copies = groupe, classes = classesDuGroupe(groupe), origine = groupe }
  end

  -- Copies renommées et redatées (export, recompression…) : même nom et même date ne les relient plus.
  -- Les images aux dimensions exactement identiques (à la rotation près) sont donc aussi comparées par
  -- miniature. Ces rapprochements restent « à vérifier » (images d'empreintes différentes) et ne
  -- sont jamais listés comme versions distinctes : des dimensions communes ne disent rien d'autre.
  -- Les cadres d'une même série (même dossier, numéros différents, prises à la minute près) n'y sont
  -- jamais réunis : ce sont des prises distinctes (voir Rafales.prisesDistinctes).
  local nbParDimensions = 0
  if options.memesDimensions then
    local parDimensions = Doublons.grouper(copies, function(c)
      local l, h = c.largeurCatalogue, c.hauteurCatalogue
      if c.video or not c.empreinte or not l or not h or l <= 0 or h <= 0 then return nil end
      return string.format('%dx%d', math.min(l, h), math.max(l, h))
    end)
    for _, groupe in ipairs(parDimensions) do
      local classes = classesDuGroupe(groupe)
      if #classes >= 2 then
        nbParDimensions = nbParDimensions + 1
        analyses[#analyses + 1] = { copies = groupe, classes = classes, origine = groupe, parDimensions = true }
      end
    end
  end

  -- Miniature de chaque image quand un groupe en compte plusieurs. Une image présente dans plusieurs
  -- analyses (même nom et même date, mêmes dimensions) n'est réduite qu'une fois.
  local aComparer, nbMultiples, parChemin = {}, 0, {}
  for _, a in ipairs(analyses) do
    if #a.classes >= 2 then
      nbMultiples = nbMultiples + 1
      for _, classe in ipairs(a.classes) do
        local chemin = classe.copies[1].chemin
        if parChemin[chemin] then
          table.insert(parChemin[chemin], classe)
        else
          parChemin[chemin] = { classe }
          aComparer[#aComparer + 1] = classe
        end
      end
    end
  end
  local magickDispo = Vignettes.magick() ~= nil
  if magickDispo then
    local cheminsImages = {}
    for _, classe in ipairs(aComparer) do cheminsImages[#cheminsImages + 1] = classe.copies[1].chemin end
    progression:setCaption(string.format(T('Lecture du cache des comparaisons : %d images', 'Reading the comparison cache: %d images'), #aComparer))
    diagnostic:mesurer('cache_signatures_chargement', { images = #aComparer }, function() cache:charger('S', cheminsImages) end)
  end
  local finComparaison = diagnostic:debutEtape('comparaison_versions_tailles', { images = #aComparer,
    groupes = nbMultiples, parallele = PARALLELE, imagemagick = magickDispo })
  if magickDispo and #aComparer > 0 then
    if not Parallele.pourChaque(aComparer, PARALLELE, function(classe) calculerMiniature(classe, cache) end, progression,
      T('Comparaison des versions de taille différente : %d / %d', 'Comparing versions of different sizes: %d / %d')) then return nil end
  end
  local sansMiniature = 0
  for _, classe in ipairs(aComparer) do
    if magickDispo and not classe.signature then sansMiniature = sansMiniature + 1 end
    for _, autre in ipairs(parChemin[classe.copies[1].chemin]) do
      autre.signature, autre.largeur, autre.hauteur, autre.pixels = classe.signature, classe.largeur, classe.hauteur, classe.pixels
    end
  end
  finComparaison('ok', { analyses_dimensions = nbParDimensions })
  diagnostic:mesurer('cache_enregistrement', { phase = 'comparaison' }, function() cache:enregistrer() end)
  local finGroupes = diagnostic:debutEtape('regroupement_final', { photos = #copies })

  local groupes, differents = {}, {}
  local signales = {}   -- groupes de candidats déjà inscrits dans `differents`
  local nbCadragesEcartes = 0
  for _, a in ipairs(analyses) do
    local ensembles = {}
    if #a.classes >= 2 and magickDispo then
      ensembles = Similitude.regrouper(a.classes, a.parDimensions and classesCompatibles or nil)
    else
      for i, classe in ipairs(a.classes) do ensembles[i] = { classe } end
    end
    for _, ensemble in ipairs(ensembles) do
      local liste = {}
      for _, classe in ipairs(ensemble) do
        for _, c in ipairs(classe.copies) do
          c.octets = c.taille
          if classe.pixels then
            c.pixels = classe.pixels
            c.dimensions = string.format('%dx%d', classe.largeur, classe.hauteur)
          end
          if classe.signature then
            c.preuveComparaison = { chemin = classe.copies[1].chemin, signature = classe.signature,
              largeur = classe.largeur, hauteur = classe.hauteur }
          end
          liste[#liste + 1] = c
        end
      end
      if #liste > 1 then groupes[#groupes + 1] = liste end
    end
    -- Versions qui restent à part : images différentes. Le groupe de candidats est listé une seule fois,
    -- sans les images au cadrage trop éloigné de la plus grande (autre image au même nom et à la même
    -- date, fort recadrage) : elles ne sont pas proposées à la fusion forcée. Une image sans miniature
    -- (format non lu par ImageMagick) n'y figure pas non plus : sans miniature, la vérification avant
    -- fusion n'a aucune preuve de comparaison et refuserait le groupe forcé. Elle est conservée.
    if #ensembles > 1 and not a.parDimensions and not signales[a.origine] then
      signales[a.origine] = true
      local principale
      for _, ensemble in ipairs(ensembles) do
        if ensemble[1].signature then principale = ensemble[1]; break end
      end
      local gardees, entier = 0, {}
      for _, ensemble in ipairs(ensembles) do
        if not ensemble[1].signature then
          -- comptée dans sansMiniature
        elseif ensemble[1] == principale or Similitude.memeCadrage(principale, ensemble[1]) then
          gardees = gardees + 1
          for _, classe in ipairs(ensemble) do
            for _, c in ipairs(classe.copies) do
              c.octets = c.taille
              entier[#entier + 1] = c
            end
          end
        else
          nbCadragesEcartes = nbCadragesEcartes + 1
        end
      end
      if gardees > 1 then differents[#differents + 1] = entier end
    end
  end

  -- Les similarités de miniature restent limitées aux candidats de même nom/date. Les empreintes
  -- complètes, elles, regroupent les mêmes contenus partout dans la portée, quel que soit leur nom.
  local parent = {}
  for _, c in ipairs(copies) do parent[c] = c end
  local function racine(c)
    if parent[c] ~= c then parent[c] = racine(parent[c]) end
    return parent[c]
  end
  local function unir(groupe)
    local premier
    for _, c in ipairs(groupe) do
      if not premier then
        premier = c
      else
        local a, b = racine(premier), racine(c)
        if a ~= b then parent[b] = a end
      end
    end
  end
  for _, groupe in ipairs(groupes) do unir(groupe) end

  local parEmpreinte = {}
  for _, c in ipairs(copies) do
    if c.empreinte and not c.empreinte:match('^gros:') then
      parEmpreinte[c.empreinte] = parEmpreinte[c.empreinte] or {}
      table.insert(parEmpreinte[c.empreinte], c)
    end
  end
  for _, groupe in pairs(parEmpreinte) do
    if #groupe > 1 then unir(groupe) end
  end

  local composantes, ordreComposantes = {}, {}
  for _, c in ipairs(copies) do
    local r = racine(c)
    if not composantes[r] then
      composantes[r] = {}
      ordreComposantes[#ordreComposantes + 1] = r
    end
    table.insert(composantes[r], c)
  end
  -- Un groupe fait uniquement de copies déjà écartées n'a plus de copie à garder.
  local function avecCopieGardable(groupe)
    for _, c in ipairs(groupe) do
      if not c.dejaEcartee then return true end
    end
    return false
  end
  local groupesFinaux = {}
  for _, r in ipairs(ordreComposantes) do
    if #composantes[r] > 1 and avecCopieGardable(composantes[r]) then groupesFinaux[#groupesFinaux + 1] = composantes[r] end
  end

  local differentsFinaux = {}
  for _, groupe in ipairs(differents) do
    local racines, nombre = {}, 0
    for _, c in ipairs(groupe) do
      local r = racine(c)
      if not racines[r] then racines[r] = true; nombre = nombre + 1 end
    end
    if nombre > 1 and avecCopieGardable(groupe) then differentsFinaux[#differentsFinaux + 1] = groupe end
  end
  finGroupes('ok', { groupes = #groupesFinaux, distincts = #differentsFinaux, cadrages_ecartes = nbCadragesEcartes })
  return {
    groupes = groupesFinaux, differents = differentsFinaux, illisibles = illisibles, sansMiniature = sansMiniature,
    magickAbsent = not magickDispo and nbMultiples > 0,
  }
end

-- Complète les copies des groupes : retouches, notes, mots-clés, collections… et publication.
local function details(catalogue, groupes, progression, diagnostic)
  progression:setCaption(T('Recherche des retouches dans le catalogue…', 'Looking for edits in the catalog…'))
  local retouchees = diagnostic:mesurer('recherche_retouchees_catalogue', {}, function()
    return catalogue:findPhotos { searchDesc = { criteria = 'hasAdjustments', operation = 'isTrue', value = true } }
  end)
  diagnostic:compteurs('retouchees_catalogue', { photos = #retouchees })
  if progression:isCanceled() then return false end
  local estRetouchee = {}
  for _, p in ipairs(retouchees) do estRetouchee[p.localIdentifier] = true end

  -- Une même photo peut figurer dans un groupe proposé et dans un groupe de versions : lue une seule fois,
  -- ses métadonnées sont recopiées sur chacune de ses copies.
  local photos, parPhoto = {}, {}
  for _, g in ipairs(groupes) do
    for _, c in ipairs(g) do
      if not parPhoto[c.photo] then
        parPhoto[c.photo] = {}
        photos[#photos + 1] = c.photo
        diagnostic.chemins[c.photo] = c.chemin
      end
      local liste = parPhoto[c.photo]
      local deja = false
      for _, autre in ipairs(liste) do deja = deja or autre == c end
      if not deja then liste[#liste + 1] = c end
    end
  end
  local appartenances = diagnostic:mesurer('collections_publications', { photos = #photos }, function()
    return CollectionsRapides.lire(catalogue, photos, progression, CORBEILLES, false, diagnostic)
  end)
  if not appartenances then return false end
  local fait = 0
  local finMetadonnees = diagnostic:debutEtape('metadonnees_candidates', { photos = #photos, taille_lot = TAILLE_LOT })
  local complet = parLots(photos, TAILLE_LOT, function(lot)
    if progression:isCanceled() then return false end
    progression:setCaption(string.format(T('Lecture des métadonnées : %d / %d', 'Reading metadata: %d / %d'), fait, #photos))
    local brutes = catalogue:batchGetRawMetadata(lot, { 'rating', 'pickStatus', 'keywords', 'gps',
      'durationInSeconds', 'trimmedDurationInSeconds' })
    local formatees = catalogue:batchGetFormattedMetadata(lot, Doublons.CHAMPS_TEXTE)
    for _, photo in ipairs(lot) do
      if progression:isCanceled() then return false end
      local b, f = brutes[photo] or {}, formatees[photo] or {}
      local video
      for _, c in ipairs(parPhoto[photo]) do
        c.retouchee = estRetouchee[c.id] or false
        if c.video then
          if not video then
            local ok,reglages = LrTasks.pcall(function() return photo:getDevelopSettings() end)
            video = { RetouchesVideo.etat(ok and reglages or nil,b) }
          end
          c.retouchee = video[1] ~= false
          c.erreurReglagesVideo = video[1] == nil and video[2] or nil
        end
        c.note, c.drapeau, c.gps = b.rating or 0, b.pickStatus or 0, b.gps
        c.motsCles = {}
        for _, mot in ipairs(b.keywords or {}) do c.motsCles[#c.motsCles + 1] = { objet = mot, nom = mot:getName() } end
        c.textes = {}
        c.annotee = c.note > 0 or c.drapeau ~= 0 or #c.motsCles > 0
        for _, cle in ipairs(Doublons.CHAMPS_TEXTE) do
          c.textes[cle] = f[cle] or ''
          if c.textes[cle] ~= '' then c.annotee = true end
        end
        c.publiee = appartenances[photo].publiee
        c.collections = appartenances[photo].collections
      end
      fait = fait + 1
      if fait % 200 == 0 then
        progression:setCaption(string.format(T('Lecture des métadonnées : %d / %d', 'Reading metadata: %d / %d'), fait, #photos))
        LrTasks.yield()
      end
    end
  end)
  finMetadonnees(complet and 'ok' or 'annule', { photos_lues = fait })
  return complet and not progression:isCanceled()
end

-- La copie gardée prend la place de chaque copie retirée, selon le plan (Doublons.effets) montré dans le
-- rapport. À appeler dans un accès en écriture.
local function fusionnerGroupe(decision, corbeille)
  local e, p = decision.effets, decision.garde.photo
  for _, col in ipairs(e.corbeillesGardee) do col.objet:removePhotos({ p }) end
  for _, col in ipairs(e.collections) do col.objet:addPhotos({ p }) end
  for _, q in ipairs(e.quittees) do q.collection.objet:removePhotos({ q.copie.photo }) end
  for _, mot in ipairs(e.motsCles) do p:addKeyword(mot.objet) end
  if e.note then p:setRawMetadata('rating', e.note) end
  if e.drapeau then p:setRawMetadata('pickStatus', e.drapeau) end
  for _, t in ipairs(e.textes) do p:setRawMetadata(t.cle, t.valeur) end
  if e.gps then p:setRawMetadata('gps', e.gps) end
  local retirees = {}
  for i, c in ipairs(decision.retirees) do retirees[i] = c.photo end
  corbeille:addPhotos(retirees)
  corbeille:removePhotos({ p })
end

local function fusionner(catalogue, decisions, progression, diagnostic)
  -- Copies virtuelles des copies écartées (groupes fusionnés de force) : lues avant la sauvegarde, qui les
  -- inclut, et créées sur les copies gardées avant l'accès en écriture de la fusion.
  local virtuelles = diagnostic:mesurer('copies_virtuelles_lecture', { groupes = #decisions }, function()
    return CopiesVirtuelles.lire(catalogue, decisions, function(photos)
      return CollectionsRapides.lire(catalogue, photos, progression, CORBEILLES, false, diagnostic)
    end, progression)
  end)
  diagnostic:compteurs('copies_virtuelles', { a_recreer = #virtuelles })
  local sauvegarde = diagnostic:mesurer('sauvegarde_collections', { groupes = #decisions }, function()
    return SauvegardeCollections.sauver(catalogue, CopiesVirtuelles.pourSauvegarde(decisions),
      LrPathUtils.child(DOSSIER_PROJET, 'sauvegardes-fusions'), 'automatique')
  end)
  diagnostic:compteurs('sauvegarde_collections', { fichier = sauvegarde })
  local photos, gardees, cheminsGardes = {}, {}, {}
  for _, d in ipairs(decisions) do
    gardees[#gardees + 1] = d.garde.chemin
    cheminsGardes[d.garde.chemin:gsub('/', '\\'):lower()] = true
  end
  for _, d in ipairs(decisions) do
    for _, c in ipairs(d.retirees) do
      if not cheminsGardes[c.chemin:gsub('/', '\\'):lower()] then
        photos[#photos + 1] = {
          chemin = c.chemin, fichier = nomFichier(c.chemin),
          date = c.date and Epoques.texte(Epoques.depuisLightroom(c.date, 0)) or '',
        }
      end
    end
  end
  diagnostic:mesurer('copies_virtuelles_creation', { copies = #virtuelles }, function()
    CopiesVirtuelles.creer(catalogue, virtuelles, CORBEILLES, progression)
  end)
  local corbeille
  local historiqueOk, erreurHistorique = diagnostic:mesurer('ecriture_catalogue_et_historique', { groupes = #decisions }, function()
    local ok, resultat, erreur = LrTasks.pcall(Annulation.action, catalogue, HISTORIQUE, T('Fusionner les doublons', 'Merge duplicates'),
      { retablir = gardees, type = 'doublon', photos = photos, temoin = decisions[1].garde.photo }, function()
      corbeille = catalogue:createCollection(COLLECTION_DOUBLONS, nil, true)
      for i, d in ipairs(decisions) do
        if progression:isCanceled() then error(T('Fusion annulée : aucune modification du catalogue n’a été conservée.', 'Merge cancelled: no change to the catalog was kept.'), 0) end
        fusionnerGroupe(d, corbeille)
        for _, e in ipairs(d.virtuelles) do CopiesVirtuelles.appliquer(e, corbeille) end
        progression:setPortionComplete(i, #decisions)
        if i % LOT_ECRITURE == 0 or i == #decisions then
          progression:setCaption(string.format(T('Fusion des doublons : %d / %d groupes', 'Merging duplicates: %d / %d groups'), i, #decisions))
          LrTasks.yield()
        end
      end
    end)
    if not ok then error(CopiesVirtuelles.completerErreur(resultat, virtuelles), 0) end
    return resultat, erreur
  end)
  -- getContainedCollections coûte plusieurs secondes par photo une fois la fusion écrite (570 groupes :
  -- barre bloquée à 1 / 570 pendant plus de 3 minutes). On lit donc une seule fois le contenu des
  -- collections « à retirer » et on vérifie qu'aucune photo gardée n'y figure.
  diagnostic:mesurer('verification_photos_gardees', { groupes = #decisions }, function()
    progression:setCaption(T('Vérification des photos gardées…', 'Checking kept photos…'))
    -- Lecture unique, sans avancement mesurable : la barre pleine passe pour une barre figée.
    if progression.setIndeterminate then progression:setIndeterminate() end
    LrTasks.yield()   -- sans cela, la légende ne s'affiche pas avant que la lecture du catalogue ne gèle l'interface
    local aRetirer = Catalogue.lectureGroupee(catalogue, function()
      return (Catalogue.photosDesCollections(catalogue, { Doublons.COLLECTION, Rafales.COLLECTION }, true))
    end, T('Le catalogue est occupé : la vérification des photos gardées a été interrompue après 5 secondes. '
      .. 'La fusion est déjà appliquée (Ctrl+Z l’annule).', 'The catalog is busy: checking the kept photos stopped after 5 seconds. '
      .. 'The merge is already applied (Ctrl+Z undoes it).'))
    for _, d in ipairs(decisions) do
      if aRetirer[d.garde.photo.localIdentifier] then
        error(T('La photo gardée est encore dans « ' .. Doublons.COLLECTION .. ' » ou « ' .. Rafales.COLLECTION
          .. ' ». Ne retirez aucune photo du catalogue.', 'The kept photo is still in “' .. Doublons.COLLECTION .. '” or “'
          .. Rafales.COLLECTION .. '”. Do not remove any photo from the catalog.'), 0)
      end
    end
  end)
  if historiqueOk then
    local historique = Historique.lire(HISTORIQUE)
    for _, chemin in ipairs(gardees) do
      if Historique.contient(historique, chemin) then error(T('Une photo gardée reste exclue dans l’historique.', 'A kept photo is still excluded in the history.'), 0) end
    end
  end
  local ecarts = diagnostic:mesurer('copies_virtuelles_verification', { copies = #virtuelles }, function()
    return CopiesVirtuelles.verifier(virtuelles)
  end)
  diagnostic:compteurs('copies_virtuelles', { recreees = #virtuelles, reglages_differents = #ecarts })
  return corbeille, #decisions, erreurHistorique, sauvegarde, CopiesVirtuelles.bilan(virtuelles, ecarts, COLLECTION_DOUBLONS)
end

local function ko(octets)
  return string.format('%d Ko', math.floor((octets or 0) / 1024 + 0.5))
end

-- Pourquoi une copie est retirée : même image, ou copie réduite / recompressée de la gardée (une fusion
-- forcée peut garder la plus petite).
local function motifRetrait(c, garde)
  if c.empreinte ~= garde.empreinte then
    return string.format('%s (%s, %s contre %s, %s)',
      (c.pixels or 0) > (garde.pixels or 0) and 'image plus grande que la copie gardée' or 'copie réduite ou recompressée',
      c.dimensions or '?', ko(c.octets), garde.dimensions or '?', ko(garde.octets))
  end
  if c.dejaEcartee then return 'déjà écartée par une fusion précédente' end
  return c.retouchee and 'retouchée' or ''
end

-- plan : les choix appliqués (Choix.appliquer), ou nil avant que l'utilisateur ait confirmé.
local function ecrireRapportCsv(decisions, plan)
  local exclues, forcees = {}, {}
  for _, d in ipairs(plan and plan.exclues or {}) do exclues[d.numero] = true end
  for _, d in ipairs(plan and plan.forcees or {}) do forcees[d.numero] = d end
  local lignes = { { 'groupe', 'decision', 'fichier', 'detail' } }
  for i, d in ipairs(decisions) do
    if forcees[i] then
      local f = forcees[i]
      table.insert(lignes, { i, 'garder (forcé)', f.garde.chemin, 'fusion forcée malgré : ' .. f.forcee })
      for _, c in ipairs(f.retirees) do
        table.insert(lignes, { i, 'retirer (forcé)', c.chemin, motifRetrait(c, f.garde) })
      end
    elseif exclues[i] then
      table.insert(lignes, { i, 'non fusionné', d.garde.chemin, 'votre choix dans le rapport (mémorisé)' })
      for _, c in ipairs(d.retirees) do
        table.insert(lignes, { i, 'non fusionné', c.chemin, 'votre choix dans le rapport (mémorisé)' })
      end
    else
      local etat = d.versions and 'conservé à part' or d.aVerifier and 'à vérifier'
      local motif = d.aVerifier and ((d.versions and '' or 'à vérifier : ') .. d.aVerifier) or ''
      table.insert(lignes, { i, etat or 'garder', d.garde.chemin,
        motif ~= '' and motif or (d.garde.retouchee and 'retouchée' or '') })
      for _, c in ipairs(d.retirees) do
        table.insert(lignes, { i, etat or 'retirer', c.chemin, motifRetrait(c, d.garde) })
      end
    end
  end
  Csv.ecrire(RAPPORT, lignes)
end

-- Aperçus du rapport : un petit JPEG par photo montrée, dans rapport-doublons\vignettes (réutilisé d'un
-- rapport à l'autre). Renvoie false si l'utilisateur annule.
local function genererApercus(decisions, progression, diagnostic)
  local finApercus = diagnostic:debutEtape('miniatures_rapport')
  local copies, vus = {}, {}
  local function voir(c)
    if not vus[c.id] then
      vus[c.id] = true
      copies[#copies + 1] = c
    end
  end
  for _, d in ipairs(decisions) do
    voir(d.garde)
    for _, c in ipairs(d.retirees) do voir(c) end
  end

  LrFileUtils.createAllDirectories(DOSSIER_APERCUS)
  local aFaire = {}
  for _, c in ipairs(copies) do
    -- Vidéo : bandeau de ApercuVideo.IMAGES images.
    c.fichierApercu = string.format(c.video and '%s-%d-video%d.jpg' or '%s-%d.jpg', tostring(c.id), c.taille or 0,
      ApercuVideo.IMAGES)
    c.cheminApercu = LrPathUtils.child(DOSSIER_APERCUS, c.fichierApercu)
    if LrFileUtils.exists(c.cheminApercu) ~= 'file' then aFaire[#aFaire + 1] = c end
  end
  diagnostic:compteurs('miniatures_rapport', { photos = #copies, a_generer = #aFaire, en_cache = #copies - #aFaire, parallele = PARALLELE_APERCUS })
  local complet = true
  if #aFaire > 0 then
    complet = Parallele.pourChaque(aFaire, PARALLELE_APERCUS, function(c)
      if c.video then ApercuVideo.ecrire(c.chemin, c.cheminApercu, Vignettes.magick())
      else Vignettes.apercu(c.chemin, c.cheminApercu) end
    end,
      progression, 'Miniatures du rapport : %d / %d')
  end
  for _, c in ipairs(copies) do c.avecApercu = LrFileUtils.exists(c.cheminApercu) == 'file' end
  finApercus(complet and 'ok' or 'annule', { photos = #copies, generees_demandees = #aFaire, en_cache = #copies - #aFaire })
  return complet
end

local function dateDuRapport()
  local ok, texte = LrTasks.pcall(function() return LrDate.timeToUserFormat(LrDate.currentTime(), '%Y-%m-%d %H:%M') end)
  return ok and texte or ''
end

-- Ajoute les groupes non fusionnés à groupes-refuses.txt, avant toute modification du catalogue.
local function memoriserRefus(decisions)
  local nouveau = not LrFileUtils.exists(REFUS)
  local f = io.open(REFUS, 'ab')
  if not f then error(T('Impossible d’écrire ' .. REFUS .. ' (fichier ouvert ailleurs ?). Aucune modification du catalogue.', 'Cannot write ' .. REFUS .. ' (file open elsewhere?). No change to the catalog.'), 0) end
  local ok, erreur = f:write((nouveau and Choix.ENTETE or '') .. Choix.lignesRefus(dateDuRapport(), decisions))
  local fermeOk, erreurFermeture = f:close()
  if not ok or not fermeOk then
    error(T('Impossible d’écrire ', 'Cannot write ') .. REFUS .. ' : ' .. tostring(erreur or erreurFermeture) .. T('. Aucune modification du catalogue.', '. No change to the catalog.'), 0)
  end
end

-- Récapitulatif des choix collés depuis le rapport : ce qui change par rapport aux groupes proposés et, pour
-- chaque groupe forcé, ce que la fusion ne transfère pas.
-- Au-delà, la boîte de confirmation ne détaille plus chaque groupe : un texte de plusieurs milliers de lignes
-- dépasse la hauteur qu'une zone de texte Windows sait afficher, et la boîte apparaît vide.
local DETAIL_FORCES = 40
local NUMEROS_AFFICHES = 300

local function decrireChoix(plan, nbProposes)
  local nbRetirees = 0
  for _, d in ipairs(plan.aFusionner) do nbRetirees = nbRetirees + #d.retirees end
  local absorbes = #(plan.absorbes or {})
  local lignes = { string.format(T('%d groupes proposés − %d que vous ne fusionnez pas%s + %d fusionnés de force = %d groupes '
    .. 'à fusionner (%d copies mises dans « %s »).', '%d proposed groups − %d you do not merge%s + %d force-merged = %d groups '
    .. 'to merge (%d copies put in “%s”).'), nbProposes, #plan.exclues,
    absorbes > 0 and string.format(T(' − %d repris dans un groupe forcé', ' − %d taken into a forced group'), absorbes) or '', #plan.forcees, #plan.aFusionner,
    nbRetirees, COLLECTION_DOUBLONS) }
  if #plan.exclues > 0 then
    local numeros = {}
    for i, d in ipairs(plan.exclues) do
      if i <= NUMEROS_AFFICHES then numeros[i] = d.numero end
    end
    local suite = #plan.exclues > NUMEROS_AFFICHES and string.format(T(' et %d autres', ' and %d more'), #plan.exclues - NUMEROS_AFFICHES) or ''
    lignes[#lignes + 1] = T('\nNe pas fusionner : groupes ', '\nDo not merge: groups ') .. table.concat(numeros, ', ') .. suite
      .. T('. Ce choix est mémorisé dans '
      .. 'groupes-refuses.txt : ces fichiers resteront « à vérifier » aux prochaines analyses (supprimez leur ligne, '
      .. 'ou fusionnez-les de force, pour revenir dessus).', '. This choice is saved in '
      .. 'groupes-refuses.txt: these files will stay “to check” in later analyses (delete their line, '
      .. 'or force-merge them, to change your mind).')
  end
  local nonDetailles, avertissementsCaches = 0, 0
  for i, d in ipairs(plan.forcees) do
    local avertissements = Doublons.avertissements(d, true)
    for _, c in ipairs(d.retirees) do
      if (c.pixels or 0) > (d.garde.pixels or 0) then
        avertissements[#avertissements + 1] = nomFichier(c.chemin) .. T(' est une image plus grande que la copie gardée', ' is a larger image than the kept copy')
      end
    end
    for _, a in ipairs(Doublons.annoncesVirtuelles(d)) do avertissements[#avertissements + 1] = a end
    if i <= DETAIL_FORCES then
      lignes[#lignes + 1] = string.format(T('\nGroupe %d fusionné de force (%s).\nCopie gardée : %s', '\nGroup %d force-merged (%s).\nKept copy: %s'), d.numero, d.forcee, d.garde.chemin)
      for _, a in ipairs(avertissements) do lignes[#lignes + 1] = '• ' .. a end
    else
      nonDetailles = nonDetailles + 1
      avertissementsCaches = avertissementsCaches + #avertissements
    end
  end
  if nonDetailles > 0 then
    lignes[#lignes + 1] = string.format(T('\n… et %d autres groupes fusionnés de force, non détaillés ici (%d remarques '
      .. 'de plus, du même genre). Le rapport montre chaque groupe ; doublons.csv en garde le détail dès que vous confirmez.',
      '\n… and %d more force-merged groups, not detailed here (%d more remarks of the same kind). The report shows '
      .. 'each group; doublons.csv keeps the details once you confirm.'),
      nonDetailles, avertissementsCaches)
  end
  if #plan.forcees > 0 then
    lignes[#lignes + 1] = T('\nLes réglages de développement et appartenances publiées restent sur les copies écartées tant '
      .. 'qu’elles sont au catalogue. Leur retrait ultérieur fera perdre ces éléments.'
      .. '\nLes copies virtuelles des copies écartées (hors vidéos) sont recréées sur la copie gardée, avec leur nom, leurs '
      .. 'réglages, métadonnées et collections, mais sans leur historique ni leurs instantanés. Les anciennes rejoignent « '
      .. COLLECTION_DOUBLONS .. ' ». La copie gardée doit être affichée dans la grille : le module la sélectionne pour '
      .. 'créer ses copies virtuelles.',
      '\nDevelop settings and published memberships stay on the discarded copies as long as they are in the catalog. '
      .. 'Removing them later will lose these.'
      .. '\nVirtual copies of the discarded copies (except videos) are recreated on the kept copy, with their name, '
      .. 'settings, metadata and collections, but without their history or snapshots. The old ones join “'
      .. COLLECTION_DOUBLONS .. '”. The kept copy must be shown in the grid: the plug-in selects it to create its '
      .. 'virtual copies.')
  end
  return table.concat(lignes, '\n')
end

local function ecrireRapportHtml(modele)
  LrFileUtils.createAllDirectories(DOSSIER_RAPPORT)
  local f = io.open(RAPPORT_HTML, 'wb')
  if not f then error(T('Impossible d’écrire ' .. RAPPORT_HTML .. ' (page ouverte dans un autre programme ?)', 'Cannot write ' .. RAPPORT_HTML .. ' (page open in another program?)'), 0) end
  f:write(RapportHtml.page(modele))
  f:close()
end

-- Décisions (copie gardée, plan) à partir des groupes dont les métadonnées viennent d'être lues (details),
-- avec les compteurs du bilan et l'identifiant de l'analyse. Sert à l'analyse comme à sa reprise.
local function preparerDecisions(groupes, differents, diagnostic)
  local finDecisions = diagnostic:debutEtape('preparation_fusions', { groupes = #groupes })
  local refus = Choix.lireRefus(LrFileUtils.exists(REFUS) and LrFileUtils.readFile(REFUS) or '')
  local r = { decisions = {}, aFusionner = {}, nbRetirees = 0, nbReduites = 0, nbAVerifier = 0, nbRefuses = 0,
    nbVersions = 0, nbDejaFusionnes = 0 }
  local decisions, refusDecisions = r.decisions, {}
  local nbAjoutsCollections, nbRetraitsCollections, nbMotsCles = 0, 0, 0
  for _, g in ipairs(groupes) do
    local refusGroupe = Choix.refusDuGroupe(refus, g)
    local d = Doublons.decider(g, refusGroupe)
    -- Une fusion précédente a déjà écarté toutes les copies en trop et ne laisse rien à transférer.
    if Doublons.dejaFusionne(d) then
      r.nbDejaFusionnes = r.nbDejaFusionnes + 1
    else
      decisions[#decisions + 1] = d
      refusDecisions[d] = refusGroupe
    end
  end
  -- Versions conservées à part : numérotées après les autres groupes, jamais fusionnées sans fusion forcée.
  for _, g in ipairs(differents) do
    local refusGroupe = Choix.refusDuGroupe(refus, g)
    local d = Doublons.deciderVersions(g, refusGroupe)
    decisions[#decisions + 1] = d
    refusDecisions[d] = refusGroupe
  end
  -- Groupes à vérifier qui partagent une photo : un seul groupe, une seule fusion forcée.
  local avant = #decisions
  decisions = Doublons.reunirChevauchements(decisions, function(copies, versions)
    local refusGroupe = Choix.refusDuGroupe(refus, copies)
    local d = versions and Doublons.deciderVersions(copies, refusGroupe) or Doublons.decider(copies, refusGroupe)
    refusDecisions[d] = refusGroupe
    return d
  end)
  r.decisions = decisions
  if #decisions < avant then diagnostic:compteurs('groupes_reunis', { avant = avant, apres = #decisions }) end
  for _, d in ipairs(decisions) do
    if d.versions then r.nbVersions = r.nbVersions + 1 end
  end
  if #decisions == 0 then
    finDecisions('ok', { groupes_fusionnables = 0, deja_fusionnes = r.nbDejaFusionnes })
    return r
  end
  for _, d in ipairs(decisions) do
    if refusDecisions[d] then r.nbRefuses = r.nbRefuses + 1 end
    if d.versions then
      -- Comptées à part (nbVersions).
    elseif d.aVerifier then
      r.nbAVerifier = r.nbAVerifier + 1
    else
      d.effets = Doublons.effets(d)
      nbAjoutsCollections = nbAjoutsCollections + #d.effets.collections
      nbRetraitsCollections = nbRetraitsCollections + #d.effets.quittees
      nbMotsCles = nbMotsCles + #d.effets.motsCles
      r.aFusionner[#r.aFusionner + 1] = d
      r.nbRetirees = r.nbRetirees + #d.retirees
      for _, c in ipairs(d.retirees) do
        if c.empreinte ~= d.garde.empreinte then r.nbReduites = r.nbReduites + 1 end
      end
    end
  end
  finDecisions('ok', { groupes_fusionnables = #r.aFusionner, photos_a_ecarter = r.nbRetirees,
    groupes_a_verifier = r.nbAVerifier, groupes_refuses = r.nbRefuses, deja_fusionnes = r.nbDejaFusionnes })
  r.identifiant = Choix.identifiant(decisions)
  diagnostic:compteurs('plan_ecriture', { ajouts_collections = nbAjoutsCollections,
    retraits_collections = nbRetraitsCollections, ajouts_mots_cles = nbMotsCles })
  return r
end

local function decrirePortee(portee)
  if portee.genre == 'selection' then return string.format(T('les %s photos sélectionnées', 'the %s selected photos'), nombre(#portee.photos)) end
  return string.format(T('les %s photos affichées%s', 'the %s photos shown%s'), nombre(#portee.photos),
    portee.nom and T(' (« ' .. portee.nom .. ' »)', ' (“' .. portee.nom .. '”)') or '')
end

LrTasks.startAsyncTask(function()
  LrFunctionContext.callWithContext('fusionnerDoublons', function(contexte)
    local etape = T('choix de la portée', 'choosing the scope')
    local diagnostic, issue, finAnalyse, cache
    contexte:addCleanupHandler(function() if diagnostic then diagnostic:fin(issue or 'interrompu') end end)
    local ok, erreur = LrTasks.pcall(function()
      diagnostic = TraceLectures.ouvrir(LrPathUtils.child(DOSSIER_PROJET, 'diagnostic-lectures-doublons.txt'), nil, 'recherche_doublons')
      local catalogue = LrApplication.activeCatalog()
      local portee = diagnostic:mesurer('lecture_portee', {}, function() return Catalogue.portee(catalogue) end)
      diagnostic:compteurs('portee', { photos = #portee.photos, genre = portee.genre, source = portee.nom })
      local memoire = DerniereAnalyse.pour(catalogue:getPath())
      local reprise = memoire and string.format(T('L’analyse de %s (%s, analyse %s) est encore en mémoire. « Reprendre '
        .. 'la dernière analyse » rouvre son rapport et la saisie du code sans tout recomparer : les métadonnées et '
        .. 'collections sont relues, et les fichiers revérifiés avant fusion.', 'The analysis of %s (%s, analysis %s) is still '
        .. 'in memory. “Resume the last analysis” reopens its report and the code entry without comparing everything again: '
        .. 'metadata and collections are re-read, and files re-checked before merging.'), memoire.portee, memoire.date,
        memoire.identifiant) or nil
      local options = diagnostic:mesurer('attente_validation_portee', {}, function()
        return demanderPortee(contexte, portee, Vignettes.magick() ~= nil, reprise)
      end)
      if not options then issue = 'annule'; return end
      local progression = LrProgressScope { title = T('Recherche des doublons', 'Finding duplicates'), functionContext = contexte }
      diagnostic.progression = progression
      cache = CacheAnalyses.ouvrir(DOSSIER_PROJET, Vignettes.magick(), diagnostic)
      -- Analyse complète. Renvoie l'état utile à la saisie du code, ou nil (annulation, rien à fusionner).
      local function analyser()
        finAnalyse = diagnostic:debutEtape('analyse_totale', { photos_portee = #portee.photos, miniatures = options.miniatures,
          memes_dimensions = options.memesDimensions })

        etape = T('lecture des photos', 'reading photos')
        local historique = diagnostic:mesurer('synchronisation_historique', {}, function()
          Annulation.synchroniser(catalogue, HISTORIQUE)
          return Historique.lire(HISTORIQUE)
        end)
        local copies = diagnostic:mesurer('lecture_photos', { photos = #portee.photos }, function()
          return lireCopies(catalogue, portee.photos, progression, historique)
        end)
        if not copies then return end
        local nbDejaEcartees = 0
        for _, c in ipairs(copies) do
          if c.dejaEcartee then nbDejaEcartees = nbDejaEcartees + 1 end
        end
        diagnostic:compteurs('photos_admises', { photos = #copies, ignorees = #portee.photos - #copies,
          deja_ecartees = nbDejaEcartees })
        etape = T('comparaison des fichiers', 'comparing files')
        local trouves = chercherGroupes(copies, progression, diagnostic, cache, options)
        if not trouves then return end
        local groupes, differents = trouves.groupes, trouves.differents
        if #groupes == 0 and #differents == 0 then
          finAnalyse('ok', { groupes = 0 }); issue = 'aucun_doublon'
          progression:done()
          LrDialogs.message(T('Doublons', 'Duplicates'), string.format(T('Aucun fichier en double parmi %s.', 'No duplicate files among %s.'), decrirePortee(portee)), 'info')
          return
        end
        etape = T('lecture des métadonnées', 'reading metadata')
        local aLire = {}
        for _, g in ipairs(groupes) do aLire[#aLire + 1] = g end
        for _, g in ipairs(differents) do aLire[#aLire + 1] = g end
        if not details(catalogue, aLire, progression, diagnostic) then return end

        local r = preparerDecisions(groupes, differents, diagnostic)
        local decisions, aFusionner, identifiant = r.decisions, r.aFusionner, r.identifiant
        local nbDejaFusionnes, nbVersions, nbAVerifier, nbRefuses = r.nbDejaFusionnes, r.nbVersions, r.nbAVerifier, r.nbRefuses
        local nbRetirees, nbReduites = r.nbRetirees, r.nbReduites
        if #decisions == 0 then
          finAnalyse('ok', { groupes = 0, deja_fusionnes = nbDejaFusionnes }); issue = 'aucun_doublon'
          progression:done()
          LrDialogs.message(T('Doublons', 'Duplicates'), string.format(T('Aucun fichier en double à fusionner parmi %s.', 'No duplicate files to merge among %s.'), decrirePortee(portee))
            .. string.format(T('\n%d groupes ont déjà été fusionnés : leurs copies en trop sont déjà écartées.', '\n%d groups were already merged: their extra copies are already set aside.'), nbDejaFusionnes),
            'info')
          return
        end

        -- Le rapport de l'analyse précédente va être remplacé : elle ne peut plus être reprise.
        DerniereAnalyse.oublier()
        etape = T('miniatures du rapport', 'report thumbnails')
        if options.miniatures and not genererApercus(decisions, progression, diagnostic) then return end

        -- Remarques du rapport et du bilan.
        local remarques = {}
        if trouves.magickAbsent then
          remarques[#remarques + 1] = T('ImageMagick est introuvable : les copies réduites ou recompressées n’ont pas '
            .. 'été cherchées (seuls les fichiers de même image sont fusionnés).', 'ImageMagick not found: downsized or '
            .. 'recompressed copies were not looked for (only files with the same image are merged).')
        end
        if trouves.sansMiniature > 0 then
          remarques[#remarques + 1] = string.format(T('%d images n’ont pas pu être comparées par ImageMagick '
            .. '(format non lu) : elles sont conservées.', '%d images could not be compared by ImageMagick '
            .. '(unreadable format): they are kept.'), trouves.sansMiniature)
        end
        if trouves.illisibles > 0 then
          remarques[#remarques + 1] = string.format(T('%d fichiers illisibles (absents ou hors ligne) n’ont pas pu être comparés.', '%d unreadable files (missing or offline) could not be compared.'),
            trouves.illisibles)
        end
        if nbDejaFusionnes > 0 then
          remarques[#remarques + 1] = string.format(T('%d groupes déjà fusionnés ne sont pas repris : leurs copies en trop '
            .. 'sont déjà écartées et il n’y a plus rien à transférer.', '%d already merged groups are not taken again: their '
            .. 'extra copies are already set aside and there is nothing left to transfer.'), nbDejaFusionnes)
        end
        -- Le rapport signale aussi l'absence de miniatures ; la boîte de dialogue, non.
        local notesRapport = {}
        for i, r in ipairs(remarques) do notesRapport[i] = r end
        if not options.miniatures then notesRapport[#notesRapport + 1] = T('Rapport sans miniatures.', 'Report without thumbnails.') end

        etape = T('écriture du rapport', 'writing the report')
        local finRapport = diagnostic:debutEtape('ecriture_rapports', { groupes = #decisions, distincts = #differents })
        ecrireRapportCsv(decisions)
        ecrireRapportHtml({
          portee = decrirePortee(portee), date = dateDuRapport(), collection = COLLECTION_DOUBLONS, identifiant = identifiant,
          decisions = decisions, notes = notesRapport,
          vignette = function(c) return c.avecApercu and ('vignettes/' .. c.fichierApercu) or nil end,
        })
        finRapport('ok')
        finAnalyse('ok', { groupes = #decisions, photos_a_ecarter = nbRetirees })
        progression:done()

        local phrasePortee = decrirePortee(portee)
        local message = string.format(T(
          '%s : %d groupes de copies d’une même photo, %d copies en trop%s.\n\n'
          .. 'Pour chaque groupe, le rapport montre la copie gardée (la plus grande image ; à image identique, la '
          .. 'retouchée, puis la mieux rangée), ce qui est retiré, et ce qui change dans les collections et les '
          .. 'métadonnées. Cliquez sur « Ouvrir le rapport » (il s’ouvre dans votre navigateur) : rien n’est modifié '
          .. 'tant que vous ne cliquez pas sur « Fusionner ». Les copies en trop sont rassemblées dans la collection '
          .. '« %s », à retirer ensuite du catalogue. Leurs chemins et dates sont mémorisés dans %s pour que '
          .. '« Recréer les albums » continue de les ignorer après vidage de la collection.',
          '%s: %d groups of copies of the same photo, %d extra copies%s.\n\n'
          .. 'For each group, the report shows the kept copy (the largest image; for identical images, the edited '
          .. 'one, then the best filed), what is removed, and what changes in collections and metadata. Click '
          .. '“Open the report” (it opens in your browser): nothing changes until you click “Merge”. The extra copies '
          .. 'are gathered in the “%s” collection, to be removed from the catalog afterwards. Their paths and dates are '
          .. 'saved in %s so that “Recreate albums” keeps ignoring them once the collection is emptied.'),
          T((phrasePortee:gsub('^les', 'Parmi les')), 'Among ' .. phrasePortee), #aFusionner, nbRetirees,
          nbReduites > 0 and string.format(T(' (dont %d copies réduites ou recompressées)', ' (including %d downsized or recompressed copies)'), nbReduites) or '',
          COLLECTION_DOUBLONS, HISTORIQUE)
        if nbAVerifier > 0 then
          message = message .. string.format(T('\n\n%d groupes à vérifier (plusieurs copies retouchées, version '
            .. '« _filtered » ou « -Modifier », copie réduite retouchée…%s) restent tels quels.', '\n\n%d groups to check '
            .. '(several edited copies, “_filtered” or “-Edit” version, edited downsized copy…%s) are left as they are.'), nbAVerifier,
            nbRefuses > 0 and string.format(T(', dont %d que vous avez choisi de ne pas fusionner', ', including %d you chose not to merge'), nbRefuses) or '')
        end
        if nbVersions > 0 then
          message = message .. string.format(T('\n%d groupes de photos de même nom d’origine et même date ont des '
            .. 'versions distinctes (image différente : retouche, recadrage…). Elles sont conservées, sauf fusion forcée '
            .. 'dans le rapport.', '\n%d groups of photos with the same original name and date have distinct versions '
            .. '(different image: edit, exposure…). They are kept, unless force-merged in the report.'), nbVersions)
        end
        for _, r in ipairs(remarques) do
          message = message .. '\n' .. r
        end
        message = message .. T('\n\nRapport : ', '\n\nReport: ') .. RAPPORT_HTML .. T(' (analyse ', ' (analysis ') .. identifiant .. ')'
          .. T('\nUne sauvegarde texte des collections d’origine sera créée avant fusion dans sauvegardes-fusions.',
            '\nA text backup of the original collections will be written to sauvegardes-fusions before merging.')
        -- Sans groupe proposé ni groupe « à vérifier », il n'y a rien à choisir : la boîte se ferme simplement.
        local choisissable = #aFusionner > 0 or nbAVerifier > 0 or nbVersions > 0
        if choisissable then
          message = message .. T('\n\nDans le rapport, cochez « Ne pas fusionner » pour écarter un groupe, ou « Fusionner de '
            .. 'force » pour un groupe à vérifier, puis cliquez sur « Copier le code » et collez-le ci-dessous. '
            .. 'Sans code, le rapport est appliqué tel quel.', '\n\nIn the report, tick “Do not merge” to leave a group out, '
            .. 'or “Force merge” for a group to check, then click “Copy the code” and paste it below. '
            .. 'Without a code, the report is applied as it is.')
        end
        DerniereAnalyse.memoriser { catalogue = catalogue:getPath(), date = dateDuRapport(), portee = decrirePortee(portee),
          identifiant = identifiant, groupes = groupes, differents = differents, message = message,
          choisissable = choisissable }
        return { decisions = decisions, aFusionner = aFusionner, identifiant = identifiant, message = message,
          choisissable = choisissable }
      end

      -- Reprise de l'analyse en mémoire : les comparaisons de fichiers sont reprises telles quelles, mais
      -- chemins, historique, métadonnées et collections sont relus et les décisions refaites. Si l'identifiant
      -- change (copie gardée, retouche, refus, groupe déjà fusionné…), le rapport ne correspond plus : refus.
      local function reprendre()
        finAnalyse = diagnostic:debutEtape('reprise_analyse', { analyse = memoire.identifiant })
        etape = T('relecture des photos de l’analyse précédente', 're-reading the photos of the previous analysis')
        local historique = diagnostic:mesurer('synchronisation_historique', {}, function()
          Annulation.synchroniser(catalogue, HISTORIQUE)
          return Historique.lire(HISTORIQUE)
        end)
        local aLire, photos, copiesDe = {}, {}, {}
        for _, g in ipairs(memoire.groupes) do aLire[#aLire + 1] = g end
        for _, g in ipairs(memoire.differents) do aLire[#aLire + 1] = g end
        for _, g in ipairs(aLire) do
          for _, c in ipairs(g) do
            if not copiesDe[c.photo] then copiesDe[c.photo] = {}; photos[#photos + 1] = c.photo end
            table.insert(copiesDe[c.photo], c)
          end
        end
        local perimee = false
        local lu, complet = LrTasks.pcall(function()
          return parLots(photos, TAILLE_LOT, function(lot, _, fin)
            if progression:isCanceled() then return false end
            progression:setCaption(string.format(T('Relecture des photos : %d / %d', 'Re-reading photos: %d / %d'), fin, #photos))
            local brutes = catalogue:batchGetRawMetadata(lot, { 'path', 'countVirtualCopies' })
            for _, photo in ipairs(lot) do
              local b = brutes[photo] or {}
              for _, c in ipairs(copiesDe[photo]) do
                if b.path ~= c.chemin then perimee = true end
                c.virtuelles = b.countVirtualCopies or 0
                c.dejaEcartee = Historique.contient(historique, c.chemin)
              end
            end
          end)
        end)
        if lu and not complet then return nil end
        if not lu then perimee = true end
        local r
        if not perimee then
          etape = T('relecture des métadonnées', 're-reading metadata')
          if not details(catalogue, aLire, progression, diagnostic) then return nil end
          r = preparerDecisions(memoire.groupes, memoire.differents, diagnostic)
          perimee = r.identifiant ~= memoire.identifiant
        end
        progression:done()
        if perimee then
          DerniereAnalyse.oublier()
          finAnalyse('perimee'); issue = 'reprise_perimee'
          LrDialogs.message(T('Analyse à relancer', 'Analysis to run again'), T('Le catalogue a changé depuis l’analyse ' .. memoire.identifiant
            .. ' (photo déplacée ou retirée, retouche, copie gardée, groupe refusé ou déjà fusionné) : son rapport ne '
            .. 'correspond plus. Relancez l’analyse.\n\nRien n’a été modifié.', 'The catalog has changed since analysis '
            .. memoire.identifiant .. ' (photo moved or removed, edit, kept copy, refused or already merged group): its '
            .. 'report no longer matches. Run the analysis again.\n\nNothing has been changed.'), 'warning')
          return nil
        end
        finAnalyse('ok', { groupes = #r.decisions, reprise = true })
        return { decisions = r.decisions, aFusionner = r.aFusionner, identifiant = r.identifiant,
          message = T('Reprise de l’analyse ', 'Resuming analysis ') .. memoire.identifiant .. ' (' .. memoire.date .. T(') : métadonnées et '
            .. 'collections relues.\n\n', '): metadata and collections re-read.\n\n') .. memoire.message,
          choisissable = memoire.choisissable }
      end

      local etat
      if options.reprise then etat = reprendre() else etat = analyser() end
      if not etat then return end
      local decisions, aFusionner, identifiant = etat.decisions, etat.aFusionner, etat.identifiant
      local message, choisissable = etat.message, etat.choisissable

      local f = LrView.osFactory()
      local proprietes = LrBinding.makePropertyTable(contexte)
      proprietes.code = ''
      local plan
      while true do
        local colonne = {
          bind_to_object = proprietes,
          spacing = f:control_spacing(),
          f:scrolled_view {
            width = 680, height = 400,
            f:static_text { title = message, width = 640, height_in_lines = 45 },
          },
          f:push_button {
            title = T('Ouvrir le rapport', 'Open the report'),
            action = function() LrHttp.openUrlInBrowser(RapportHtml.urlFichier(RAPPORT_HTML)) end,
          },
        }
        if choisissable then
          colonne[#colonne + 1] = f:static_text { title = T('Code de vos choix (vide : le rapport tel quel) :', 'Code of your choices (empty: the report as it is):') }
          colonne[#colonne + 1] = f:edit_field { value = LrView.bind('code'), width = 680, immediate = true }
        end
        local finAttente = diagnostic:debutEtape('attente_decision_utilisateur')
        local choix = LrDialogs.presentModalDialog {
          title = T('Résultat de la recherche des doublons', 'Duplicate search results'),
          contents = f:column(colonne),
          actionVerb = choisissable and T('Fusionner', 'Merge') or T('Fermer', 'Close'),
          cancelVerb = T('Fermer sans fusionner', 'Close without merging'),
        }
        finAttente('ok', { choix = choix })
        if choix ~= 'ok' or not choisissable then issue = 'rapport_seul'; return end

        local lus, erreurCode = Choix.lireCode(proprietes.code, decisions, identifiant)
        if not lus then
          LrDialogs.message(T('Code des choix refusé', 'Choice code rejected'), erreurCode .. T('\n\nRien n’a été modifié.', '\n\nNothing has been changed.'), 'warning')
        else
          plan = Choix.appliquer(decisions, lus)
          diagnostic:compteurs('choix_rapport', { exclus = #plan.exclues, forces = #plan.forcees, a_fusionner = #plan.aFusionner })
          if #plan.exclues + #plan.forcees == 0 then
            if #plan.aFusionner > 0 then break end
            LrDialogs.message(T('Rien à fusionner', 'Nothing to merge'), T('Aucun groupe n’est proposé à la fusion. Pour fusionner un groupe '
              .. '« à vérifier », cochez « Fusionner de force » dans le rapport, puis collez le code.', 'No group is proposed '
              .. 'for merging. To merge a group “to check”, tick “Force merge” in the report, then paste the code.'), 'info')
          else
            local texte = decrireChoix(plan, #aFusionner)
            local _, nbLignes = texte:gsub('\n', '')
            local finConfirmation = diagnostic:debutEtape('attente_confirmation_choix')
            local reponse = LrDialogs.presentModalDialog {
              title = T('Confirmer vos choix', 'Confirm your choices'),
              contents = f:scrolled_view {
                width = 680, height = 400,
                f:static_text { title = texte, width = 640, height_in_lines = math.min(1500, math.max(20, nbLignes + math.ceil(#texte / 90))) },
              },
              actionVerb = #plan.aFusionner > 0 and T('Fusionner', 'Merge') or T('Mémoriser les refus', 'Save the refusals'),
              cancelVerb = T('Revenir au code', 'Back to the code'),
            }
            finConfirmation('ok', { choix = reponse })
            if reponse == 'ok' then break end
          end
        end
      end

      if #plan.exclues > 0 then
        etape = T('mémorisation des groupes non fusionnés', 'saving the groups not merged')
        diagnostic:mesurer('memorisation_refus', { groupes = #plan.exclues }, function() memoriserRefus(plan.exclues) end)
      end
      if #plan.exclues + #plan.forcees > 0 then ecrireRapportCsv(decisions, plan) end
      if #plan.aFusionner == 0 then
        issue = 'refus_seuls'
        DerniereAnalyse.oublier()
        LrDialogs.message(T('Choix mémorisés', 'Choices saved'), string.format(T('%d groupes ne seront pas fusionnés : ils resteront « à '
          .. 'vérifier » aux prochaines analyses.\n%s\n\nRien n’a été modifié dans le catalogue.', '%d groups will not be merged: '
          .. 'they will stay “to check” in later analyses.\n%s\n\nNothing has been changed in the catalog.'), #plan.exclues, REFUS), 'info')
        return
      end
      aFusionner = plan.aFusionner

      etape = T('fusion des doublons', 'merging duplicates')
      local fusion = LrProgressScope { title = T('Fusion des doublons', 'Merging duplicates'), functionContext = contexte }
      local valide = diagnostic:mesurer('revalidation_fichiers_avant_fusion', { groupes = #aFusionner }, function()
        return RevalidationFichiers.verifier(aFusionner, fusion, Empreintes, Vignettes, cache, diagnostic,
          function(elements, tache, legende) return Parallele.pourChaque(elements, PARALLELE, tache, fusion, legende) end)
      end)
      if not valide then issue = 'annule'; fusion:done(); return end
      local _, nbFusionnes, erreurHistorique, sauvegarde, bilanVirtuelles = diagnostic:mesurer('application_fusion', { groupes = #aFusionner }, function()
        return fusionner(catalogue, aFusionner, fusion, diagnostic)
      end)
      issue = 'fusion_appliquee'
      DerniereAnalyse.oublier()
      fusion:done()
      local bilan = string.format(T(
        '%d groupes fusionnés sur %d. Les copies en trop sont dans la collection « %s ». '
        .. '\n\nElles restent visibles dans les dossiers tant qu’elles sont au catalogue. Pour terminer le retrait, '
        .. 'sélectionnez uniquement les copies écartées dans « Catalogue → Toutes les photos », puis Suppr → « Retirer ».',
        '%d groups merged out of %d. The extra copies are in the “%s” collection. '
        .. '\n\nThey stay visible in folders as long as they are in the catalog. To finish removing them, select only '
        .. 'the discarded copies in “Catalog → All Photographs”, then Delete → “Remove”.'),
        nbFusionnes, #aFusionner, COLLECTION_DOUBLONS)
        .. T('\n\nCtrl+Z annule cette fusion complète, y compris l’historique des exclusions.',
          '\n\nCtrl+Z undoes this whole merge, including the history of exclusions.')
      if #plan.forcees > 0 then
        bilan = bilan .. string.format(T('\n\n%d groupes fusionnés de force, avec la copie choisie dans le rapport.', '\n\n%d groups force-merged, with the copy chosen in the report.'), #plan.forcees)
      end
      bilan = bilan .. bilanVirtuelles
      if #plan.exclues > 0 then
        bilan = bilan .. string.format(T('\n%d groupes non fusionnés, mémorisés dans %s (Ctrl+Z ne lève pas ce choix).', '\n%d groups not merged, saved in %s (Ctrl+Z does not lift this choice).'),
          #plan.exclues, REFUS)
      end
      if erreurHistorique then bilan = bilan .. T('\nHistorique texte à synchroniser : ', '\nText history to synchronise: ') .. tostring(erreurHistorique) end
      bilan = bilan .. T('\n\nSauvegarde des collections d’origine :\n', '\n\nBackup of the original collections:\n') .. sauvegarde
      LrDialogs.message(T('Doublons fusionnés', 'Duplicates merged'), bilan, erreurHistorique and 'warning' or 'info')
    end)
    if cache then cache:enregistrer() end
    if not ok then
      issue = 'erreur'
      if diagnostic then diagnostic:compteurs('erreur', { etape = etape, message = tostring(erreur) }) end
      LrDialogs.message(T('Erreur pendant la fusion des doublons', 'Error while merging duplicates'),
        string.format(T('Étape : %s\n%s', 'Step: %s\n%s'), etape, tostring(erreur)), 'critical')
    end
  end)
end)
