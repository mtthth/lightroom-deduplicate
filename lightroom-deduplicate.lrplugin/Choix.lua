-- Choix faits dans le rapport des doublons : groupes à ne pas fusionner, groupes « à vérifier » à fusionner
-- de force. Pur Lua, sans appel à Lightroom, pour pouvoir être testé à part.
--
-- Le rapport HTML est une page locale : il ne peut pas écrire sur le disque. Il affiche donc un code que
-- l'utilisateur copie puis colle dans Lightroom :
--   DEDUP 1a2b3c4d · non 12 45 · force 3 9:2
-- 1a2b3c4d identifie l'analyse (voir identifiant) ; « non » liste les groupes à ne pas fusionner ;
-- « force » les groupes « à vérifier » à fusionner quand même, « 9:2 » gardant la 2ᵉ copie du groupe 9
-- (dans l'ordre du rapport : la copie qui serait gardée, puis les autres).
--
-- Les groupes non fusionnés sont mémorisés dans groupes-refuses.txt : une ligne par groupe, la date puis les
-- chemins, séparés par des tabulations. Un groupe qui réunit deux fichiers d'un même refus reste « à vérifier ».

local Doublons = require 'Doublons'

local M = {}

M.ENTETE = '# Groupes que tu as choisi de ne pas fusionner : date, puis les fichiers du groupe, séparés par des tabulations.\r\n'
  .. '# Un groupe qui réunit deux fichiers d’une même ligne reste « à vérifier ». Supprime la ligne pour lever le refus.\r\n'

local function normaliser(chemin)
  return (chemin or ''):gsub('/', '\\'):lower()
end

-- Identifiant de l'analyse : numéros, état et copies des groupes. Un code copié depuis un autre rapport, où
-- les mêmes numéros désignent d'autres groupes, est ainsi refusé. Le même identifiant revient quand une
-- nouvelle analyse retrouve exactement les mêmes groupes : le rapport retrouve alors les cases cochées.
function M.identifiant(decisions)
  -- Reste sous 2^31 : string.format('%x') de Lightroom (Lua 5.1) passe par un entier long de 32 bits.
  local h = 7
  local function ajouter(texte)
    for i = 1, #texte do h = (h * 31 + texte:byte(i)) % 2147483647 end
  end
  for n, d in ipairs(decisions) do
    ajouter(string.format('|%d%s%s', n, d.aVerifier and 'v' or 'f', tostring(d.garde.id)))
    for _, c in ipairs(d.retirees) do ajouter(',' .. tostring(c.id)) end
  end
  return string.format('%08x', h)
end

-- Lit le code collé dans Lightroom. Renvoie { exclus = { [numéro] = true }, forces = { [numéro] = copie
-- gardée (1 = celle qui serait gardée) }, absorbes = { [numéro] = numéro du groupe forcé qui le contient } },
-- ou nil et un message. Un texte vide ne demande aucun choix.
function M.lireCode(texte, decisions, identifiant)
  local choix = { exclus = {}, forces = {} }
  local mots = {}
  local propre = (texte or ''):lower():gsub('[^%w:]+', ' ')
  for mot in propre:gmatch('%S+') do mots[#mots + 1] = mot end
  if #mots == 0 then return choix end
  if mots[1] ~= 'dedup' then
    return nil, 'Le code doit commencer par DEDUP : copie-le avec le bouton « Copier le code » du rapport.'
  end
  if mots[2] ~= identifiant then
    return nil, string.format('Ce code vient d’un autre rapport (analyse %s ; celle-ci est %s). Ouvre le rapport de '
      .. 'cette analyse avec « Ouvrir le rapport » et copie de nouveau le code.', mots[2] or '?', identifiant)
  end
  local mode
  for i = 3, #mots do
    local mot = mots[i]
    if mot == 'non' or mot == 'force' then
      mode = mot
    else
      local n, k = mot:match('^(%d+)$'), nil
      if not n then n, k = mot:match('^(%d+):(%d+)$') end
      if not n or not mode then return nil, 'Code illisible près de « ' .. mot .. ' ».' end
      n = tonumber(n)
      local d = decisions[n]
      if not d then return nil, string.format('Le groupe %d n’existe pas dans ce rapport.', n) end
      if choix.exclus[n] or choix.forces[n] then
        return nil, string.format('Le groupe %d apparaît deux fois dans le code.', n)
      end
      if mode == 'non' then
        if k then return nil, string.format('« %s » : seul un groupe forcé indique la copie à garder.', mot) end
        if d.aVerifier then
          return nil, string.format('Le groupe %d est déjà laissé tel quel (« à vérifier ») : rien à exclure.', n)
        end
        choix.exclus[n] = true
      else
        if not d.aVerifier then
          return nil, string.format('Le groupe %d est déjà proposé à la fusion : rien à forcer.', n)
        end
        k = tonumber(k or 1)
        if k < 1 or k > #d.retirees + 1 then
          return nil, string.format('Le groupe %d n’a pas de copie numéro %d.', n, k)
        end
        choix.forces[n] = k
      end
    end
  end
  -- Un groupe forcé (des versions conservées à part, surtout) peut contenir les copies d'un groupe déjà
  -- proposé : il le remplace. Un chevauchement partiel, ou entre deux groupes forcés, est refusé.
  choix.absorbes = {}
  local function ids(d)
    local t = { [d.garde.id] = true }
    for _, c in ipairs(d.retirees) do t[c.id] = true end
    return t
  end
  for f in pairs(choix.forces) do
    local dansForce = ids(decisions[f])
    for n, d in ipairs(decisions) do
      local fusionne = choix.forces[n] or (not d.aVerifier and not choix.exclus[n])
      if n ~= f and fusionne then
        local communes, total = 0, 0
        for id in pairs(ids(d)) do
          total = total + 1
          if dansForce[id] then communes = communes + 1 end
        end
        if communes > 0 then
          if choix.forces[n] or communes < total then
            if choix.forces[n] then
              return nil, string.format('Les groupes %d et %d partagent des photos : ne force qu’un des deux (décoche '
                .. '« Fusionner de force » sur le groupe %d).', math.min(f, n), math.max(f, n), math.max(f, n))
            end
            return nil, string.format('Les groupes %d et %d partagent des photos, mais le groupe forcé %d ne contient '
              .. 'qu’une partie du groupe %d : coche « Ne pas fusionner » sur le groupe %d, ou décoche « Fusionner de '
              .. 'force » sur le groupe %d.', math.min(f, n), math.max(f, n), f, n, n, f)
          end
          choix.absorbes[n] = f
        end
      end
    end
  end
  return choix
end

-- Plan final : les groupes proposés moins les exclus, plus les groupes forcés avec la copie choisie.
-- Renvoie { aFusionner, exclues, forcees } ; chaque décision porte son numéro dans le rapport, et une
-- décision forcée porte la raison qui la laissait « à vérifier » (champ forcee) et son plan (effets).
function M.appliquer(decisions, choix)
  local plan = { aFusionner = {}, exclues = {}, forcees = {}, absorbes = {} }
  for n, d in ipairs(decisions) do
    d.numero = n
    local k = choix.forces[n]
    if k then
      local copies = { d.garde }
      for _, c in ipairs(d.retirees) do copies[#copies + 1] = c end
      local forcee = {
        numero = n, garde = copies[k], retirees = {}, memeImage = d.memeImage, forcee = d.aVerifier,
        pourquoi = k == 1 and d.pourquoi or 'choisie dans le rapport',
      }
      for i, c in ipairs(copies) do
        if i ~= k then forcee.retirees[#forcee.retirees + 1] = c end
      end
      forcee.effets = Doublons.effets(forcee)
      plan.aFusionner[#plan.aFusionner + 1] = forcee
      plan.forcees[#plan.forcees + 1] = forcee
    elseif choix.absorbes and choix.absorbes[n] then
      -- Ses copies sont fusionnées avec le groupe forcé qui les contient toutes.
      plan.absorbes[#plan.absorbes + 1] = d
    elseif not d.aVerifier then
      if choix.exclus[n] then
        plan.exclues[#plan.exclues + 1] = d
      else
        plan.aFusionner[#plan.aFusionner + 1] = d
      end
    end
  end
  return plan
end

-- Lit groupes-refuses.txt (contenu texte, éventuellement vide).
function M.lireRefus(contenu)
  local refus = { parChemin = {} }
  for ligne in (contenu or ''):gmatch('[^\r\n]+') do
    if ligne:sub(1, 1) ~= '#' then
      local champs = {}
      for champ in ligne:gmatch('[^\t]+') do champs[#champs + 1] = champ end
      if #champs >= 3 then
        local a, m, j = champs[1]:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)')
        local entree = { date = a and string.format('%s/%s/%s', j, m, a) or champs[1] }
        for i = 2, #champs do
          local cle = normaliser(champs[i])
          refus.parChemin[cle] = refus.parChemin[cle] or {}
          table.insert(refus.parChemin[cle], entree)
        end
      end
    end
  end
  return refus
end

-- Le refus qui réunit au moins deux copies du groupe, ou nil.
function M.refusDuGroupe(refus, copies)
  local compte = {}
  for _, c in ipairs(copies) do
    for _, entree in ipairs(refus.parChemin[normaliser(c.chemin)] or {}) do
      compte[entree] = (compte[entree] or 0) + 1
      if compte[entree] >= 2 then return entree end
    end
  end
  return nil
end

-- Lignes à ajouter à groupes-refuses.txt pour les décisions non fusionnées.
function M.lignesRefus(date, decisions)
  local lignes = {}
  for _, d in ipairs(decisions) do
    local champs = { date ~= '' and date or '?', d.garde.chemin }
    for _, c in ipairs(d.retirees) do champs[#champs + 1] = c.chemin end
    lignes[#lignes + 1] = table.concat(champs, '\t') .. '\r\n'
  end
  return table.concat(lignes)
end

return M
