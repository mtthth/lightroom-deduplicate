-- Lectures dans le catalogue partagées par les commandes du module.

local LrTasks = import 'LrTasks'

local M = {}

-- Regroupe les lectures SDK sous un seul accès au catalogue. Sans cet accès explicite,
-- Lightroom ouvre/ferme un accès implicite pour chaque getName/getParent/getContained…
-- (coûteux lorsque d'autres tâches sollicitent le catalogue). Aucune écriture ici,
-- et l'accès privé ne crée pas d'étape dans l'historique d'annulation.
-- Le callback doit uniquement lire le catalogue ; ne pas y faire de calcul disque ni de dialogue.
function M.lectureGroupee(catalogue, lire, messageOccupe)
  local resultat
  local statut = catalogue:withPrivateWriteAccessDo(function()
    resultat = lire()
  end, { timeout = 5 })
  if statut ~= 'executed' then
    error(messageOccupe or require('Langue').t('Le catalogue est occupé : lecture interrompue après 5 secondes. Aucune fusion n’a été appliquée.', 'The catalog is busy: reading stopped after 5 seconds. No merge was applied.'), 0)
  end
  return resultat
end

-- Collections ordinaires et publications des seules photos candidates. Petits lots pour
-- relâcher l'accès entre deux lectures, caches limités à cette analyse (jamais persistants).
function M.lireAppartenances(catalogue, photos, progression, corbeilles, complet, diagnostic)
  local resultats, collections, chemins = {}, {}, {}
  local function appel(contexte, operation, lire)
    if diagnostic then return diagnostic:appel(contexte, operation, lire) end
    return lire()
  end
  for debut = 1, #photos, 25 do
    if progression:isCanceled() then return nil end
    local fin = math.min(debut + 24, #photos)
    progression:setCaption(string.format(require('Langue').t('Lecture des collections et publications : %d / %d', 'Reading collections and publications: %d / %d'), debut, #photos))
    local lot = { numero = debut, total = #photos, id = photos[debut].localIdentifier,
      chemin = diagnostic and diagnostic.chemins[photos[debut]] }
    local termine = appel(lot, 'accès au catalogue (lot ' .. debut .. '-' .. fin .. ')', function()
      return M.lectureGroupee(catalogue, function()
      for i = debut, fin do
        if progression:isCanceled() then return false end
        local photo = photos[i]
        local contexte = { numero = i, total = #photos, id = photo.localIdentifier,
          chemin = diagnostic and diagnostic.chemins[photo] }
        local publiees = appel(contexte, 'getContainedPublishedCollections', function()
          return photo:getContainedPublishedCollections()
        end)
        local info = { collections = {}, publiee = #publiees > 0 }
        local contenues = appel(contexte, 'getContainedCollections', function() return photo:getContainedCollections() end)
        for _, collection in ipairs(contenues) do
          local id = collection.localIdentifier
          local col = collections[id]
          if not col then
            local nom, nomInitial = M.etiquetteCollection(collection, complet, nil, chemins,
              diagnostic and function(objet, operation, lire, nomConnu)
                local c = { numero = i, total = #photos, id = photo.localIdentifier, chemin = contexte.chemin,
                  collection = objet.localIdentifier, nom = nomConnu }
                return appel(c, operation, lire)
              end)
            -- getContainedCollections n'inclut pas les collections dynamiques (SDK).
            col = { objet = collection, id = id, nom = nom, dynamique = false,
              exclue = corbeilles[nomInitial] or false }
            collections[id] = col
          end
          info.collections[#info.collections + 1] = col
        end
        resultats[photo] = info
      end
      return true
      end)
    end)
    if not termine then
      if diagnostic then diagnostic:terminer('Annulé') end
      return nil
    end
    progression:setPortionComplete(fin, #photos)
    LrTasks.yield()
  end
  if progression:isCanceled() then
    if diagnostic then diagnostic:terminer('Annulé') end
    return nil
  end
  if diagnostic then diagnostic:terminer('Lecture terminée') end
  return resultats
end

-- Identifiants (localIdentifier) des photos des collections de premier niveau portant l'un des
-- noms de `noms` (par exemple « Doublons à retirer » et « Rafales à retirer », où les commandes
-- mettent les photos en trop en attendant que vous les retiriez du catalogue), et leur nombre.
-- Une erreur de lecture donne une liste vide : la commande continue sans ignorer ces photos.
-- `strict` laisse au contraire remonter l'erreur (vérification après fusion : une lecture ratée ne doit
-- pas passer pour une absence de photos).
function M.photosDesCollections(catalogue, noms, strict)
  local voulus = {}
  for _, nom in ipairs(noms) do voulus[nom] = true end
  local ids, nb = {}, 0
  local function lire()
    for _, collection in ipairs(catalogue:getChildCollections()) do
      if voulus[collection:getName()] then
        for _, photo in ipairs(collection:getPhotos()) do
          if not ids[photo.localIdentifier] then nb = nb + 1 end
          ids[photo.localIdentifier] = true
        end
      end
    end
  end
  if strict then lire() else LrTasks.pcall(lire) end
  return ids, nb
end

-- Identifiants des photos qui portent le mot-clé `nom` (à n'importe quel niveau de la hiérarchie des
-- mots-clés), et leur nombre. Une erreur de lecture, ou un mot-clé absent, donne une liste vide.
function M.photosAvecMotCle(catalogue, nom)
  local ids, nb = {}, 0
  LrTasks.pcall(function()
    local visites = 0
    local function chercher(motsCles)
      for _, motCle in ipairs(motsCles) do
        visites = visites + 1
        if motCle:getName() == nom then
          for _, photo in ipairs(motCle:getPhotos()) do
            if not ids[photo.localIdentifier] then nb = nb + 1 end
            ids[photo.localIdentifier] = true
          end
        end
        -- Garde-fou : une hiérarchie démesurée ne doit pas bloquer la commande.
        if visites < 50000 then chercher(motCle:getChildren()) end
      end
    end
    chercher(catalogue:getKeywords())
  end)
  return ids, nb
end

local NOMS_SOURCES = {
  kAllPhotos = 'Toutes les photos du catalogue', kPreviousImport = 'Dernier import',
  kQuickCollection = 'Collection rapide', kTargetCollection = 'Collection cible',
}

-- Nom de la source affichée dans la grille (dossier, collection…), ou nil.
local function nomSources(catalogue)
  local noms = {}
  LrTasks.pcall(function()
    for _, source in ipairs(catalogue:getActiveSources()) do
      noms[#noms + 1] = type(source) == 'table' and source:getName() or NOMS_SOURCES[source] or tostring(source)
    end
  end)
  return #noms > 0 and table.concat(noms, ' + ') or nil
end

-- Photos sur lesquelles travaille une commande de recherche : les photos sélectionnées s'il y en a au
-- moins deux, sinon toutes les photos affichées dans la grille (dossier, collection, tout le catalogue…).
-- Renvoie { photos, genre = 'selection' ou 'affichees', nom = nom de la source affichée (ou nil) }.
function M.portee(catalogue)
  local nom = nomSources(catalogue)
  -- getTargetPhoto vaut nil quand rien n'est sélectionné ; getTargetPhotos renverrait alors toute la grille.
  if catalogue:getTargetPhoto() then
    local selection = catalogue:getTargetPhotos()
    if #selection >= 2 then return { photos = selection, genre = 'selection', nom = nom } end
  end
  -- Une seule photo sélectionnée, ou aucune : getMultipleSelectedOrAllPhotos renvoie toute la grille.
  return { photos = catalogue:getMultipleSelectedOrAllPhotos(), genre = 'affichees', nom = nom }
end

-- Étiquette d'une collection pour l'affichage : « Ensemble / Collection » (ensemble de premier niveau
-- et collection elle-même ; les niveaux intermédiaires sont omis).
-- `complet` conserve aussi les années et les autres ensembles intermédiaires.
function M.etiquetteCollection(collection, complet, progressionEtape, cache, appel)
  cache = cache or {}
  local function lire(objet)
    local cle = objet.localIdentifier or objet
    if cache[cle] then return cache[cle].nom, cache[cle].parent end
    if progressionEtape then progressionEtape('nom') end
    local nom = appel and appel(objet, 'getName', function() return objet:getName() end) or objet:getName()
    if progressionEtape then progressionEtape('parent') end
    local parent
    if appel then parent = appel(objet, 'getParent', function() return objet:getParent() end, nom)
    else parent = objet:getParent() end
    cache[cle] = { nom = nom, parent = parent }
    return nom, parent
  end
  local nomInitial, parent = lire(collection)
  local noms = { nomInitial }
  local visites, profondeur = {}, 0
  while parent do
    profondeur = profondeur + 1
    local id = parent.localIdentifier
    if profondeur > 100 or (id and visites[id]) then
      error(require('Langue').t('Hiérarchie de collections invalide ou trop profonde : lecture interrompue.', 'Invalid or too deep collection hierarchy: reading stopped.'), 0)
    end
    if id then visites[id] = true end
    local nom
    nom, parent = lire(parent)
    table.insert(noms, 1, nom)
  end
  return complet and table.concat(noms, ' / ') or (#noms == 1 and noms[1] or (noms[1] .. ' / ' .. noms[#noms])), nomInitial
end

return M
