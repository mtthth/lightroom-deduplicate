-- Exécuter : luajit tests/copies-virtuelles.lua
-- Faux SDK : copies virtuelles des copies écartées recréées sur la copie gardée.
package.path = 'lightroom-deduplicate.lrplugin/?.lua;' .. package.path
function import(nom)
  if nom == 'LrTasks' then return { pcall = pcall, sleep = function() end } end
  return {}
end
local Doublons = require 'Doublons'
local CopiesVirtuelles = require 'CopiesVirtuelles'
local SauvegardeCollections = require 'SauvegardeCollections'

-- Collections : chaque ajout ou retrait est noté « nom+id » ou « nom-id ».
local journal = {}
local function collection(id, nom, hierarchie)
  local objet = {}
  function objet:addPhotos(ps) for _, p in ipairs(ps) do journal[#journal + 1] = nom .. '+' .. p.localIdentifier end end
  function objet:removePhotos(ps) for _, p in ipairs(ps) do journal[#journal + 1] = nom .. '-' .. p.localIdentifier end end
  function objet:getName() return nom end
  objet.localIdentifier = id
  return { id = id, nom = nom, objet = objet, dynamique = false, exclue = nom == Doublons.COLLECTION,
    cheminComplet = nom, hierarchie = hierarchie or { { id = id, parent = 0, nom = nom, ensemble = false } } }
end
local vacances, plage, aRetirer, affichee = collection(1, 'Vacances'), collection(2, 'Plage'),
  collection(3, Doublons.COLLECTION), collection(4, 'Affichée')

local photos = {}
local function photo(id, champs)
  local p = { localIdentifier = id, brut = champs.brut or {}, formate = champs.formate or {}, reglages = champs.reglages,
    collections = champs.collections or {}, appliques = {} }
  function p:getRawMetadata(cle) return self.brut[cle] end
  function p:getDevelopSettings() return self.reglages end
  function p:applyDevelopSettings(r, nom) self.reglages = r; self.appliques[#self.appliques + 1] = nom end
  function p:addKeyword(mot) journal[#journal + 1] = 'mot ' .. mot:getName() .. ' ' .. self.localIdentifier end
  function p:setRawMetadata(cle, valeur) journal[#journal + 1] = cle .. '=' .. tostring(valeur) .. ' ' .. self.localIdentifier end
  function p:getContainedCollections()
    local liste = {}
    for i, c in ipairs(self.collections) do liste[i] = c.objet end
    return liste
  end
  photos[id] = p
  return p
end
local function mot(nom) return { localIdentifier=nom, getName = function() return nom end } end

-- Copie gardée G (10), copie écartée R (20) avec deux copies virtuelles : V1 (21), à recréer, et V2 (22), déjà
-- mise à retirer. Une vidéo écartée (30) a aussi une copie virtuelle, jamais recréée.
local G = photo(10, { brut = { rating = 2, pickStatus = 0, keywords = { mot('Mer') } } })
local reglagesV1 = { WhiteBalance = 'As Shot', Temperature = 5200, Tint = 3, Exposure2012 = 0.35,
  ToneCurvePV2012 = { 0, 0, 255, 255 }, CropLeft = 0.1 }
local V1 = photo(21, { brut = { isVirtualCopy = true, rating = 4, pickStatus = 1, keywords = { mot('Mer'), mot('N&B') } },
  formate = { copyName = 'Noir et blanc', caption = 'Coucher de soleil' }, reglages = reglagesV1 })
local V2 = photo(22, { brut = { isVirtualCopy = true }, formate = { copyName = 'Copie 2' }, reglages = {} })
local R = photo(20, { brut = { virtualCopies = { V1, V2 } } })
local video = photo(30, { brut = { virtualCopies = { photo(31, {}) } } })
local appartenances = { [V1] = { collections = { vacances, plage } }, [V2] = { collections = { aRetirer } } }

local function copie(p, chemin, extra)
  local c = { photo = p, id = p.localIdentifier, chemin = chemin, collections = {}, motsCles = {}, textes = {} }
  for k, v in pairs(extra or {}) do c[k] = v end
  return c
end
local garde = copie(G, 'D:\\A\\IMG_1.jpg', { note = 2, motsCles = { { nom = 'Mer', objet=G.brut.keywords[1] } } })
local retiree = copie(R, 'D:\\B\\IMG_1-2.jpg', { virtuelles = 2, retouchee = true })
local retireeVideo = copie(video, 'D:\\B\\clip.mov', { virtuelles = 1, video = true })
local decision = { garde = garde, retirees = { retiree, retireeVideo } }

-- Annonces de la confirmation : la copie écartée est recréée, la vidéo reste signalée.
assert(Doublons.virtuellesRecreees(retiree, garde) and not Doublons.virtuellesRecreees(retireeVideo, garde))
local annonces = Doublons.annoncesVirtuelles(decision)
assert(#annonces == 1 and annonces[1]:find('IMG_1-2.jpg a des copies virtuelles : elles seront recréées', 1, true))
local avertissements = table.concat(Doublons.avertissements(decision, true), '\n')
assert(avertissements:find('clip.mov a des copies virtuelles : elles ne seront pas recréées (vidéo)', 1, true))
assert(not avertissements:find('IMG_1-2.jpg a des copies virtuelles', 1, true))
-- Fusion manuelle : une copie virtuelle sélectionnée avec son original est fusionnée, pas recréée.
local selectionnee = copie(V1, 'D:\\B\\IMG_1-2.jpg', { virtuelle = true })
local manuelle = CopiesVirtuelles.aRecreer({ garde = garde, retirees = { retiree, selectionnee } },
  function(c) return c.photo:getRawMetadata('virtualCopies') end)
assert(#manuelle == 1 and manuelle[1].source.photo == V2)

-- Lecture : V1 seule (V2 est déjà à retirer), avec ses métadonnées et ses réglages préparés.
local catalogue = { selection = { G, R } }
function catalogue:batchGetRawMetadata(liste, cles)
  local r = {}
  for _, p in ipairs(liste) do
    r[p] = {}
    for _, cle in ipairs(cles) do r[p][cle] = p.brut[cle] end
  end
  return r
end
function catalogue:batchGetFormattedMetadata(liste, cles)
  local r = {}
  for _, p in ipairs(liste) do
    r[p] = {}
    for _, cle in ipairs(cles) do r[p][cle] = p.formate[cle] end
  end
  return r
end
local lues
local entrees = CopiesVirtuelles.lire(catalogue, { decision }, function(liste) lues = liste; return appartenances end)
assert(#lues == 2 and #entrees == 1 and decision.virtuelles[1] == entrees[1])
local e = entrees[1]
assert(e.source.photo == V1 and e.retiree == retiree and e.source.nomCopie == 'Noir et blanc' and e.source.note == 4)
assert(e.source.chemin == retiree.chemin and e.source.textes.caption == 'Coucher de soleil')
assert(e.reglages.Temperature == nil and e.reglages.Tint == nil and e.reglages.Exposure2012 == 0.35, 'balance des blancs recalculée')
assert(reglagesV1.Temperature == 5200, 'réglages lus inchangés')
assert(CopiesVirtuelles.reglages({ WhiteBalance = 'Custom', Temperature = 4800 }).Temperature == 4800)
-- Sans copie virtuelle à recréer, aucune lecture.
local sans = { garde = garde, retirees = { copie(photo(40, {}), 'D:\\C\\x.jpg') } }
assert(#CopiesVirtuelles.lire(catalogue, { sans }, function() error('lecture inutile') end) == 0 and #sans.virtuelles == 0)

-- Sauvegarde : l'ancienne copie virtuelle est une copie écartée.
local pourSauvegarde = CopiesVirtuelles.pourSauvegarde({ decision })
assert(#pourSauvegarde[1].retirees == 3 and pourSauvegarde[1].retirees[3] == e.source and #decision.retirees == 2)
for _, c in ipairs({ garde, retiree, retireeVideo }) do c.collections = {} end
local sauvegarde = SauvegardeCollections.lire(SauvegardeCollections.texte('D:\\Catalogue.lrcat', pourSauvegarde, 'forcee'))
assert(sauvegarde.photos[21].virtuelle and sauvegarde.photos[21].role == 'ecartee' and #sauvegarde.photos[21].collections == 2)

-- Création : la gardée doit pouvoir être sélectionnée ; la sélection d'origine est rétablie.
local selectionnables = { [10] = true }
local creees = {}
function catalogue:setSelectedPhotos(active, autres)
  if selectionnables[active.localIdentifier] then
    self.selection = { active }
    for _, p in ipairs(autres) do if p ~= active then self.selection[#self.selection + 1] = p end end
  end
end
function catalogue:getTargetPhoto() return self.selection[1] end
function catalogue:getTargetPhotos() return self.selection end
function catalogue:createVirtualCopies(nom)
  local n = photo(100 + #creees, { brut = { isVirtualCopy = true, masterPhoto = self.maitre or self.selection[1], rating = 2,
    pickStatus = 0, keywords = { mot('Mer') } }, formate = { copyName = nom }, collections = { affichee } })
  creees[#creees + 1] = n
  self.selection = { n }
  return { n }
end
local corbeilles = { [Doublons.COLLECTION] = true }

selectionnables[10] = false
local ok, erreur = pcall(CopiesVirtuelles.creer, catalogue, entrees, corbeilles)
assert(not ok and erreur:find('IMG_1.jpg n’a pas pu être sélectionnée', 1, true) and erreur:find('Rien n’a été modifié', 1, true))
assert(#creees == 0 and not erreur:find('déjà créée', 1, true))
selectionnables[10] = true

-- Lightroom crée une copie d'une autre photo : erreur, avec la copie déjà créée.
catalogue.selection = { G, R }
catalogue.maitre = R
ok, erreur = pcall(CopiesVirtuelles.creer, catalogue, entrees, corbeilles)
assert(not ok and erreur:find('Aucune fusion', 1, true) and erreur:find('1 copie virtuelle déjà créée', 1, true))
assert(catalogue.selection[1] == G and catalogue.selection[2] == R, 'sélection rétablie après erreur')
catalogue.maitre, creees = nil, {}

catalogue.selection = { G, R }
CopiesVirtuelles.creer(catalogue, entrees, corbeilles)
local N = creees[1]
assert(#creees == 1 and e.nouvelle.photo == N and N.formate.copyName == 'Noir et blanc', 'même nom de copie')
assert(catalogue.selection[1] == G and catalogue.selection[2] == R and #catalogue.selection == 2, 'sélection rétablie')
-- La nouvelle copie quitte la collection affichée, où Lightroom l'a rangée, et rejoint celles de l'ancienne.
assert(#e.sortir == 1 and e.sortir[1].id == affichee.id)
assert(#e.effets.collections == 2 and #e.effets.quittees == 2 and #e.effets.motsCles == 1 and e.effets.motsCles[1].nom == 'N&B')
assert(e.effets.note == 4 and e.effets.drapeau == 1 and e.effets.textes[1].cle == 'caption')

-- Application dans l'accès en écriture de la fusion.
journal = {}
local corbeille = collection(3, Doublons.COLLECTION).objet
CopiesVirtuelles.appliquer(e, corbeille)
assert(N.reglages == e.reglages and N.appliques[1]:find('IMG_1-2.jpg', 1, true))
local fait = table.concat(journal, ' | ')
for _, attendu in ipairs({ 'Affichée-100', 'Vacances+100', 'Plage+100', 'Vacances-21', 'Plage-21', 'mot N&B 100',
  'rating=4 100', 'pickStatus=1 100', 'caption=Coucher de soleil 100', Doublons.COLLECTION .. '+21' }) do
  assert(fait:find(attendu, 1, true), attendu .. ' manquant : ' .. fait)
end
assert(not fait:find(' 10$') and not fait:find('+10 ', 1, true), 'la copie gardée n’est pas touchée')

-- Vérification après fusion : réglages relus identiques, puis un réglage différent.
local ecarts = CopiesVirtuelles.verifier(entrees)
assert(#ecarts == 0)
assert(CopiesVirtuelles.bilan(entrees, ecarts, Doublons.COLLECTION):find('1 copie virtuelle recréée', 1, true))
N.reglages = { WhiteBalance = 'As Shot', Exposure2012 = 0.3500001, ToneCurvePV2012 = { 0, 0, 255, 250 }, CropLeft = 0.1 }
ecarts = CopiesVirtuelles.verifier(entrees)
assert(#ecarts == 1 and #ecarts[1].cles == 1 and ecarts[1].cles[1] == 'ToneCurvePV2012', 'tolérance numérique, tables comparées')
local bilan = CopiesVirtuelles.bilan(entrees, ecarts, Doublons.COLLECTION)
assert(bilan:find('IMG_1-2.jpg « Noir et blanc » : ToneCurvePV2012', 1, true))
assert(CopiesVirtuelles.bilan({}, {}, Doublons.COLLECTION) == '')
assert(CopiesVirtuelles.completerErreur('Fusion annulée.', { creees = 2 }):find('2 copies virtuelles déjà créées', 1, true))
assert(CopiesVirtuelles.completerErreur('Fusion annulée.', {}) == 'Fusion annulée.')

print('OK : copies virtuelles lues, sauvegardées, recréées sur la gardée avec réglages, nom, métadonnées et collections.')
