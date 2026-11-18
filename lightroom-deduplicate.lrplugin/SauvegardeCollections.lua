-- Sauvegardes lisibles, indépendantes du rapport qui est remplacé à chaque analyse.
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local M = {}
local function encoder(s)
  return (tostring(s or ''):gsub('\\', '\\\\'):gsub('\t', '\\t'):gsub('\r', '\\r'):gsub('\n', '\\n'))
end
local function decoder(s)
  return (s:gsub('\\(.)', function(c) return ({ t = '\t', r = '\r', n = '\n', ['\\'] = '\\' })[c] or error('Échappement invalide') end))
end
function M.texte(cataloguePath, decisions, genre)
  local lignes = { 'SAUVEGARDE_COLLECTIONS_V2', '# État ORIGINAL des collections avant l’opération ; les métadonnées et retouches ne sont pas sauvegardées.',
    '# PHOTO : id, rôle, virtuelle (0/1), chemin. MEMBRE : id photo, id collection, chemin complet.',
    '# NOEUD : id, id parent, ensemble/collection, nom. Les caractères spéciaux sont échappés avec \\.',
    'CATALOGUE\t' .. encoder(cataloguePath), 'DATE\t' .. os.date('%Y-%m-%d %H:%M:%S'), 'TYPE\t' .. encoder(genre) }
  local photos, noeuds, liens, nb = {}, {}, {}, 0
  local function copie(c, role)
    if photos[c.id] then return end
    photos[c.id] = true; nb = nb + 1
    lignes[#lignes + 1] = table.concat({ 'PHOTO', c.id, role, c.virtuelle and 1 or 0, encoder(c.chemin) }, '\t')
    for _, col in ipairs(assert(c.collections, 'Collections non lues')) do
      if not col.dynamique then
        assert(col.hierarchie and #col.hierarchie > 0, 'Chemin original de collection absent : sauvegarde impossible')
        for _, n in ipairs(col.hierarchie) do
          if not noeuds[n.id] then
            noeuds[n.id] = n
            lignes[#lignes + 1] = table.concat({ 'NOEUD', n.id, n.parent or 0,
              n.ensemble and 'ensemble' or 'collection', encoder(n.nom) }, '\t')
          end
        end
        lignes[#lignes + 1] = table.concat({ 'MEMBRE', c.id, col.id, encoder(col.cheminComplet or col.nom) }, '\t')
        liens[#liens + 1] = true
      end
    end
  end
  for numero, d in ipairs(decisions) do
    lignes[#lignes + 1] = 'GROUPE\t' .. numero
    local function membre(c, role)
      assert(not photos[c.id], 'Photo présente dans plusieurs groupes : ' .. tostring(c.id))
      copie(c, role)
      lignes[#lignes + 1] = 'GROUPEPHOTO\t' .. numero .. '\t' .. c.id
    end
    membre(d.garde, 'gardee')
    for _, c in ipairs(d.gardees or {}) do membre(c, 'gardee') end
    for _, c in ipairs(d.retirees) do membre(c, 'ecartee') end
  end
  lignes[#lignes + 1] = 'FIN\t' .. nb .. '\t' .. #liens
  return table.concat(lignes, '\n') .. '\n'
end
function M.lire(texte)
  texte = texte:gsub('\r\n', '\n')
  local version = texte:match('^SAUVEGARDE_COLLECTIONS_V([12])\n')
  assert(version, 'Format de sauvegarde inconnu')
  local r = { photos = {}, ordre = {}, noeuds = {}, groupes = {}, ancienne = version == '1' }
  local affectees = {}
  local nb, liens, fin = 0, 0, false
  for ligne in texte:gmatch('[^\n]+') do
    if ligne:sub(1, 1) ~= '#' and ligne ~= 'SAUVEGARDE_COLLECTIONS_V' .. version then
      assert(not fin, 'Données après la fin de sauvegarde')
      local cle, valeur = ligne:match('^(%u+)\t(.*)$')
      if cle == 'CATALOGUE' then r.catalogue = decoder(valeur)
      elseif cle == 'TYPE' then r.genre = decoder(valeur)
      elseif cle == 'DATE' then r.date = valeur
      elseif cle == 'GROUPE' and version == '2' then
        local id = tonumber(valeur)
        assert(id and id == #r.groupes + 1, 'Groupe invalide')
        r.groupes[id] = { numero = id, photos = {} }
      elseif cle == 'GROUPEPHOTO' and version == '2' then
        local g, p = valeur:match('^(%d+)\t(%d+)$')
        g, p = tonumber(g), tonumber(p)
        assert(g and p and r.groupes[g] and r.photos[p] and not affectees[p], 'Appartenance au groupe invalide')
        affectees[p] = true
        local groupe = r.groupes[g]
        groupe.photos[#groupe.photos + 1] = r.photos[p]
      elseif cle == 'PHOTO' then
        local id, role, virtuelle, chemin = valeur:match('^(%d+)\t(%a+)\t([01])\t(.*)$')
        assert(id and (role == 'gardee' or role == 'ecartee'), 'Photo invalide'); id = tonumber(id)
        assert(not r.photos[id], 'Photo répétée')
        r.photos[id] = { id = id, role = role, virtuelle = virtuelle == '1', chemin = decoder(chemin), collections = {} }
        r.ordre[#r.ordre + 1] = r.photos[id]; nb = nb + 1
      elseif cle == 'NOEUD' then
        local id, parent, type_, nom = valeur:match('^(%d+)\t(%d+)\t(%a+)\t(.*)$')
        assert(id and (type_ == 'ensemble' or type_ == 'collection'), 'Nœud invalide'); id = tonumber(id)
        assert(not r.noeuds[id], 'Nœud répété')
        r.noeuds[id] = { id = id, parent = tonumber(parent), ensemble = type_ == 'ensemble', nom = decoder(nom) }
      elseif cle == 'MEMBRE' then
        local p, c = valeur:match('^(%d+)\t(%d+)\t')
        assert(p and r.photos[tonumber(p)], 'Appartenance sans photo')
        r.photos[tonumber(p)].collections[#r.photos[tonumber(p)].collections + 1] = tonumber(c); liens = liens + 1
      elseif cle == 'FIN' then
        local p, c = valeur:match('^(%d+)\t(%d+)$')
        assert(tonumber(p) == nb and tonumber(c) == liens, 'Sauvegarde incomplète'); fin = true
      else error('Ligne de sauvegarde inconnue') end
    end
  end
  assert(fin and r.catalogue and nb > 0, 'Sauvegarde incomplète')
  if version == '1' then
    r.groupes[1] = { numero = 1, photos = r.ordre, ancienne = true }
  else
    assert(#r.groupes > 0, 'Groupes absents')
    for _, g in ipairs(r.groupes) do assert(#g.photos > 0, 'Groupe vide') end
    for _, p in ipairs(r.ordre) do assert(affectees[p.id], 'Photo sans groupe') end
  end
  for _, photo in ipairs(r.ordre) do
    for _, id in ipairs(photo.collections) do assert(r.noeuds[id] and not r.noeuds[id].ensemble, 'Collection absente') end
  end
  for id, n in pairs(r.noeuds) do
    local visites, profondeur = {}, 0
    while n do
      profondeur = profondeur + 1
      assert(not visites[n.id] and profondeur < 100, 'Cycle de collections')
      visites[n.id] = true
      if n.parent == 0 then break end
      n = assert(r.noeuds[n.parent], 'Parent absent'); assert(n.ensemble, 'Parent non ensemble')
    end
  end
  return r
end
function M.sauver(catalogue, decisions, dossier, genre)
  LrFileUtils.createAllDirectories(dossier)
  local chemin = LrFileUtils.chooseUniqueFileName(LrPathUtils.child(dossier,
    os.date(genre == 'rafales' and 'collections-avant-rafales-%Y%m%d-%H%M%S.txt'
      or 'collections-avant-fusion-%Y%m%d-%H%M%S.txt')))
  -- L'analyse peut précéder la confirmation de plusieurs minutes : relire l'état
  -- courant juste avant la fusion au lieu de sauvegarder des appartenances anciennes.
  local Rapides = dofile(LrPathUtils.child(_PLUGIN.path, 'CollectionsRapides.lua'))
  local photos, vus = {}, {}
  local function ajouter(c)
    if not vus[c.id] then vus[c.id] = true; photos[#photos + 1] = assert(c.photo) end
  end
  for _, d in ipairs(decisions) do
    ajouter(d.garde)
    for _, c in ipairs(d.gardees or {}) do ajouter(c) end
    for _, c in ipairs(d.retirees) do ajouter(c) end
  end
  local progression = { isCanceled = function() return false end, setCaption = function() end, setPortionComplete = function() end }
  local etat = assert(Rapides.lire(catalogue, photos, progression, {}, true), 'Lecture de sauvegarde interrompue')
  local function copie(c)
    return { id = c.id, chemin = c.chemin, virtuelle = c.virtuelle, collections = assert(etat[c.photo]).collections }
  end
  local actuelles = {}
  for _, d in ipairs(decisions) do
    local r = { garde = copie(d.garde), gardees = {}, retirees = {} }
    for _, c in ipairs(d.gardees or {}) do r.gardees[#r.gardees + 1] = copie(c) end
    for _, c in ipairs(d.retirees) do r.retirees[#r.retirees + 1] = copie(c) end
    actuelles[#actuelles + 1] = r
  end
  local contenu = M.texte(catalogue:getPath(), actuelles, genre)
  M.lire(contenu) -- Refuse une sauvegarde inexploitable avant toute modification du catalogue.
  local f = assert(io.open(chemin, 'wb'), 'Impossible de créer la sauvegarde des collections')
  local ok, err = f:write(contenu); local ferme = f:close()
  assert(ok and ferme, err or 'Écriture de sauvegarde incomplète')
  assert(LrFileUtils.readFile(chemin) == contenu, 'La sauvegarde des collections n’a pas pu être vérifiée')
  return chemin
end
-- Construit une vue limitée aux groupes choisis, sans modifier la sauvegarde d'origine.
function M.selectionner(sauvegarde, numeros)
  local selection = { catalogue = sauvegarde.catalogue, genre = sauvegarde.genre,
    noeuds = sauvegarde.noeuds, photos = {}, ordre = {}, groupes = {}, ancienne = sauvegarde.ancienne }
  local vus = {}
  for _, numero in ipairs(numeros) do
    local groupe = assert(sauvegarde.groupes[numero], 'Groupe inconnu')
    assert(not vus[numero], 'Groupe choisi plusieurs fois')
    vus[numero] = true
    selection.groupes[#selection.groupes + 1] = groupe
    for _, p in ipairs(groupe.photos) do
      selection.photos[p.id] = p
      selection.ordre[#selection.ordre + 1] = p
    end
  end
  assert(#selection.ordre > 0, 'Aucun groupe sélectionné')
  return selection
end
-- À exécuter dans la même action annulable que la restauration des collections.
function M.retirerMotCleRafales(sauvegarde, photos, nom)
  if sauvegarde.genre ~= 'rafales' then return end
  for _, p in ipairs(sauvegarde.ordre) do
    local photo = assert(photos[p.id], 'Photo absente : ' .. p.chemin)
    for _, mot in ipairs(photo:getRawMetadata('keywords') or {}) do
      if mot:getName() == nom then photo:removeKeyword(mot) end
    end
  end
end
-- À appeler dans une action catalogue annulable, après validation de toutes les photos.
function M.restaurer(catalogue, sauvegarde, photos, corbeilles)
  local objets, parCollection, retablir = {}, {}, {}
  local function collection(id)
    if objets[id] then return objets[id] end
    local n = assert(sauvegarde.noeuds[id])
    local parent = n.parent ~= 0 and collection(n.parent) or nil
    local existante = catalogue:getCollectionByLocalIdentifier(id)
    if existante then
      local p = existante:getParent()
      local parentId = p and p.localIdentifier or 0
      local attendu = parent and parent.localIdentifier or 0
      if existante:getName() ~= n.nom or parentId ~= attendu
        or existante:type() ~= (n.ensemble and 'LrCollectionSet' or 'LrCollection') then existante = nil end
    end
    if not existante then
      if n.ensemble then existante = catalogue:createCollectionSet(n.nom, parent, true)
      else existante = catalogue:createCollection(n.nom, parent, true) end
    end
    assert(existante, 'Impossible de recréer ' .. n.nom)
    objets[id] = existante
    return existante
  end
  for _, p in ipairs(sauvegarde.ordre) do
    local photo = assert(photos[p.id], 'Photo absente : ' .. p.chemin)
    local anciens, enRetrait = {}, false
    for _, id in ipairs(p.collections) do
      anciens[id] = true
      if corbeilles[sauvegarde.noeuds[id].nom] then enRetrait = true end
      parCollection[id] = parCollection[id] or {}; table.insert(parCollection[id], photo)
    end
    -- Retire uniquement les marqueurs de retrait ajoutés depuis la sauvegarde.
    for _, col in ipairs(photo:getContainedCollections()) do
      if corbeilles[col:getName()] and not anciens[col.localIdentifier] then col:removePhotos({ photo }) end
    end
    if not enRetrait and not p.virtuelle then retablir[#retablir + 1] = p.chemin end
  end
  for id, liste in pairs(parCollection) do collection(id):addPhotos(liste) end
  return retablir
end
return M
