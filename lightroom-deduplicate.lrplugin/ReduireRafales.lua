-- Réduit les rafales du dossier (ou de la collection) affiché dans Lightroom.
--
-- 1. Détecte les rafales : au moins 3 cadres qui se suivent à une seconde au plus, avec des numéros de
--    fichier voisins (voir Rafales.lua).
-- 2. Découpe chaque rafale en blocs de 4 cadres consécutifs (réglable) et, dans chaque bloc, garde le
--    cadre le plus net (netteté mesurée par ImageMagick, voir Vignettes.lua).
-- 3. Les cadres protégés sont toujours gardés, en plus du plus net de leur bloc : ceux qui sont dans une
--    collection protégée (voir les réglages du module), notés, marqués d'un
--    drapeau ou d'un libellé (même personnalisé), retouchés dans Lightroom ou avec des copies virtuelles,
--    publiés, ou qui ont une version retouchée dans un éditeur externe (-Modifier, DxO_…).
-- 4. Après confirmation, les autres cadres (tous leurs fichiers : RAW + JPEG, copies…) sont mis dans la
--    collection « Rafales à retirer ». Rien n'est supprimé : le SDK de Lightroom ne le permet pas. Il
--    reste à sélectionner ces photos dans « Toutes les photos », puis Suppr → Retirer.
-- 5. Toutes les photos des rafales traitées (gardées comme retirées) reçoivent le mot-clé « Rafale
--    traitée », non exporté. La collection « Rafales à retirer » sera vidée une fois les cadres
--    supprimés : le mot-clé est la mémoire qui empêche une relance de réduire une seconde fois les cadres
--    déjà réduits.
-- Le détail est écrit dans rafales.csv, dans le dossier du projet.
-- Sont ignorées les photos des collections « Doublons à retirer » et « Rafales à retirer », et celles qui
-- portent déjà le mot-clé « Rafale traitée ».

local LrApplication = import 'LrApplication'
local LrBinding = import 'LrBinding'
local LrDialogs = import 'LrDialogs'
local LrFileUtils = import 'LrFileUtils'
local LrHttp = import 'LrHttp'
local LrFunctionContext = import 'LrFunctionContext'
local LrPathUtils = import 'LrPathUtils'
local LrPrefs = import 'LrPrefs'
local LrProgressScope = import 'LrProgressScope'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'

local Catalogue = require 'Catalogue'
local Csv = require 'Csv'
local Doublons = require 'Doublons'
local Epoques = require 'Epoques'
local Historique = require 'Historique'
local Annulation = require 'Annulation'
local Parallele = require 'Parallele'
local Rafales = require 'Rafales'
local T = require('Langue').t
local RapportRafales = require 'RapportRafales'
local RapportHtml = require 'RapportHtml'
local Vignettes = require 'Vignettes'
local TraceLectures = require 'TraceLectures'
local SauvegardeCollections = require 'SauvegardeCollections'

local TAILLE_LOT = 1000
local PARALLELE = 4   -- mesures de netteté en même temps
local PARALLELE_APERCUS = 8   -- génération des JPEG du rapport
local LIBELLES_COULEUR = { red = true, yellow = true, green = true, blue = true, purple = true }
local RAPPORT = LrPathUtils.child(LrPathUtils.parent(_PLUGIN.path), 'rafales.csv')
local DOSSIER_RAPPORT = LrPathUtils.child(LrPathUtils.parent(_PLUGIN.path), 'rapport-rafales')
local DOSSIER_APERCUS = LrPathUtils.child(DOSSIER_RAPPORT, 'vignettes')
local RAPPORT_HTML = LrPathUtils.child(DOSSIER_RAPPORT, 'index.html')
local DIAGNOSTIC = LrPathUtils.child(LrPathUtils.parent(_PLUGIN.path), 'diagnostic-rafales.txt')
local HISTORIQUE = require('HistoriqueCommun').chemins()

-- Source affichée dans Lightroom : un dossier ou une collection. Renvoie
-- { nom, dossier (vrai pour un dossier), photos = function(sousDossiers) }, ou nil et un message.
local function lireSource(catalogue)
  local sources = catalogue:getActiveSources()
  if #sources ~= 1 or type(sources[1]) ~= 'table' then
    return nil, T('Affichez un seul dossier ou une seule collection (panneau Dossiers ou Collections), puis relancez la commande.', 'Show a single folder or a single collection (Folders or Collections panel), then run the command again.')
  end
  local source = sources[1]
  local genre = source:type()
  if genre == 'LrFolder' then
    return { nom = source:getName(), dossier = true, photos = function(sous) return source:getPhotos(sous) end }
  elseif genre == 'LrCollection' or genre == 'LrPublishedCollection' then
    return { nom = source:getName(), dossier = false, photos = function() return source:getPhotos() end }
  end
  return nil, T('Affichez un dossier ou une collection (pas un ensemble de collections), puis relancez la commande.', 'Show a folder or a collection (not a collection set), then run the command again.')
end

-- Boîte de choix : un cadre gardé pour combien, sous-dossiers. Renvoie { ratio, sousDossiers } ou nil.
local function demanderOptions(contexte, source)
  local f = LrView.osFactory()
  local proprietes = LrBinding.makePropertyTable(contexte)
  proprietes.ratio = Rafales.RATIO
  proprietes.sousDossiers = false

  local colonne = { bind_to_object = proprietes, spacing = f:control_spacing() }
  colonne[#colonne + 1] = f:static_text {
    title = T('Réduire les rafales de « ' .. source.nom .. ' ». Rien n’est supprimé : les cadres en trop sont mis '
      .. 'dans la collection « ' .. Rafales.COLLECTION .. ' », que vous vérifiez avant de les retirer.', 'Reduce the bursts of “'
      .. source.nom .. '”. Nothing is deleted: the extra frames are put in the “' .. Rafales.COLLECTION .. '” collection, which '
      .. 'you check before removing them.'),
    width = 480, height_in_lines = 3,
  }
  colonne[#colonne + 1] = f:row {
    spacing = f:label_spacing(),
    f:static_text { title = T('Garder 1 cadre sur', 'Keep 1 frame out of') },
    f:edit_field { value = LrView.bind('ratio'), width_in_digits = 3, min = 2, max = 20, precision = 0, immediate = true },
    f:static_text { title = T('(le plus net de chaque bloc ; les cadres protégés sont gardés en plus)', '(the sharpest of each block; protected frames are kept as well)') },
  }
  if source.dossier then
    colonne[#colonne + 1] = f:checkbox { title = T('Inclure les sous-dossiers', 'Include subfolders'), value = LrView.bind('sousDossiers') }
  end
  local reponse = LrDialogs.presentModalDialog {
    title = T('Réduire les rafales', 'Reduce bursts'), contents = f:column(colonne), actionVerb = T('Analyser', 'Analyse'),
  }
  if reponse ~= 'ok' then return nil end
  local ratio = math.floor(tonumber(proprietes.ratio) or Rafales.RATIO)
  return { ratio = math.max(2, ratio), sousDossiers = proprietes.sousDossiers and true or false }
end

-- Fichiers des photos : chemin, heure de prise de vue, taille, et les protections qui se lisent dans
-- les métadonnées. Renvoie nil si l'utilisateur annule, sinon les fichiers et le nombre de photos de
-- la source ignorées car elles sont déjà traitées ou dans une collection « à retirer ».
local function lireFichiers(catalogue, photos, ignorees, historique, progression)
  local fichiers, nbIgnorees = {}, 0
  local complet = Parallele.parLots(photos, TAILLE_LOT, function(lot, _, fin)
    if progression:isCanceled() then return false end
    progression:setCaption(string.format(T('Lecture des photos : %d / %d', 'Reading photos: %d / %d'), fin, #photos))
    local brutes = catalogue:batchGetRawMetadata(lot, { 'path', 'fileSize', 'dateTimeOriginal', 'isVirtualCopy',
      'countVirtualCopies', 'rating', 'pickStatus', 'colorNameForLabel' })
    local etiquettes = catalogue:batchGetFormattedMetadata(lot, { 'label' })
    for _, photo in ipairs(lot) do
      local b = brutes[photo] or {}
      if ignorees[photo.localIdentifier] or Historique.contient(historique, b.path) then
        nbIgnorees = nbIgnorees + 1
      elseif not b.isVirtualCopy and b.path and b.dateTimeOriginal then
        local raisons = {}
        if (b.rating or 0) > 0 then raisons[#raisons + 1] = T('note ', 'rating ') .. b.rating end
        if (b.pickStatus or 0) ~= 0 then raisons[#raisons + 1] = 'drapeau' end
        local libelle = (etiquettes[photo] or {}).label or ''
        if libelle ~= '' then
          raisons[#raisons + 1] = T('libellé « ' .. libelle .. ' »', 'label “' .. libelle .. '”')
        elseif LIBELLES_COULEUR[(b.colorNameForLabel or ''):lower()] then
          raisons[#raisons + 1] = T('libellé ', 'label ') .. b.colorNameForLabel
        end
        if (b.countVirtualCopies or 0) > 0 then raisons[#raisons + 1] = T('copies virtuelles', 'virtual copies') end
        fichiers[#fichiers + 1] = {
          photo = photo, id = photo.localIdentifier, chemin = b.path, t = b.dateTimeOriginal,
          taille = b.fileSize, raisons = raisons,
        }
      end
    end
    progression:setPortionComplete(fin, #photos)
  end)
  if not complet then return nil end
  return fichiers, nbIgnorees
end

-- Nom de l'ensemble de premier niveau d'une collection et libellé à afficher.
local function historiqueARetirer(rafales)
  local photos = {}
  for _, rafale in ipairs(rafales) do
    for _, cadre in ipairs(rafale) do
      if cadre.decision == 'retirer' then
        for _, f in ipairs(cadre.fichiers) do
          photos[#photos + 1] = {
            chemin = f.chemin, fichier = f.nom,
            date = Epoques.texte(Epoques.depuisLightroom(f.t, 0)),
          }
        end
      end
    end
  end
  return photos
end

local function infoCollection(collection)
  local noms = { collection:getName() }
  local parent = collection:getParent()
  while parent do
    table.insert(noms, 1, parent:getName())
    parent = parent:getParent()
  end
  return noms, table.concat(noms, ' / ')
end

-- Ajoute aux fichiers des cadres en rafale les protections qui demandent un appel par photo :
-- collections protégées, collections publiées et retouches Lightroom.
local function ajouterProtections(catalogue, rafales, progression, diagnostic, motIgnore)
  local ok, retouchees = LrTasks.pcall(function()
    return diagnostic:mesurer('recherche_retouchees_catalogue', {}, function()
      return catalogue:findPhotos { searchDesc = { criteria = 'hasAdjustments', operation = 'isTrue', value = true } }
    end)
  end)
  if not ok then error(T('impossible de savoir quelles photos sont retouchées : ', 'cannot tell which photos are edited: ') .. tostring(retouchees), 0) end
  local estRetouchee = {}
  for _, p in ipairs(retouchees) do estRetouchee[p.localIdentifier] = true end

  local total, fait = 0, 0
  for _, rafale in ipairs(rafales) do total = total + #rafale end
  for _, rafale in ipairs(rafales) do
    for _, cadre in ipairs(rafale) do
      if progression:isCanceled() then return false end
      fait = fait + 1
      progression:setCaption(string.format(T('Protections des cadres : %d / %d', 'Frame protections: %d / %d'), fait, total))
      progression:setPortionComplete(fait, total)
      for _, f in ipairs(cadre.fichiers) do
        if estRetouchee[f.id] then table.insert(f.raisons, T('retouches Lightroom', 'Lightroom edits')) end
        for _, collection in ipairs(f.photo:getContainedCollections()) do
          if not collection:isSmartCollection() then
            local noms, etiquette = infoCollection(collection)
            if Rafales.collectionProtege(noms, motIgnore) then table.insert(f.raisons, T('collection « ' .. etiquette .. ' »', 'collection “' .. etiquette .. '”')) end
          end
        end
        if #f.photo:getContainedPublishedCollections() > 0 then table.insert(f.raisons, T('collection publiée', 'published collection')) end
      end
      Rafales.proteger(cadre)
      LrTasks.yield()
    end
  end
  return true
end

local function taille(octets)
  if require('Langue').anglais() then return string.format('%.2f GB', octets / 1024 ^ 3) end
  return (string.format('%.2f Go', octets / 1024 ^ 3):gsub('%.', ','))
end

-- Mesure la netteté des cadres à comparer. Renvoie false si l'utilisateur annule.
local function mesurerNettete(rafales, progression)
  local aMesurer = Rafales.cadresAMesurer(rafales)
  if #aMesurer == 0 then return true end
  return Parallele.pourChaque(aMesurer, PARALLELE, function(cadre)
    cadre.nettete = Vignettes.nettete(cadre.mesure.chemin)
  end, progression, T('Mesure de la netteté : %d / %d', 'Measuring sharpness: %d / %d'))
end

local function ecrireRapportHtml(rafales, source, progression, magickAbsent)
  LrFileUtils.createAllDirectories(DOSSIER_APERCUS)
  local aFaire = {}
  for _, rafale in ipairs(rafales) do
    for _, cadre in ipairs(rafale) do
      local f = cadre.mesure
      if f then
        local nom = string.format('%s-%d.jpg', tostring(f.id), f.taille or 0)
        local destination = LrPathUtils.child(DOSSIER_APERCUS, nom)
        cadre.cheminApercu = destination
        cadre.nomApercu = 'vignettes/' .. nom
        if not magickAbsent and LrFileUtils.exists(destination) ~= 'file' then
          aFaire[#aFaire + 1] = { fichier = f.chemin, destination = destination }
        end
      end
    end
  end
  if #aFaire > 0 and not Parallele.pourChaque(aFaire, PARALLELE_APERCUS, function(item)
    Vignettes.apercu(item.fichier, item.destination)
  end, progression, T('Miniatures du rapport : %d / %d', 'Report thumbnails: %d / %d')) then return false end
  for _, rafale in ipairs(rafales) do
    for _, cadre in ipairs(rafale) do
      if cadre.cheminApercu and LrFileUtils.exists(cadre.cheminApercu) == 'file' then cadre.apercuRapport = cadre.nomApercu end
    end
  end
  local f = io.open(RAPPORT_HTML, 'wb')
  if not f then error(T('Impossible d’écrire le rapport HTML : ', 'Cannot write the HTML report: ') .. RAPPORT_HTML, 0) end
  local ok, erreur = f:write(RapportRafales.page(source, rafales, Rafales.bilan(rafales)))
  local ferme = f:close()
  if not ok or not ferme then error(T('Impossible d’écrire le rapport HTML : ', 'Cannot write the HTML report: ') .. tostring(erreur), 0) end
  return true
end

LrTasks.startAsyncTask(function()
  LrFunctionContext.callWithContext('reduireRafales', function(contexte)
    local etape = T('lecture de la source', 'reading the source')
    local diagnostic, issue = nil, 'annule'
    contexte:addCleanupHandler(function() if diagnostic then diagnostic:fin(issue or 'interrompu') end end)
    local ok, erreur = LrTasks.pcall(function()
      diagnostic = TraceLectures.ouvrir(DIAGNOSTIC, nil, 'reduction_rafales')
      local catalogue = LrApplication.activeCatalog()
      local source, probleme = diagnostic:mesurer('lecture_source', {}, function() return lireSource(catalogue) end)
      if not source then
        LrDialogs.message(T('Réduire les rafales', 'Reduce bursts'), probleme, 'info')
        return
      end
      diagnostic:compteurs('source', { nom = source.nom, dossier = source.dossier })
      local options = diagnostic:mesurer('attente_options', {}, function() return demanderOptions(contexte, source) end)
      if not options then return end

      local progression = LrProgressScope { title = T('Réduction des rafales', 'Reducing bursts'), functionContext = contexte }
      etape = T('lecture des photos', 'reading photos')
      -- Ignorées : les photos des collections « à retirer » et celles qui portent le mot-clé des rafales
      -- déjà traitées (la collection sera vidée une fois les cadres supprimés, le mot-clé reste).
      local ignorees = diagnostic:mesurer('recherche_exclusions', {}, function()
        local resultat = Catalogue.photosDesCollections(catalogue, { Doublons.COLLECTION, Rafales.COLLECTION })
        for id in pairs((Catalogue.photosAvecMotCle(catalogue, Rafales.MOT_CLE))) do resultat[id] = true end
        return resultat
      end)
      local historique = diagnostic:mesurer('synchronisation_historique', {}, function()
        Annulation.synchroniser(catalogue, HISTORIQUE)
        return Historique.lire(HISTORIQUE)
      end)
      local photos = diagnostic:mesurer('lecture_photos_source', { sous_dossiers = options.sousDossiers }, function()
        return source.photos(options.sousDossiers)
      end)
      local fichiers, nbIgnorees = diagnostic:mesurer('lecture_metadonnees', { photos = #photos }, function()
        return lireFichiers(catalogue, photos, ignorees, historique, progression)
      end)
      if not fichiers then return end

      diagnostic:compteurs('photos_admises', { fichiers = #fichiers, ignorees = nbIgnorees })
      etape = T('détection des rafales', 'detecting bursts')
      local cadres, rafales = diagnostic:mesurer('detection_rafales', { fichiers = #fichiers }, function()
        local resultat = Rafales.cadres(fichiers)
        return resultat, Rafales.rafales(resultat)
      end)
      diagnostic:compteurs('detection', { cadres = #cadres, rafales = #rafales })
      if #rafales == 0 then
        issue = 'termine'
        progression:done()
        LrDialogs.message(T('Réduire les rafales', 'Reduce bursts'), string.format(T(
          'Aucune rafale dans « %s » (%d cadres) : il faut au moins %d cadres à une seconde d’écart au plus, '
          .. 'avec des numéros de fichier voisins.', 'No burst in “%s” (%d frames): at least %d frames at most one second '
          .. 'apart, with neighbouring file numbers, are needed.'), source.nom, #cadres, Rafales.MIN_CADRES), 'info')
        return
      end
      Rafales.blocs(rafales, options.ratio)

      local motIgnore = LrPrefs.prefsForPlugin().motCollectionRafales
      if motIgnore == nil then motIgnore = Rafales.MOT_COLLECTION_DEFAUT end
      etape = 'protections'
      if not diagnostic:mesurer('protections', { rafales = #rafales }, function()
        return ajouterProtections(catalogue, rafales, progression, diagnostic, motIgnore)
      end) then return end

      etape = T('mesure de la netteté', 'measuring sharpness')
      local magickAbsent = diagnostic:mesurer('recherche_imagemagick', {}, function() return Vignettes.magick() == nil end)
      diagnostic:compteurs('nettete', { cadres_a_mesurer = #Rafales.cadresAMesurer(rafales), imagemagick_absent = magickAbsent })
      if not magickAbsent and not diagnostic:mesurer('mesure_nettete', {}, function()
        return mesurerNettete(rafales, progression)
      end) then return end
      diagnostic:mesurer('decisions', {}, function() Rafales.decider(rafales) end)

      etape = T('écriture du rapport', 'writing the report')
      diagnostic:mesurer('ecriture_rapport', {}, function() Csv.ecrire(RAPPORT, Rafales.lignesRapport(rafales)) end)
      etape = T('création du rapport HTML', 'creating the HTML report')
      if not diagnostic:mesurer('rapport_html', {}, function()
        return ecrireRapportHtml(rafales, source.nom, progression, magickAbsent)
      end) then return end
      progression:done()

      local bilan = Rafales.bilan(rafales)
      diagnostic:compteurs('bilan', { rafales = bilan.rafales, cadres = bilan.cadres, proteges = bilan.proteges, gardes = bilan.gardes, retires = bilan.retires, fichiers_retires = bilan.fichiersRetires })
      local sansMesure = 0
      for _, rafale in ipairs(rafales) do
        for _, c in ipairs(rafale) do
          if c.decision == 'retirer' and c.nettete == nil and c.nonMesure then
            sansMesure = sansMesure + 1
          end
        end
      end
      if bilan.retires == 0 then
        issue = 'termine'
        local choix = LrDialogs.confirm(T('Réduire les rafales', 'Reduce bursts'), string.format(T(
          '%d rafales (%d cadres) dans « %s » : rien à retirer, tous les cadres sont protégés ou seuls dans leur bloc.\n\n'
          .. 'Consultez les raisons dans le rapport et les réglages du module.\n\nDétail : %s', '%d bursts (%d frames) in “%s”: '
          .. 'nothing to remove, all frames are protected or alone in their block.\n\nSee the reasons in the report and the '
          .. 'plug-in settings.\n\nDetails: %s'), bilan.rafales, bilan.cadres, source.nom, RAPPORT_HTML),
          T('Voir le rapport', 'View the report'), T('Fermer', 'Close'))
        if choix == 'ok' then LrHttp.openUrlInBrowser(RapportHtml.urlFichier(RAPPORT_HTML)) end
        return
      end

      local message = string.format(
        T('« %s » : %d rafales, %d cadres en rafale.\n\n'
        .. '• %d cadres protégés, toujours gardés (collection, note, drapeau, libellé, retouche…)\n'
        .. '• %d cadres gardés : le plus net de chaque bloc de %d\n'
        .. '• %d cadres à retirer (%d fichiers, %s)\n\n'
        .. 'Si vous cliquez sur « Mettre de côté », ces cadres seront ajoutés à la collection « %s ». '
        .. 'Rien ne sera supprimé. Les photos de ces rafales (gardées comme retirées) recevront le mot-clé « %s » '
        .. '(non exporté) : une relance les ignore. Rapport : %s',
        '“%s”: %d bursts, %d frames in bursts.\n\n'
        .. '• %d protected frames, always kept (collection, rating, flag, label, edit…)\n'
        .. '• %d frames kept: the sharpest of each block of %d\n'
        .. '• %d frames to remove (%d files, %s)\n\n'
        .. 'If you click “Set aside”, these frames will be added to the “%s” collection. '
        .. 'Nothing will be deleted. The photos of these bursts (kept or removed) will receive the “%s” keyword '
        .. '(not exported): a new run ignores them. Report: %s'),
        source.nom, bilan.rafales, bilan.cadres, bilan.proteges, bilan.gardes, options.ratio,
        bilan.retires, bilan.fichiersRetires, taille(bilan.octetsRetires), Rafales.COLLECTION, Rafales.MOT_CLE, RAPPORT_HTML)
      if motIgnore:match('%S') then
        message = message .. string.format(T('\n\nLes collections dont le chemin contient « %s » ne protègent pas les photos. '
          .. 'Si vous retirez ensuite ces photos du catalogue, elles disparaîtront aussi de ces collections.', '\n\nCollections '
          .. 'whose path contains “%s” do not protect photos. If you then remove these photos from the catalog, they will also '
          .. 'disappear from these collections.'), motIgnore)
      end
      if nbIgnorees > 0 then
        message = message .. string.format(T('\n\n%d photos de cette source sont ignorées : déjà traitées (mot-clé « %s » ou historique) '
          .. 'ou dans les collections « à retirer ».', '\n\n%d photos of this source are ignored: already processed (“%s” '
          .. 'keyword or history) or in the “to remove” collections.'), nbIgnorees, Rafales.MOT_CLE)
      end
      if magickAbsent then
        message = message .. T('\n\nImageMagick est introuvable : la netteté n’a pas été mesurée, le premier cadre non protégé '
          .. 'de chaque bloc est gardé.', '\n\nImageMagick not found: sharpness was not measured, the first unprotected frame '
          .. 'of each block is kept.')
      elseif sansMesure > 0 then
        message = message .. string.format(T('\n\n%d cadres n’ont pas pu être mesurés (format non lu par ImageMagick, '
          .. 'RAW sans JPEG…) : le premier cadre de leur bloc est gardé.', '\n\n%d frames could not be measured (format '
          .. 'not read by ImageMagick, RAW without JPEG…): the first frame of their block is kept.'), sansMesure)
      end

      local finAttente = diagnostic:debutEtape('attente_confirmation')
      local choix
      repeat
        choix = LrDialogs.confirm(T('Mettre de côté les cadres en trop ?', 'Set aside the extra frames?'), message, T('Mettre de côté', 'Set aside'), T('Annuler', 'Cancel'), T('Voir le rapport', 'View the report'))
        if choix == 'other' then LrHttp.openUrlInBrowser(RapportHtml.urlFichier(RAPPORT_HTML)) end
      until choix ~= 'other'
      finAttente(choix == 'ok' and 'ok' or 'annule')
      if choix ~= 'ok' then return end

      etape = T('création de la collection et du mot-clé', 'creating the collection and keyword')
      local aRetirer = Rafales.photosARetirer(rafales)
      local traitees = Rafales.photosTraitees(rafales)
      local collection
      etape = T('sauvegarde des collections', 'backing up collections')
      local sauvegarde = diagnostic:mesurer('sauvegarde_collections', { photos = #traitees }, function()
        return SauvegardeCollections.sauver(catalogue, Rafales.decisionsSauvegarde(rafales),
          LrPathUtils.child(LrPathUtils.parent(_PLUGIN.path), 'sauvegardes-rafales'), 'rafales')
      end)
      diagnostic:compteurs('sauvegarde_collections', { fichier = sauvegarde })
      etape = T('création de la collection et du mot-clé', 'creating the collection and keyword')
      local finApplication = diagnostic:debutEtape('application', { photos_a_retirer = #aRetirer, photos_traitees = #traitees })
      local historiqueOk, erreurHistorique = Annulation.action(catalogue, HISTORIQUE, T('Réduire les rafales', 'Reduce bursts'),
        { type = 'rafale', photos = historiqueARetirer(rafales), temoin = traitees[1] }, function()
        collection = catalogue:createCollection(Rafales.COLLECTION, nil, true)
        if not collection then error(T('Lightroom a refusé de créer la collection « ' .. Rafales.COLLECTION .. ' ».', 'Lightroom refused to create the “' .. Rafales.COLLECTION .. '” collection.'), 0) end
        collection:addPhotos(aRetirer)
        -- Mot-clé non exporté, posé sur toutes les photos des rafales traitées.
        local motCle = catalogue:createKeyword(Rafales.MOT_CLE, {}, false, nil, true)
        if not motCle then error(T('Lightroom a refusé de créer le mot-clé « ' .. Rafales.MOT_CLE .. ' ».', 'Lightroom refused to create the “' .. Rafales.MOT_CLE .. '” keyword.'), 0) end
        for _, photo in ipairs(traitees) do photo:addKeyword(motCle) end
      end)
      finApplication(historiqueOk and 'ok' or 'historique_a_synchroniser')
      issue = 'termine'
      local messageFinal = string.format(
        T('%d cadres (%d fichiers) sont dans la collection « %s ».\n\n'
        .. 'Pour terminer le retrait, sélectionnez uniquement ces copies dans « Catalogue → Toutes les photos », '
        .. 'puis Suppr → « Retirer » (espace récupérable sur disque : %s).\n\n'
        .. 'Les photos de ces rafales ont reçu le mot-clé « %s » : les prochaines réductions les ignorent, même une '
        .. 'fois la collection vidée. Les fichiers retirés sont mémorisés dans %s. Pour les retraiter, supprimez '
        .. 'leurs lignes de cet historique et ôtez le mot-clé de toutes les photos de la rafale.',
        '%d frames (%d files) are in the “%s” collection.\n\n'
        .. 'To finish removing them, select only these copies in “Catalog → All Photographs”, '
        .. 'then Delete → “Remove” (disk space that can be recovered: %s).\n\n'
        .. 'The photos of these bursts received the “%s” keyword: later reductions ignore them, even once the '
        .. 'collection is emptied. The removed files are saved in %s. To process them again, delete their lines from '
        .. 'this history and remove the keyword from all photos of the burst.'),
        bilan.retires, bilan.fichiersRetires, Rafales.COLLECTION, taille(bilan.octetsRetires), Rafales.MOT_CLE, HISTORIQUE)
        .. T('\n\nCtrl+Z annule la réduction complète : collection, mot-clé et historique des exclusions.', '\n\nCtrl+Z undoes the whole reduction: collection, keyword and history of exclusions.')
        .. T('\n\nSauvegarde des collections d’origine :\n', '\n\nBackup of the original collections:\n') .. sauvegarde
      if not historiqueOk then messageFinal = messageFinal .. T('\nHistorique texte à synchroniser : ', '\nText history to synchronise: ') .. tostring(erreurHistorique) end
      LrDialogs.message(T('Rafales mises de côté', 'Bursts set aside'), messageFinal, historiqueOk and 'info' or 'warning')
    end)
    if not ok then
      issue = 'erreur'
      if diagnostic then diagnostic:compteurs('erreur', { etape = etape, message = tostring(erreur) }) end
      LrDialogs.message(T('Erreur pendant la réduction des rafales', 'Error while reducing bursts'),
        string.format(T('Étape : %s\n%s', 'Step: %s\n%s'), etape, tostring(erreur)), 'critical')
    end
  end)
end)
