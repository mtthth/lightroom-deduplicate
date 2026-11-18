-- Lecture groupée SQLite en mode strictement lecture seule. Les modifications restent SDK.
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local LrTasks = import 'LrTasks'
local LrMD5 = import 'LrMD5'
local M = {}

local function dehex(s)
  assert(#s % 2 == 0 and not s:find('[^%da-f]'), 'Texte du snapshot invalide')
  return (s:gsub('..', function(o) return string.char(tonumber(o, 16)) end))
end

function M.decoder(texte, catalogue, photos, corbeilles, complet)
  texte = texte:gsub('\r\n', '\n')
  local infos, noeuds, liens, compteP, compteC, compteL = {}, {}, {}, 0, 0, 0
  local fin = false
  assert(texte:match('^LRDC1\n'), 'Snapshot de collections invalide : ' ..
    (texte:match('^ERROR\t([%da-f]*)') and dehex(texte:match('^ERROR\t([%da-f]*)')) or 'format inconnu'))
  for ligne in texte:gmatch('[^\n]+') do
    assert(not fin, 'Données après la fin du snapshot')
    local id, flag = ligne:match('^P\t(%d+)\t([01])$')
    if id then
      id = tonumber(id); assert(not infos[id], 'Photo répétée')
      infos[id] = { collections = {}, publiee = flag == '1' }; compteP = compteP + 1
    elseif ligne:sub(1, 2) == 'C\t' then
      local c, parent, nom = ligne:match('^C\t(%d+)\t(%d+)\t([%da-f]*)$')
      assert(c, 'Collection invalide'); c = tonumber(c)
      assert(not noeuds[c], 'Collection répétée')
      noeuds[c] = { id = c, parent = tonumber(parent), nom = dehex(nom) }; compteC = compteC + 1
    elseif ligne:sub(1, 2) == 'L\t' then
      local p, c = ligne:match('^L\t(%d+)\t(%d+)$'); assert(p, 'Appartenance invalide')
      liens[#liens + 1] = { tonumber(p), tonumber(c) }; compteL = compteL + 1
    elseif ligne:sub(1, 4) == 'END\t' then
      local p, c, l = ligne:match('^END\t(%d+)\t(%d+)\t(%d+)$')
      assert(tonumber(p) == compteP and tonumber(c) == compteC and tonumber(l) == compteL,
        'Snapshot incomplet'); fin = true
    else assert(ligne == 'LRDC1', 'Ligne de snapshot inconnue') end
  end
  -- Le script Python dédoublonne les identifiants : comparer au nombre de photos distinctes.
  local distinctes, nbDistinctes = {}, 0
  for _, photo in ipairs(photos) do
    if not distinctes[photo.localIdentifier] then distinctes[photo.localIdentifier] = true; nbDistinctes = nbDistinctes + 1 end
  end
  assert(fin and compteP == nbDistinctes, 'Photos candidates manquantes')
  local objets, resultats = {}, {}
  for _, lien in ipairs(liens) do
    local p, cid = lien[1], lien[2]
    assert(infos[p] and noeuds[cid], 'Appartenance sans photo/collection')
    if not objets[cid] then
      local noms, hierarchie, visite, n = {}, {}, {}, noeuds[cid]
      while n do
        assert(not visite[n.id] and #noms < 100, 'Cycle de collections')
        visite[n.id] = true; table.insert(noms, 1, n.nom)
        table.insert(hierarchie, 1, { id = n.id, parent = n.parent, nom = n.nom, ensemble = n.id ~= cid })
        if n.parent == 0 then break end
        n = assert(noeuds[n.parent], 'Parent de collection absent')
      end
      local objet = { localIdentifier = cid }
      -- Résolution SDK uniquement au moment d'appliquer une modification. Une disparition
      -- provoque une erreur et le rollback de l'action Undo complète.
      local sdk
      local function resoudre()
        if not sdk then sdk = assert(catalogue:getCollectionByLocalIdentifier(cid), 'Collection disparue : ' .. cid) end
        return sdk
      end
      function objet:addPhotos(ps) resoudre():addPhotos(ps) end
      function objet:removePhotos(ps) resoudre():removePhotos(ps) end
      function objet:getName() return noeuds[cid].nom end
      objets[cid] = { objet = objet, id = cid, dynamique = false,
        exclue = corbeilles[noeuds[cid].nom] or false,
        cheminComplet = table.concat(noms, ' / '), hierarchie = hierarchie,
        nom = complet and table.concat(noms, ' / ') or (#noms == 1 and noms[1] or noms[1] .. ' / ' .. noms[#noms]) }
    end
    infos[p].collections[#infos[p].collections + 1] = objets[cid]
  end
  for _, photo in ipairs(photos) do resultats[photo] = assert(infos[photo.localIdentifier], 'Photo absente du snapshot') end
  return resultats
end

local function python()
  local Python = require 'Python'
  return Python.chemin() or error(Python.MESSAGE, 0)
end
local function citer(p)
  assert(not p:find('["%%!&|<>^\r\n]'), 'Chemin incompatible avec la commande Python')
  for i = 1, #p do assert(p:byte(i) < 128, 'Le dossier temporaire Python doit avoir un chemin ASCII') end
  return '"' .. p .. '"'
end

function M.lire(catalogue, photos, progression, corbeilles, complet, diagnostic)
  if progression:isCanceled() then return nil end
  if #photos == 0 then return {} end
  progression:setCaption('Lecture groupée des collections et publications du catalogue…')
  local base = LrPathUtils.child(LrPathUtils.getStandardFilePath('temp'),
    'lrdedup-' .. LrMD5.digest(tostring({}) .. os.time()))
  local script, requete, sortie = base .. '.py', base .. '.txt', base .. '.tsv'
  local ok, resultat = LrTasks.pcall(function()
    local exe = python()
    LrFileUtils.copy(LrPathUtils.child(_PLUGIN.path, 'collections_readonly.py'), script)
    local path = catalogue:getPath()
    assert(not path:find('[\r\n]'), 'Chemin du catalogue invalide')
    local f = assert(io.open(requete, 'wb'))
    f:write(path .. '\n')
    for _, photo in ipairs(photos) do f:write(tostring(photo.localIdentifier) .. '\n') end
    f:close()
    local function executer()
      -- Les exécutables Python détectés ont un chemin ASCII sans espaces. Ne pas
      -- entourer toute la commande de guillemets : cmd.exe peut alors mal la découper.
      citer(exe)
      return LrTasks.execute(exe .. ' ' .. citer(script) .. ' ' .. citer(requete) .. ' ' .. citer(sortie))
    end
    local code
    if diagnostic then
      code = diagnostic:appel({ numero = 1, total = #photos, id = photos[1].localIdentifier,
        chemin = diagnostic.chemins[photos[1]] }, 'snapshot SQLite en lecture seule', executer)
    else code = executer() end
    if progression:isCanceled() then return nil end
    local contenu = LrFileUtils.readFile(sortie)
    if not contenu then error('La lecture groupée a échoué (code ' .. tostring(code) .. ').', 0) end
    local donnees = M.decoder(contenu, catalogue, photos, corbeilles, complet)
    if code ~= 0 then error('La lecture groupée a échoué (code ' .. tostring(code) .. ').', 0) end
    if diagnostic then diagnostic:terminer('Snapshot complet : ' .. #photos .. ' photos') end
    progression:setPortionComplete(#photos, #photos)
    return donnees
  end)
  for _, p in ipairs({ script, requete, sortie }) do
    if LrFileUtils.exists(p) then LrFileUtils.delete(p) end
  end
  if not ok then error(resultat, 0) end
  return resultat
end
return M
