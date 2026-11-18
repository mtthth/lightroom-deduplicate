-- Fusionne en un seul groupe les photos ou vidéos explicitement sélectionnées par l'utilisateur.
-- Contrairement à « Fusionner les doublons », cette commande ne cherche pas à reconnaître les images :
-- la sélection elle-même désigne le groupe à fusionner.

local LrApplication = import 'LrApplication'
local LrBinding = import 'LrBinding'
local LrDialogs = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrPathUtils = import 'LrPathUtils'
local LrProgressScope = import 'LrProgressScope'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'

local Catalogue = dofile(LrPathUtils.child(_PLUGIN.path, 'Catalogue.lua'))
local TraceLectures = dofile(LrPathUtils.child(_PLUGIN.path, 'TraceLectures.lua'))
local CollectionsRapides = dofile(LrPathUtils.child(_PLUGIN.path, 'CollectionsRapides.lua'))
local CopiesVirtuelles = dofile(LrPathUtils.child(_PLUGIN.path, 'CopiesVirtuelles.lua'))
local SauvegardeCollections = dofile(LrPathUtils.child(_PLUGIN.path, 'SauvegardeCollections.lua'))
local Annulation = require 'Annulation'
local Doublons = require 'Doublons'
local T = require('Langue').t
Doublons.reglerDossiers(import('LrPrefs').prefsForPlugin())   -- mots des dossiers mal rangés (Reglages.lua)
local Empreintes = require 'Empreintes'
local Epoques = require 'Epoques'
local Historique = require 'Historique'
local Noms = require 'Noms'

local COLLECTION_DOUBLONS = Doublons.COLLECTION
local CORBEILLES = { [Doublons.COLLECTION] = true, ['Rafales à retirer'] = true }
local DOSSIER_PROJET = LrPathUtils.parent(_PLUGIN.path)
local HISTORIQUE = require('HistoriqueCommun').chemins()

local function nomFichier(chemin)
  return chemin:match('[^/\\]+$') or chemin
end

local function cleChemin(chemin)
  return (chemin or ''):gsub('/', '\\'):lower()
end

local function selection(catalogue)
  if not catalogue:getTargetPhoto() then return {} end
  local vus, photos = {}, {}
  for _, photo in ipairs(catalogue:getTargetPhotos()) do
    if not vus[photo.localIdentifier] then
      vus[photo.localIdentifier] = true
      photos[#photos + 1] = photo
    end
  end
  return photos
end

local function lireCopies(catalogue, photos)
  local brutes = catalogue:batchGetRawMetadata(photos,
    { 'path', 'fileSize', 'dateTimeOriginal', 'isVirtualCopy', 'masterPhoto', 'countVirtualCopies',
      'width', 'height', 'dimensions', 'isVideo', 'fileFormat', 'durationInSeconds' })
  local copies = {}
  for _, photo in ipairs(photos) do
    local b = brutes[photo] or {}
    if not b.path then
      return nil, T('Au moins une photo ou vidéo sélectionnée n’a pas de chemin de fichier lisible dans le catalogue.', 'At least one selected photo or video has no readable file path in the catalog.')
    end
    local dimensions = type(b.dimensions) == 'table' and b.dimensions or {}
    local largeur, hauteur = tonumber(b.width or dimensions.width), tonumber(b.height or dimensions.height)
    copies[#copies + 1] = {
      photo = photo, id = photo.localIdentifier, chemin = b.path, taille = b.fileSize,
      octets = b.fileSize or 0, date = b.dateTimeOriginal, virtuelles = b.countVirtualCopies or 0,
      virtuelle = b.isVirtualCopy or false, maitre = b.masterPhoto,
      video = b.isVideo or b.fileFormat == 'VIDEO' or Empreintes.estVideo(b.path),
      duree = tonumber(b.durationInSeconds),
      collections = {}, motsCles = {}, textes = {}, note = 0, drapeau = 0,
      largeur = largeur, hauteur = hauteur,
      pixels = largeur and hauteur and largeur > 0 and hauteur > 0 and largeur * hauteur or nil,
    }
  end
  return copies
end

local function completerDetails(catalogue, copies, progression, diagnostic)
  progression:setCaption(T('Lecture des métadonnées de la sélection…', 'Reading the metadata of the selection…'))

  local photos, parPhoto = {}, {}
  for _, c in ipairs(copies) do
    photos[#photos + 1] = c.photo
    parPhoto[c.photo] = c
  end
  progression:setCaption(T('Lecture des notes, drapeaux, mots-clés et GPS…', 'Reading ratings, flags, keywords and GPS…'))
  local brutes = catalogue:batchGetRawMetadata(photos, { 'rating', 'pickStatus', 'keywords', 'gps' })
  if progression:isCanceled() then return end
  local champs = { 'copyName' }
  for _, cle in ipairs(Doublons.CHAMPS_TEXTE) do champs[#champs + 1] = cle end
  progression:setCaption(T('Lecture des textes des photos…', 'Reading the photos’ texts…'))
  local formatees = catalogue:batchGetFormattedMetadata(photos, champs)
  if progression:isCanceled() then return end
  for _, c in ipairs(copies) do diagnostic.chemins[c.photo] = c.chemin end
  local appartenances = diagnostic:mesurer('collections_publications', { photos = #photos }, function()
    return CollectionsRapides.lire(catalogue, photos, progression, CORBEILLES, true, diagnostic)
  end)
  if not appartenances then return end
  for _, photo in ipairs(photos) do
    if progression:isCanceled() then return end
    local c, b, f = parPhoto[photo], brutes[photo] or {}, formatees[photo] or {}
    c.note, c.drapeau, c.gps = b.rating or 0, b.pickStatus or 0, b.gps
    c.nomCopie = f.copyName or ''
    for _, mot in ipairs(b.keywords or {}) do c.motsCles[#c.motsCles + 1] = { objet = mot, nom = mot:getName() } end
    c.textes = {}
    for _, cle in ipairs(Doublons.CHAMPS_TEXTE) do c.textes[cle] = f[cle] or '' end
    c.publiee = appartenances[photo].publiee
    c.collections = appartenances[photo].collections
  end
end

local function decrireCopie(c)
  return (c.video and T('vidéo · ', 'video · ') or '')
    .. (c.pixels and string.format('%d × %d px', c.largeur, c.hauteur) or T('résolution inconnue', 'unknown resolution'))
    .. (c.video and c.duree and string.format(' · %.1f s', c.duree) or '')
    .. string.format(T(' · %d étoile(s)', ' · %d star(s)'), c.note or 0)
    .. (c.taille and string.format(T(' · %.2f Mo', ' · %.2f MB'), c.taille / 1024 / 1024) or T(' · poids inconnu', ' · unknown size'))
    .. (c.virtuelle and (T(' · copie virtuelle', ' · virtual copy') .. (c.nomCopie ~= '' and T(' « ' .. c.nomCopie .. ' »', ' “' .. c.nomCopie .. '”') or '')) or '')
end

local function choisirGardee(contexte, copies, parResolution)
  local f = LrView.osFactory()
  local proprietes = LrBinding.makePropertyTable(contexte)
  local choix = {}
  local originaux = {}
  for _, c in ipairs(copies) do if not c.virtuelle then originaux[cleChemin(c.chemin)] = true end end
  local avecOriginalSelectionne = false
  local avecOriginalEcarte = false
  for _, c in ipairs(copies) do
    local originalEcarte = false
    if c.virtuelle and c.maitre then
      for _, collection in ipairs(c.maitre:getContainedCollections()) do
        if CORBEILLES[collection:getName()] then originalEcarte = true; break end
      end
    end
    -- Retirer l'original du catalogue retirerait aussi sa copie virtuelle : elle ne peut pas être
    -- la gardée quand cet original est sélectionné ou déjà mis à retirer hors de la sélection.
    if c.virtuelle and originaux[cleChemin(c.chemin)] then
      avecOriginalSelectionne = true
    elseif originalEcarte then
      avecOriginalEcarte = true
    else
      choix[#choix + 1] = {
        title = (#choix == 0 and T('Conseillée — ', 'Recommended — ') or '') .. decrireCopie(c) .. ' — ' .. c.chemin, value = c.id,
      }
    end
  end
  if #choix == 0 then
    LrDialogs.message(T('Fusion manuelle impossible', 'Manual merge not possible'), T('Aucune photo de la sélection ne peut être gardée : '
      .. 'les originaux de ces copies virtuelles sont dans une collection « à retirer ». '
      .. 'Rétablissez d’abord leurs originaux avant de relancer la fusion.', 'No photo of the selection can be kept: the '
      .. 'originals of these virtual copies are in a “to remove” collection. Restore their originals first, then run the '
      .. 'merge again.'), 'warning')
    return nil
  end
  proprietes.gardee = choix[1].value
  local reponse = LrDialogs.presentModalDialog {
    title = T('Fusion manuelle', 'Manual merge'),
    contents = f:column {
      bind_to_object = proprietes,
      spacing = f:control_spacing(),
      f:static_text {
        title = string.format(T('%d photos ou vidéos sélectionnées seront traitées comme un seul groupe, sans comparaison '
          .. 'de leur contenu. Choisissez la copie qui récupère les albums et métadonnées. Les autres quitteront leurs '
          .. 'collections ordinaires et seront placées dans « %s ». Elles restent dans le catalogue jusqu’à leur retrait manuel.',
          '%d selected photos or videos will be treated as a single group, without comparing their content. Choose the '
          .. 'copy that receives the albums and metadata. The others will leave their ordinary collections and be placed in '
          .. '“%s”. They stay in the catalog until you remove them.'),
          #copies, COLLECTION_DOUBLONS),
        width = 560, height_in_lines = 5,
      },
      f:static_text {
        title = parResolution
          and T('Proposition : plus grande résolution, puis meilleure note, puis nom le plus simple.',
            'Proposal: highest resolution, then best rating, then simplest name.')
          or T('Résolution incomplète : proposition selon la note puis le nom ; le poids départage les égalités.',
            'Incomplete resolution: proposal by rating then name; file size breaks ties.'),
        width = 560, height_in_lines = 2,
      },
      f:static_text { title = T('Copie à garder (la proposition est présélectionnée) :', 'Copy to keep (the proposal is preselected):') },
      f:popup_menu { value = LrView.bind('gardee'), items = choix, width_in_chars = 72 },
      f:static_text {
        title = avecOriginalSelectionne
          and T('Une copie virtuelle et son original sont sélectionnés : gardez un original pour conserver le fichier support.', 'A virtual copy and its original are selected: keep an original to keep the underlying file.') or '',
        visible = avecOriginalSelectionne, width = 560, height_in_lines = 2,
      },
      f:static_text {
        title = avecOriginalEcarte
          and T('Les copies virtuelles dont l’original est dans une collection « à retirer » ne peuvent pas être gardées. '
            .. 'Rétablissez d’abord leur original si vous voulez les conserver.', 'Virtual copies whose original is in a “to '
            .. 'remove” collection cannot be kept. Restore their original first if you want to keep them.') or '',
        visible = avecOriginalEcarte, width = 560, height_in_lines = 3,
      },
    },
    actionVerb = 'Continuer',
  }
  if reponse ~= 'ok' then return nil end
  for _, c in ipairs(copies) do if c.id == proprietes.gardee then return c end end
  return nil
end

local function decrireCollections(decision)
  local albums, autres = {}, {}
  local prefixe = Noms.ENSEMBLE_ALBUMS .. ' / '
  for _, col in ipairs(decision.effets.collectionsFinales) do
    local liste = col.nom:sub(1, #prefixe) == prefixe and albums or autres
    liste[#liste + 1] = col.nom
  end
  table.sort(albums)
  table.sort(autres)
  local texte = #albums > 0 and (T('Albums après fusion (', 'Albums after merging (') .. #albums .. T(') :\n• ', '):\n• ') .. table.concat(albums, '\n• '))
    or T('Albums après fusion : aucun album Google Photos dans les appartenances actuelles de la sélection.',
      'Albums after merging: no Google Photos album in the current memberships of the selection.')
  if #autres > 0 then
    texte = texte .. T('\n\nAutres collections après fusion :\n• ', '\n\nOther collections after merging:\n• ') .. table.concat(autres, '\n• ')
  end
  return texte
end

local SANS_PROGRESSION = {
  isCanceled = function() return false end, setCaption = function() end, setPortionComplete = function() end,
}

local function appliquer(catalogue, decision, diagnostic)
  -- Copies virtuelles des copies écartées : lues avant la sauvegarde, qui les inclut, et créées sur la copie
  -- gardée avant l'accès en écriture de la fusion (voir CopiesVirtuelles.lua).
  local virtuelles = diagnostic:mesurer('copies_virtuelles_lecture', {}, function()
    return CopiesVirtuelles.lire(catalogue, { decision }, function(photos)
      return CollectionsRapides.lire(catalogue, photos, SANS_PROGRESSION, CORBEILLES, true, diagnostic)
    end)
  end)
  local sauvegarde = SauvegardeCollections.sauver(catalogue, CopiesVirtuelles.pourSauvegarde({ decision }),
    LrPathUtils.child(DOSSIER_PROJET, 'sauvegardes-fusions'), 'forcee')
  diagnostic:mesurer('copies_virtuelles_creation', { copies = #virtuelles }, function()
    CopiesVirtuelles.creer(catalogue, virtuelles, CORBEILLES)
  end)
  local photos = {}
  for _, c in ipairs(decision.retirees) do
    if not c.virtuelle and cleChemin(c.chemin) ~= cleChemin(decision.garde.chemin) then
      photos[#photos + 1] = {
        chemin = c.chemin, fichier = nomFichier(c.chemin),
        date = c.date and Epoques.texte(Epoques.depuisLightroom(c.date, 0)) or '',
      }
    end
  end
  local corbeille
  local ok, historiqueOk, erreurHistorique = LrTasks.pcall(Annulation.action, catalogue, HISTORIQUE, T('Fusion manuelle de photos et vidéos', 'Manual merge of photos and videos'),
    { retablir = { decision.garde.chemin }, type = 'doublon', photos = photos, temoin = decision.garde.photo }, function()
    corbeille = catalogue:createCollection(COLLECTION_DOUBLONS, nil, true)
    local e, garde = decision.effets, decision.garde.photo
    for _, col in ipairs(e.corbeillesGardee) do col.objet:removePhotos({ garde }) end
    for _, col in ipairs(e.collections) do col.objet:addPhotos({ garde }) end
    for _, q in ipairs(e.quittees) do q.collection.objet:removePhotos({ q.copie.photo }) end
    for _, mot in ipairs(e.motsCles) do garde:addKeyword(mot.objet) end
    if e.note then garde:setRawMetadata('rating', e.note) end
    if e.drapeau then garde:setRawMetadata('pickStatus', e.drapeau) end
    for _, t in ipairs(e.textes) do garde:setRawMetadata(t.cle, t.valeur) end
    if e.gps then garde:setRawMetadata('gps', e.gps) end
    local retirees = {}
    for i, c in ipairs(decision.retirees) do retirees[i] = c.photo end
    corbeille:addPhotos(retirees)
    corbeille:removePhotos({ garde })
    for _, e in ipairs(virtuelles) do CopiesVirtuelles.appliquer(e, corbeille) end
  end)
  if not ok then error(CopiesVirtuelles.completerErreur(historiqueOk, virtuelles), 0) end
  for _, col in ipairs(decision.garde.photo:getContainedCollections()) do
    if CORBEILLES[col:getName()] then
      error(T('La copie gardée est encore dans « ' .. col:getName() .. ' ». Ne retirez aucune photo ou vidéo du catalogue.', 'The kept copy is still in “' .. col:getName() .. '”. Do not remove any photo or video from the catalog.'), 0)
    end
  end
  if historiqueOk and Historique.contient(Historique.lire(HISTORIQUE), decision.garde.chemin) then
    error(T('La copie gardée reste exclue dans l’historique. Ne retirez aucune photo ou vidéo du catalogue.', 'The kept copy is still excluded in the history. Do not remove any photo or video from the catalog.'), 0)
  end
  local ecarts = diagnostic:mesurer('copies_virtuelles_verification', { copies = #virtuelles }, function()
    return CopiesVirtuelles.verifier(virtuelles)
  end)
  return historiqueOk, erreurHistorique, sauvegarde, CopiesVirtuelles.bilan(virtuelles, ecarts, COLLECTION_DOUBLONS)
end

LrTasks.startAsyncTask(function()
  LrFunctionContext.callWithContext('fusionManuelle', function(contexte)
    local etape = T('lecture de la sélection', 'reading the selection')
    local diagnostic, issue
    contexte:addCleanupHandler(function() if diagnostic then diagnostic:fin(issue or 'interrompu') end end)
    local ok, erreur = LrTasks.pcall(function()
      diagnostic = TraceLectures.ouvrir(LrPathUtils.child(DOSSIER_PROJET, 'diagnostic-lectures-fusion-forcee.txt'), nil, 'fusion_forcee')
      local catalogue = diagnostic:mesurer('catalogue_actif', {}, function() return LrApplication.activeCatalog() end)
      local photos = diagnostic:mesurer('selection_grille', {}, function() return selection(catalogue) end)
      if #photos < 2 then
        LrDialogs.message(T('Fusion manuelle', 'Manual merge'), T('Sélectionnez au moins deux photos ou vidéos dans la grille ou la pellicule.', 'Select at least two photos or videos in the grid or the filmstrip.'), 'info')
        return
      end

      local progression = diagnostic:mesurer('barre_progression', { photos = #photos }, function()
        return LrProgressScope { title = T('Fusion manuelle', 'Manual merge'), functionContext = contexte }
      end)
      diagnostic.progression = progression
      local copies, message = diagnostic:mesurer('lecture_selection', { photos = #photos }, function() return lireCopies(catalogue, photos) end)
      if not copies then progression:done(); LrDialogs.message(T('Fusion manuelle impossible', 'Manual merge not possible'), message, 'critical'); return end
      etape = T('lecture des métadonnées', 'reading metadata')
      diagnostic:mesurer('metadonnees_selection', { photos = #photos }, function() completerDetails(catalogue, copies, progression, diagnostic) end)
      if progression:isCanceled() then progression:done(); return end
      local parResolution = Doublons.classerManuellement(copies)
      progression:done()

      local garde = diagnostic:mesurer('attente_choix_copie', {}, function() return choisirGardee(contexte, copies, parResolution) end)
      if not garde then return end
      local finPreparation = diagnostic:debutEtape('preparation_confirmation', {})
      local retirees = {}
      for _, c in ipairs(copies) do if c ~= garde then retirees[#retirees + 1] = c end end
      local decision = { garde = garde, retirees = retirees }
      -- La sélection n'est pas comparée au catalogue des retouches : chaque copie écartée est signalée.
      local avertissements = Doublons.avertissements(decision, false)
      decision.effets = Doublons.effets(decision)

      local lignes = {}
      for _, c in ipairs(retirees) do
        lignes[#lignes + 1] = '• ' .. c.chemin
          .. (c.virtuelle and (T(' (copie virtuelle', ' (virtual copy') .. (c.nomCopie ~= '' and T(' « ' .. c.nomCopie .. ' »', ' “' .. c.nomCopie .. '”') or '') .. ')') or '')
      end
      local texteDestination = decrireCollections(decision)
      if #decision.effets.corbeillesGardee > 0 then
        texteDestination = texteDestination .. T('\n\nLa copie gardée sera sortie des collections « à retirer » où elle se trouve déjà.', '\n\nThe kept copy will be taken out of the “to remove” collections it is already in.')
      end
      local messageConfirmation = T('Copie gardée :\n', 'Kept copy:\n') .. garde.chemin .. '\n' .. decrireCopie(garde)
        .. '\n\n' .. texteDestination .. T('\n\nCopies qui seront mises dans « ' .. COLLECTION_DOUBLONS .. ' » :\n',
          '\n\nCopies that will be put in “' .. COLLECTION_DOUBLONS .. '”:\n') .. table.concat(lignes, '\n')
        .. T('\n\nMétadonnées : note la plus haute, mots-clés réunis, drapeau retenu prioritaire sur rejeté ; '
        .. 'textes et GPS de la copie gardée conservés, champs vides complétés avec les autres copies.'
        .. '\nLes fichiers retirés seront mémorisés dans photos-traitees.txt.'
        .. '\nUne sauvegarde texte des collections d’origine sera créée avant la fusion dans sauvegardes-fusions.',
        '\n\nMetadata: highest rating, keywords combined, “picked” flag wins over “rejected”; texts and GPS of the kept '
        .. 'copy kept, empty fields filled from the other copies.'
        .. '\nThe removed files will be saved in photos-traitees.txt.'
        .. '\nA text backup of the original collections will be written to sauvegardes-fusions before merging.')
      local annonces = Doublons.annoncesVirtuelles(decision)
      if #annonces > 0 then
        messageConfirmation = messageConfirmation .. T('\n\nCopies virtuelles recréées :\n• ', '\n\nVirtual copies recreated:\n• ') .. table.concat(annonces, '\n• ')
          .. T('\nChacune devient une copie virtuelle de la copie gardée, avec son nom, ses réglages, métadonnées et '
          .. 'collections, mais sans son historique ni ses instantanés. Les anciennes rejoignent « ' .. COLLECTION_DOUBLONS
          .. ' ». Celles qui font partie de la sélection sont fusionnées comme les autres copies.', '\nEach becomes a virtual '
          .. 'copy of the kept copy, with its name, settings, metadata and collections, but without its history or snapshots. '
          .. 'The old ones join “' .. COLLECTION_DOUBLONS .. '”. Those that are part of the selection are merged like the other copies.')
      end
      if #avertissements > 0 then
        messageConfirmation = messageConfirmation .. T('\n\nÉléments non transférés :\n• ', '\n\nNot transferred:\n• ')
          .. table.concat(avertissements, '\n• ')
          .. T('\nLes coupes et réglages vidéo, les réglages de développement, les copies virtuelles de vidéos et les '
          .. 'appartenances publiées restent sur les copies écartées tant qu’elles sont au catalogue. Leur retrait '
          .. 'ultérieur fera perdre ces éléments.', '\nVideo trims and settings, develop settings, virtual copies of videos '
          .. 'and published memberships stay on the discarded copies as long as they are in the catalog. Removing them later '
          .. 'will lose these.')
      end
      finPreparation('ok')
      local choix = diagnostic:mesurer('attente_confirmation', {}, function()
        return LrDialogs.confirm(T('Confirmer la fusion manuelle ?', 'Confirm the manual merge?'), messageConfirmation, T('Fusionner de force', 'Force merge'), T('Annuler', 'Cancel'))
      end)
      if choix ~= 'ok' then issue = 'annule'; return end

      etape = T('préparation de l’historique et fusion annulable', 'preparing the history and undoable merge')
      local historiqueOk, erreurHistorique, sauvegarde, bilanVirtuelles = diagnostic:mesurer('sauvegarde_et_application_fusion', { photos = #copies }, function()
        return appliquer(catalogue, decision, diagnostic)
      end)
      issue = 'fusion_appliquee'
      local bilan = string.format(T('%d photos ou vidéos fusionnées. Copie gardée :\n%s\n\n%s\n\nLes %d autres sont dans « %s ».',
        '%d photos or videos merged. Kept copy:\n%s\n\n%s\n\nThe %d others are in “%s”.'),
        #copies, garde.chemin, texteDestination, #retirees, COLLECTION_DOUBLONS)
        .. T('\nLa copie gardée a été vérifiée hors des collections de retrait. Les copies écartées restent visibles '
        .. 'dans les dossiers tant qu’elles ne sont pas retirées du catalogue.'
        .. '\nCtrl+Z annule cette fusion complète, y compris l’historique des exclusions.', '\nThe kept copy was checked to '
        .. 'be out of the removal collections. The discarded copies stay visible in folders as long as they are not removed '
        .. 'from the catalog.\nCtrl+Z undoes this whole merge, including the history of exclusions.')
        .. bilanVirtuelles
        .. T('\n\nSauvegarde des collections d’origine :\n', '\n\nBackup of the original collections:\n') .. sauvegarde
      if historiqueOk then
        LrDialogs.message(T('Fusion manuelle terminée', 'Manual merge done'), bilan .. T('\nHistorique enregistré dans photos-traitees.txt.', '\nHistory saved in photos-traitees.txt.'), 'info')
      else
        LrDialogs.message(T('Fusion effectuée, historique non enregistré', 'Merge done, history not saved'), bilan
          .. T('\n\nLa fusion a bien été appliquée. Gardez les copies dans cette collection tant que l’historique '
          .. 'n’est pas enregistré.\n', '\n\nThe merge has been applied. Keep the copies in this collection until the '
          .. 'history is saved.\n') .. tostring(erreurHistorique), 'warning')
      end
    end)
    if not ok then
      issue = 'erreur'
      LrDialogs.message(T('Erreur pendant la fusion manuelle', 'Error during the manual merge'), string.format(T('Étape : %s\n%s', 'Step: %s\n%s'), etape, tostring(erreur)), 'critical')
    end
  end)
end)
