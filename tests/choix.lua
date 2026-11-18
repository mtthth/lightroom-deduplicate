package.path = 'lightroom-deduplicate.lrplugin/?.lua;' .. package.path
local Choix = require 'Choix'
local Doublons = require 'Doublons'

local function copie(id, chemin, extra)
  local c = { id = id, chemin = chemin, empreinte = 'jpeg:' .. (extra and extra.empreinte or 'x'), pixels = 100, octets = 10 }
  for k, v in pairs(extra or {}) do c[k] = v end
  return c
end

-- Trois groupes : 1 et 3 proposés, 2 « à vérifier » (deux copies retouchées).
local a1, a2 = copie(1, 'D:\\A\\a.jpg'), copie(2, 'D:\\B\\a-2.jpg')
local b1, b2, b3 = copie(3, 'D:\\A\\b.jpg', { retouchee = true }), copie(4, 'D:\\B\\b-2.jpg', { retouchee = true }),
  copie(5, 'D:\\C\\b.jpg', { virtuelles = 2, publiee = true })
local c1, c2 = copie(6, 'D:\\A\\c.jpg'), copie(7, 'D:\\B\\c (2).jpg')
local decisions = { Doublons.decider({ a1, a2 }), Doublons.decider({ b1, b2, b3 }), Doublons.decider({ c1, c2 }) }
assert(not decisions[1].aVerifier and decisions[2].aVerifier and not decisions[3].aVerifier)
local id = Choix.identifiant(decisions)
assert(id:match('^%x%x%x%x%x%x%x%x$'), id)
assert(Choix.identifiant(decisions) == id, 'identifiant stable')
assert(Choix.identifiant({ decisions[1], decisions[3], decisions[2] }) ~= id, 'numérotation différente')

-- Code vide : aucun choix, le plan d'origine.
local choix = assert(Choix.lireCode('  ', decisions, id))
local plan = Choix.appliquer(decisions, choix)
assert(#plan.aFusionner == 2 and #plan.exclues == 0 and #plan.forcees == 0)

-- Code complet, avec les séparateurs du rapport, des majuscules et un retour à la ligne.
choix = assert(Choix.lireCode('DEDUP ' .. id:upper() .. ' · non 3 · force 2:3\n', decisions, id))
assert(choix.exclus[3] and choix.forces[2] == 3)
plan = Choix.appliquer(decisions, choix)
assert(#plan.aFusionner == 2 and #plan.exclues == 1 and #plan.forcees == 1)
assert(plan.exclues[1] == decisions[3] and plan.exclues[1].numero == 3)
local forcee = plan.forcees[1]
assert(forcee.numero == 2 and forcee.forcee == decisions[2].aVerifier and not forcee.aVerifier)
-- La 3ᵉ copie du rapport (celle qui serait gardée, puis les retirées dans l'ordre) devient la gardée.
assert(forcee.garde == decisions[2].retirees[2] and #forcee.retirees == 2 and forcee.effets)
assert(forcee.retirees[1] == decisions[2].garde and forcee.retirees[2] == decisions[2].retirees[1])
assert(plan.aFusionner[1] == decisions[1] and plan.aFusionner[2] == forcee)
-- Sans numéro de copie, la copie qui serait gardée l'est.
choix = assert(Choix.lireCode('DEDUP ' .. id .. ' force 2', decisions, id))
assert(Choix.appliquer(decisions, choix).forcees[1].garde == decisions[2].garde)

-- Codes refusés.
for _, texte in ipairs({
  'non 1', 'DEDUP 00000000 non 1', 'DEDUP ' .. id .. ' 1', 'DEDUP ' .. id .. ' non 9', 'DEDUP ' .. id .. ' non 2',
  'DEDUP ' .. id .. ' force 1', 'DEDUP ' .. id .. ' force 2:4', 'DEDUP ' .. id .. ' force 2:0', 'DEDUP ' .. id .. ' non 1:1',
  'DEDUP ' .. id .. ' non 1 non 1', 'DEDUP ' .. id .. ' non 1 force 1', 'DEDUP ' .. id .. ' non x',
}) do
  local r, message = Choix.lireCode(texte, decisions, id)
  assert(not r and type(message) == 'string', texte)
end

-- Refus mémorisés : deux fichiers d'une même ligne réunis dans un groupe le laissent « à vérifier ».
local texte = Choix.ENTETE .. Choix.lignesRefus('2026-11-01 14:32', { decisions[1], decisions[3] })
assert(texte:find('2026-11-01 14:32\tD:\\A\\a.jpg\tD:\\B\\a-2.jpg\r\n', 1, true))
local refus = Choix.lireRefus(texte)
local r = Choix.refusDuGroupe(refus, { copie(10, 'd:/b/A-2.JPG'), copie(11, 'D:\\A\\a.jpg') })
assert(r and r.date == '01/11/2026')
local d = Doublons.decider({ copie(10, 'd:/b/A-2.JPG'), copie(11, 'D:\\A\\a.jpg') }, r)
assert(d.aVerifier and d.aVerifier:find('01/11/2026', 1, true))
-- Un seul fichier refusé, ou deux fichiers de refus différents, ne suffisent pas.
assert(not Choix.refusDuGroupe(refus, { copie(12, 'D:\\A\\a.jpg'), copie(13, 'D:\\Z\\a.jpg') }))
assert(not Choix.refusDuGroupe(refus, { copie(14, 'D:\\A\\a.jpg'), copie(15, 'D:\\A\\c.jpg') }))
assert(not Choix.refusDuGroupe(Choix.lireRefus(nil), { a1, a2 }))
assert(not Choix.refusDuGroupe(Choix.lireRefus('# commentaire\tD:\\A\\a.jpg\tD:\\B\\a-2.jpg\r\n'), { a1, a2 }))

-- Avertissements des copies écartées par une fusion forcée.
local av = Doublons.avertissements(forcee, true)
local tout = table.concat(av, '\n')
assert(tout:find('b.jpg est retouchée dans Lightroom', 1, true))
assert(tout:find('b-2.jpg est retouchée dans Lightroom', 1, true))
assert(not tout:find('non vérifiée', 1, true))
local manuel = table.concat(Doublons.avertissements({ retirees = { copie(20, 'D:\\v.mov', { video = true, virtuelles = 1 }) } }, false), '\n')
assert(manuel:find('v.mov est une vidéo', 1, true) and manuel:find('présence non vérifiée', 1, true)
  and manuel:find('a des copies virtuelles', 1, true))
assert(#Doublons.avertissements({ retirees = { copie(21, 'D:\\w.mov', { video = true }) } }, true) == 0)

-- Un groupe de versions forcé qui contient toutes les copies d'un groupe proposé le remplace ; un
-- chevauchement partiel est refusé.
do
  local v1, v2 = copie(101, 'D:\\A\\v.jpg', { empreinte = 'e1' }), copie(102, 'D:\\B\\v.jpg', { empreinte = 'e1' })
  local vf, w = copie(103, 'D:\\A\\v_filtered.jpg', { empreinte = 'e2' }), copie(104, 'D:\\C\\w.jpg', { empreinte = 'e1' })
  local ds = { Doublons.decider({ v1, v2 }), Doublons.deciderVersions({ v1, v2, vf }) }
  local idv = Choix.identifiant(ds)
  local lu = assert(Choix.lireCode('DEDUP ' .. idv .. ' force 2', ds, idv))
  local p = Choix.appliquer(ds, lu)
  assert(lu.absorbes[1] == 2 and #p.aFusionner == 1 and #p.forcees == 1 and #p.absorbes == 1)
  assert(#p.forcees[1].retirees == 2, 'le groupe forcé reprend toutes les copies')
  ds = { Doublons.decider({ v1, v2, w }), Doublons.deciderVersions({ v1, vf }) }
  idv = Choix.identifiant(ds)
  local r, message = Choix.lireCode('DEDUP ' .. idv .. ' force 2', ds, idv)
  assert(not r and message:find('partagent des photos', 1, true), 'chevauchement partiel refusé')
  assert(Choix.lireCode('DEDUP ' .. idv .. ' non 1 force 2', ds, idv), 'possible si l’autre groupe est exclu')
end

-- Cas P1140098 : deux copies identiques retouchées (« à vérifier ») et une autre version de la même photo
-- (groupe de versions) partagent une photo. Ils deviennent un seul groupe, forcé en une fois ; un groupe
-- proposé n'est jamais réuni.
do
  local p1 = copie(201, 'D:\\Albums\\P1140098.JPG', { empreinte = 'p', retouchee = true })
  local p2 = copie(202, 'D:\\Parc\\P1140098.JPG', { empreinte = 'p', retouchee = true })
  local p1bis = copie(201, 'D:\\Albums\\P1140098.JPG', { empreinte = 'p', preuveComparaison = { 'preuve' } })
  local p4 = copie(203, 'D:\\Desordre\\P1140098(4).JPG', { empreinte = 'q', preuveComparaison = { 'preuve' } })
  local q1, q2 = copie(204, 'D:\\A\\q.jpg'), copie(205, 'D:\\B\\q-2.jpg')
  local avant = { Doublons.decider({ q1, q2 }), Doublons.decider({ p1, p2 }), Doublons.deciderVersions({ p4, p1bis }) }
  assert(not avant[1].aVerifier and avant[2].aVerifier and avant[3].versions)
  local appels = 0
  local apres = Doublons.reunirChevauchements(avant, function(copies, versions)
    appels = appels + 1
    assert(versions, 'un groupe de versions réuni reste un groupe de versions')
    return Doublons.deciderVersions(copies)
  end)
  assert(appels == 1 and #apres == 2 and apres[1] == avant[1], 'le groupe proposé est intact, à sa place')
  local reuni = apres[2]
  assert(reuni.reunis == 2 and reuni.aVerifier and reuni.versions and #reuni.retirees == 2, 'un groupe de 3 photos')
  local ids = { [reuni.garde.id] = true }
  for _, c in ipairs(reuni.retirees) do ids[c.id] = true end
  assert(ids[201] and ids[202] and ids[203], 'toutes les photos')
  for _, c in ipairs({ reuni.garde, table.unpack(reuni.retirees) }) do
    if c.id == 201 then assert(c.preuveComparaison, 'la copie qui porte la preuve de comparaison est gardée') end
  end
  local idr = Choix.identifiant(apres)
  local lus = assert(Choix.lireCode('DEDUP ' .. idr .. ' force 2:3', apres, idr), 'forcé en une fois')
  local plan = Choix.appliquer(apres, lus)
  assert(#plan.forcees == 1 and #plan.forcees[1].retirees == 2)
  -- Sans chevauchement, rien ne change ; un groupe réuni sans raison propre reste « à vérifier ».
  assert(#Doublons.reunirChevauchements({ avant[1], avant[2] }, error) == 2)
  local x1, x2, x3 = copie(301, 'D:\\A\\x.jpg'), copie(302, 'D:\\B\\x.jpg'), copie(303, 'D:\\C\\x.jpg')
  local v1, v2 = Doublons.decider({ x1, x2 }), Doublons.decider({ x2, x3 })
  v1.aVerifier, v2.aVerifier = 'test', 'test'
  local r = Doublons.reunirChevauchements({ v1, v2 }, function(copies) return Doublons.decider(copies) end)
  assert(#r == 1 and r[1].aVerifier == Doublons.RAISON_REUNIS and not r[1].versions)
end

print('Choix du rapport : OK')
