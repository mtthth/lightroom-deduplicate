-- Copies virtuelles des copies écartées : la fusion les recrée sur la copie gardée, puisqu'elles
-- disparaîtraient avec leur original lors de son retrait du catalogue.
--
-- Sont concernées les copies virtuelles des copies écartées, sauf celles des vidéos (applyDevelopSettings
-- ne vaut que pour les images), celles qui font elles-mêmes partie du groupe (fusion manuelle) et celles
-- qui sont déjà dans une collection « à retirer ».
--   1. Après confirmation, leurs réglages, nom de copie, métadonnées et collections sont lus (lire).
--   2. Une copie virtuelle de la photo gardée est créée pour chacune, avec le même nom de copie (creer).
--      createVirtualCopies agit sur la sélection et hors accès en écriture : chaque création est une
--      action Lightroom distincte de la fusion, et la sélection est rétablie ensuite.
--   3. Dans l'accès en écriture de la fusion (appliquer), la nouvelle copie reçoit les réglages de
--      développement de l'ancienne, ses collections, et ses métadonnées selon les règles de Doublons.effets
--      (note la plus haute, mots-clés réunis…). L'ancienne quitte ses collections pour « Doublons à retirer ».
--   4. Après la fusion, les réglages de la nouvelle copie sont relus et comparés (verifier).
-- Ne sont pas repris : l'historique de développement, les instantanés et les appartenances publiées.

local LrTasks = import 'LrTasks'
local Doublons = require 'Doublons'

local M = {}
local T = require('Langue').t

local SANS_PROGRESSION = {
  isCanceled = function() return false end, setCaption = function() end, setPortionComplete = function() end,
}

local function nomFichier(chemin)
  return chemin:match('[^/\\]+$') or chemin
end

-- Nom d'une copie virtuelle pour les messages : « IMG_1.jpg « Noir et blanc » ».
function M.decrire(source)
  return nomFichier(source.chemin) .. ((source.nomCopie or '') ~= '' and T(' « ' .. source.nomCopie .. ' »', ' “' .. source.nomCopie .. '”') or '')
end

-- Copies virtuelles à recréer pour une décision, dans l'ordre des copies écartées. virtuellesDe(c) renvoie les
-- LrPhoto des copies virtuelles de la copie écartée c.
function M.aRecreer(decision, virtuellesDe)
  local dansGroupe = { [decision.garde.id] = true }
  for _, c in ipairs(decision.gardees or {}) do dansGroupe[c.id] = true end
  for _, c in ipairs(decision.retirees) do dansGroupe[c.id] = true end
  local liste = {}
  for _, c in ipairs(decision.retirees) do
    if Doublons.virtuellesRecreees(c, decision.garde) then
      for _, photo in ipairs(virtuellesDe(c) or {}) do
        if not dansGroupe[photo.localIdentifier] then
          dansGroupe[photo.localIdentifier] = true
          liste[#liste + 1] = { decision = decision, retiree = c,
            source = { photo = photo, id = photo.localIdentifier, chemin = c.chemin, virtuelle = true } }
        end
      end
    end
  end
  return liste
end

-- Lit les copies virtuelles à recréer et les rattache à chaque décision (decision.virtuelles). À appeler après
-- confirmation, juste avant la sauvegarde des collections. lireCollections(photos) renvoie les appartenances
-- de ces photos (CollectionsRapides.lire). Renvoie la liste de toutes les copies à recréer.
function M.lire(catalogue, decisions, lireCollections, progression)
  progression = progression or SANS_PROGRESSION
  local entrees = {}
  local avec = false
  for _, d in ipairs(decisions) do
    d.virtuelles = {}
    for _, c in ipairs(d.retirees) do
      if Doublons.virtuellesRecreees(c, d.garde) then avec = true end
    end
  end
  if not avec then return entrees end
  progression:setCaption(T('Lecture des copies virtuelles des copies écartées…', 'Reading the virtual copies of the discarded copies…'))
  local candidates = {}
  for _, d in ipairs(decisions) do
    for _, e in ipairs(M.aRecreer(d, function(c) return c.photo:getRawMetadata('virtualCopies') end)) do
      candidates[#candidates + 1] = e
    end
  end
  if #candidates == 0 then return entrees end
  local photos = {}
  for i, e in ipairs(candidates) do photos[i] = e.source.photo end
  local brutes = catalogue:batchGetRawMetadata(photos, { 'isVirtualCopy', 'rating', 'pickStatus', 'keywords', 'gps' })
  local champs = { 'copyName' }
  for _, cle in ipairs(Doublons.CHAMPS_TEXTE) do champs[#champs + 1] = cle end
  local formatees = catalogue:batchGetFormattedMetadata(photos, champs)
  local appartenances = lireCollections(photos)
  if not appartenances then error(T('Lecture des copies virtuelles interrompue. Rien n’a été modifié.', 'Reading virtual copies interrupted. Nothing has been changed.'), 0) end
  for _, e in ipairs(candidates) do
    local s = e.source
    local b, f = brutes[s.photo] or {}, formatees[s.photo] or {}
    if not b.isVirtualCopy then
      error(T('Une copie virtuelle de ' .. nomFichier(s.chemin) .. ' n’a pas pu être relue. Rien n’a été modifié.', 'A virtual copy of ' .. nomFichier(s.chemin) .. ' could not be re-read. Nothing has been changed.'), 0)
    end
    s.nomCopie = f.copyName or ''
    s.note, s.drapeau, s.gps = b.rating or 0, b.pickStatus or 0, b.gps
    s.motsCles = {}
    for _, mot in ipairs(b.keywords or {}) do s.motsCles[#s.motsCles + 1] = { objet = mot, nom = mot:getName() } end
    s.textes = {}
    for _, cle in ipairs(Doublons.CHAMPS_TEXTE) do s.textes[cle] = f[cle] or '' end
    s.collections = assert(appartenances[s.photo], 'Collections de la copie virtuelle non lues').collections
    -- Déjà mise à retirer : vous l'avez écartée auparavant, elle n'est pas recréée.
    local aRetirer = false
    for _, col in ipairs(s.collections) do
      if col.exclue then aRetirer = true end
    end
    if not aRetirer then
      e.reglages = M.reglages(s.photo:getDevelopSettings())
      entrees[#entrees + 1] = e
      table.insert(e.decision.virtuelles, e)
    end
  end
  return entrees
end

-- Décisions complétées par les copies virtuelles recréées, pour la sauvegarde des collections : les anciennes
-- quittent leurs collections, elles sont donc sauvegardées comme copies écartées.
function M.pourSauvegarde(decisions)
  local liste = {}
  for i, d in ipairs(decisions) do
    local retirees = {}
    for _, c in ipairs(d.retirees) do retirees[#retirees + 1] = c end
    for _, e in ipairs(d.virtuelles or {}) do retirees[#retirees + 1] = e.source end
    liste[i] = { garde = d.garde, gardees = d.gardees, retirees = retirees }
  end
  return liste
end

-- Réglages à appliquer : ceux de l'ancienne copie virtuelle, sans la température et la teinte d'une balance
-- des blancs « Telle quelle » ou « Auto », calculées d'après son fichier : Lightroom les recalcule pour la gardée.
function M.reglages(lus)
  local r = {}
  for cle, valeur in pairs(lus or {}) do r[cle] = valeur end
  if r.WhiteBalance == 'As Shot' or r.WhiteBalance == 'Auto' then
    r.Temperature, r.Tint, r.IncrementalTemperature, r.IncrementalTint = nil, nil, nil, nil
  end
  return r
end

local function egal(a, b)
  if type(a) == 'number' and type(b) == 'number' then
    return math.abs(a - b) <= 1e-3 * math.max(1, math.abs(a), math.abs(b))
  end
  if type(a) ~= 'table' or type(b) ~= 'table' then return a == b end
  for cle, valeur in pairs(a) do
    if not egal(valeur, b[cle]) then return false end
  end
  for cle in pairs(b) do
    if a[cle] == nil then return false end
  end
  return true
end

-- Noms (triés) des réglages appliqués qui diffèrent de ceux relus sur la nouvelle copie.
function M.differences(appliques, relus)
  local cles = {}
  for cle, valeur in pairs(appliques) do
    if not egal(valeur, (relus or {})[cle]) then cles[#cles + 1] = tostring(cle) end
  end
  table.sort(cles)
  return cles
end

-- Plan d'une copie recréée, une fois la nouvelle copie créée et lue (e.nouvelle) : les effets de Doublons.effets,
-- l'ancienne copie tenant le rôle de copie retirée, et les collections ordinaires dont la nouvelle doit sortir
-- (Lightroom y range une copie virtuelle créée pendant l'affichage d'une collection).
function M.preparer(e)
  e.effets = Doublons.effets({ garde = e.nouvelle, retirees = { e.source } })
  local garder = {}
  for _, col in ipairs(e.source.collections) do garder[col.id] = true end
  e.sortir = {}
  for _, col in ipairs(e.nouvelle.collections) do
    if not col.exclue and not col.dynamique and not garder[col.id] then e.sortir[#e.sortir + 1] = col end
  end
end

local function nbCreees(entrees)
  return entrees.creees or 0
end

-- Complète un message d'erreur survenu après la création des copies virtuelles.
function M.completerErreur(erreur, entrees)
  local n = nbCreees(entrees)
  if n == 0 then return tostring(erreur) end
  if require('Langue').anglais() then
    return tostring(erreur) .. string.format('\n\n%d virtual cop%s already created on the kept copies, without the settings '
      .. 'of the old ones: Ctrl+Z (repeated) undoes them, or remove them from the catalog.', n, n > 1 and 'ies' or 'y')
  end
  return tostring(erreur) .. string.format('\n\n%d copie%s virtuelle%s déjà créée%s sur les copies gardées, sans les '
    .. 'réglages des anciennes : Ctrl+Z (répété) les annule, ou retirez-les du catalogue.', n,
    n > 1 and 's' or '', n > 1 and 's' or '', n > 1 and 's' or '')
end

-- Sélectionne la seule photo `photo` ; vrai si Lightroom l'a bien prise pour cible.
local function selectionner(catalogue, photo)
  catalogue:setSelectedPhotos(photo, {})
  for _ = 1, 10 do
    local cible = catalogue:getTargetPhoto()
    if cible and cible.localIdentifier == photo.localIdentifier and #catalogue:getTargetPhotos() == 1 then return true end
    LrTasks.sleep(0.1)
  end
  return false
end

local function lireNouvelles(catalogue, entrees, corbeilles)
  local photos = {}
  for i, e in ipairs(entrees) do photos[i] = e.nouvelle.photo end
  local brutes = catalogue:batchGetRawMetadata(photos, { 'rating', 'pickStatus', 'keywords', 'gps' })
  local formatees = catalogue:batchGetFormattedMetadata(photos, Doublons.CHAMPS_TEXTE)
  for _, e in ipairs(entrees) do
    local n = e.nouvelle
    local b, f = brutes[n.photo] or {}, formatees[n.photo] or {}
    n.note, n.drapeau, n.gps = b.rating or 0, b.pickStatus or 0, b.gps
    n.motsCles = {}
    for _, mot in ipairs(b.keywords or {}) do n.motsCles[#n.motsCles + 1] = { objet = mot, nom = mot:getName() } end
    n.textes = {}
    for _, cle in ipairs(Doublons.CHAMPS_TEXTE) do n.textes[cle] = f[cle] or '' end
    -- getContainedCollections ne liste que les collections ordinaires (ni dynamiques, ni publiées).
    n.collections = {}
    for _, col in ipairs(n.photo:getContainedCollections()) do
      n.collections[#n.collections + 1] = { objet = col, id = col.localIdentifier, nom = col:getName(), dynamique = false,
        exclue = corbeilles[col:getName()] or false }
    end
    M.preparer(e)
  end
end

-- Crée sur chaque photo gardée une copie virtuelle par entrée, hors accès en écriture, puis lit son état et
-- prépare son plan. Vérifie d'abord que chaque photo gardée peut être sélectionnée (elle doit être affichée).
-- entrees.creees compte les copies créées, même en cas d'erreur.
function M.creer(catalogue, entrees, corbeilles, progression)
  if #entrees == 0 then return end
  progression = progression or SANS_PROGRESSION
  local active = catalogue:getTargetPhoto()
  local selection = active and catalogue:getTargetPhotos() or nil
  entrees.creees = 0
  local ok, erreur = LrTasks.pcall(function()
    for _, e in ipairs(entrees) do
      if not selectionner(catalogue, e.decision.garde.photo) then
        error(T('La copie gardée ' .. nomFichier(e.decision.garde.chemin) .. ' n’a pas pu être sélectionnée : elle n’est '
          .. 'pas affichée dans la grille, ou un filtre la masque. Il faut la sélectionner pour lui créer les copies '
          .. 'virtuelles de ' .. nomFichier(e.retiree.chemin) .. '. Affichez son dossier, retirez le filtre, puis relancez. '
          .. 'Rien n’a été modifié.', 'The kept copy ' .. nomFichier(e.decision.garde.chemin) .. ' could not be selected: it is '
          .. 'not shown in the grid, or a filter hides it. It must be selected to create the virtual copies of '
          .. nomFichier(e.retiree.chemin) .. ' on it. Show its folder, remove the filter, then run again. Nothing has been changed.'), 0)
      end
    end
    for i, e in ipairs(entrees) do
      if progression:isCanceled() then error(T('Fusion annulée : aucune fusion n’a été appliquée.', 'Merge cancelled: no merge was applied.'), 0) end
      progression:setCaption(string.format(T('Création des copies virtuelles sur les copies gardées : %d / %d', 'Creating virtual copies on the kept copies: %d / %d'), i, #entrees))
      local garde = e.decision.garde
      local maitre = garde.virtuelle and garde.maitre or garde.photo
      if not selectionner(catalogue, garde.photo) then
        error(T('La copie gardée ' .. nomFichier(garde.chemin) .. ' n’est plus sélectionnable. Aucune fusion n’a été appliquée.', 'The kept copy ' .. nomFichier(garde.chemin) .. ' can no longer be selected. No merge was applied.'), 0)
      end
      local nouvelles = catalogue:createVirtualCopies(e.source.nomCopie ~= '' and e.source.nomCopie or nil) or {}
      entrees.creees = entrees.creees + #nouvelles
      local n = nouvelles[1]
      local maitreLu = n and #nouvelles == 1 and n:getRawMetadata('isVirtualCopy') and n:getRawMetadata('masterPhoto')
      if not maitreLu or maitreLu.localIdentifier ~= maitre.localIdentifier then
        error(string.format(T('Lightroom a créé %d copie(s) virtuelle(s) au lieu d’une copie virtuelle de %s. Aucune fusion '
          .. 'n’a été appliquée.', 'Lightroom created %d virtual cop(ies) instead of one virtual copy of %s. No merge was applied.'),
          #nouvelles, nomFichier(garde.chemin)), 0)
      end
      e.nouvelle = { photo = n, id = n.localIdentifier }
      progression:setPortionComplete(i, #entrees)
    end
    lireNouvelles(catalogue, entrees, corbeilles)
  end)
  if active then LrTasks.pcall(function() catalogue:setSelectedPhotos(active, selection) end) end
  if not ok then error(M.completerErreur(erreur, entrees), 0) end
end

-- La nouvelle copie prend la place de l'ancienne. À appeler dans l'accès en écriture de la fusion.
function M.appliquer(e, corbeille)
  local ef, n, ancienne = e.effets, e.nouvelle.photo, e.source.photo
  n:applyDevelopSettings(e.reglages, T('Réglages de la copie virtuelle de ', 'Settings of the virtual copy of ') .. nomFichier(e.retiree.chemin))
  for _, col in ipairs(e.sortir) do col.objet:removePhotos({ n }) end
  for _, col in ipairs(ef.corbeillesGardee) do col.objet:removePhotos({ n }) end
  for _, col in ipairs(ef.collections) do col.objet:addPhotos({ n }) end
  for _, q in ipairs(ef.quittees) do q.collection.objet:removePhotos({ ancienne }) end
  for _, mot in ipairs(ef.motsCles) do n:addKeyword(mot.objet) end
  if ef.note then n:setRawMetadata('rating', ef.note) end
  if ef.drapeau then n:setRawMetadata('pickStatus', ef.drapeau) end
  for _, t in ipairs(ef.textes) do n:setRawMetadata(t.cle, t.valeur) end
  if ef.gps then n:setRawMetadata('gps', ef.gps) end
  corbeille:addPhotos({ ancienne })
end

-- Après la fusion : réglages relus qui diffèrent de ceux de l'ancienne copie. Renvoie { { entree, cles }… }.
function M.verifier(entrees)
  local ecarts = {}
  for _, e in ipairs(entrees) do
    local cles = M.differences(e.reglages, e.nouvelle.photo:getDevelopSettings())
    if #cles > 0 then ecarts[#ecarts + 1] = { entree = e, cles = cles } end
  end
  return ecarts
end

-- Paragraphe du bilan de fusion, ou '' sans copie virtuelle recréée.
function M.bilan(entrees, ecarts, collection)
  if #entrees == 0 then return '' end
  local texte
  if require('Langue').anglais() then
    texte = string.format('\n\n%d virtual cop%s recreated on the kept copies (settings, copy name, metadata, collections). '
      .. 'The old ones are in “%s” with their original.', #entrees, #entrees > 1 and 'ies' or 'y', collection)
      .. '\nTheir creation is a Lightroom action separate from the merge: after Ctrl+Z of the merge, they stay on the kept '
      .. 'copies, without the settings of the old ones, until the following Ctrl+Z.'
  else
    texte = string.format('\n\n%d copie%s virtuelle%s recréée%s sur les copies gardées (réglages, nom de copie, '
      .. 'métadonnées, collections). Les anciennes sont dans « %s » avec leur original.', #entrees,
      #entrees > 1 and 's' or '', #entrees > 1 and 's' or '', #entrees > 1 and 's' or '', collection)
      .. '\nLeur création est une action Lightroom distincte de la fusion : après Ctrl+Z de la fusion, elles restent '
      .. 'sur les copies gardées, sans les réglages des anciennes, jusqu’aux Ctrl+Z suivants.'
  end
  if #ecarts > 0 then
    texte = texte .. T('\n\nRéglages relus différents de ceux des anciennes copies : comparez-les avant de retirer les copies '
      .. 'écartées.', '\n\nSettings read back differ from those of the old copies: compare them before removing the discarded copies.')
    for _, ecart in ipairs(ecarts) do
      local cles = {}
      for i = 1, math.min(5, #ecart.cles) do cles[i] = ecart.cles[i] end
      texte = texte .. '\n• ' .. M.decrire(ecart.entree.source) .. ' : ' .. table.concat(cles, ', ')
        .. (#ecart.cles > 5 and string.format(T('… (%d réglages)', '… (%d settings)'), #ecart.cles) or '')
    end
  end
  return texte
end

return M
