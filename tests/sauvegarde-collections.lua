package.path = 'lightroom-deduplicate.lrplugin/?.lua;' .. package.path
function import() return {} end
local M = require 'SauvegardeCollections'
local hierarchie = {
  { id = 1, parent = 0, nom = 'Albums', ensemble = true },
  { id = 2, parent = 1, nom = '2026', ensemble = true },
  { id = 3, parent = 2, nom = 'Été / Paris\tFamille\nVoyage', ensemble = false },
}
local col = { id = 3, nom = 'Albums / Été', cheminComplet = 'Albums / 2026 / Été / Paris', hierarchie = hierarchie }
local garde = { id = 10, chemin = 'D:\\Photos\\Gardée.jpg', collections = { col } }
local retiree = { id = 20, chemin = 'D:\\Photos\\Copie.jpg', collections = { col }, virtuelle = true }
local texte = M.texte('D:\\Catalogue.lrcat', { { garde = garde, retirees = { retiree } } }, 'forcee')
local s = M.lire(texte:gsub('\n', '\r\n'))
assert(#s.ordre == 2 and s.photos[20].virtuelle and s.photos[20].role == 'ecartee')
assert(s.catalogue == 'D:\\Catalogue.lrcat' and s.photos[10].chemin == garde.chemin)
assert(s.date and s.date:match('^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d$'))
assert(s.noeuds[3].nom == hierarchie[3].nom and s.noeuds[2].ensemble)
assert(not pcall(M.lire, texte:gsub('FIN[^\n]+\n', '')))
assert(not pcall(M.lire, texte:gsub('NOEUD\t1\t0', 'NOEUD\t1\t2')))
assert(not pcall(M.texte, 'cat', { { garde = { id = 1, chemin = 'x', collections = { { id = 123 } } }, retirees = {} } }, 'test'))
local ajouts, supprimes, crees = {}, {}, {}
local corbeille = { localIdentifier = 999, getName = function() return 'Doublons à retirer' end,
  removePhotos = function(_, ps) for _, p in ipairs(ps) do supprimes[p.id] = true end end }
local photos = {}
for _, p in ipairs(s.ordre) do photos[p.id] = { id = p.id, getContainedCollections = function() return { corbeille } end } end
local racine = { localIdentifier = 1, getName = function() return 'Albums' end, getParent = function() return nil end,
  type = function() return 'LrCollectionSet' end }
local cat = { getCollectionByLocalIdentifier = function(_, id) if id == 1 then return racine end end }
local function creer(nom, parent, ensemble)
  local obj = { localIdentifier = 100 + #crees, addPhotos = function(_, ps) ajouts[nom] = ps end }
  crees[#crees + 1] = { nom = nom, parent = parent, ensemble = ensemble, objet = obj }
  return obj
end
function cat:createCollectionSet(n, p) return creer(n, p, true) end
function cat:createCollection(n, p) return creer(n, p, false) end
local retablir = M.restaurer(cat, s, photos, { ['Doublons à retirer'] = true })
assert(#crees == 2 and crees[1].nom == '2026' and crees[1].parent == racine)
assert(crees[2].parent == crees[1].objet and #ajouts[hierarchie[3].nom] == 2)
assert(supprimes[10] and supprimes[20] and #retablir == 1)
local Rafales = require 'Rafales'
local protege = { id = 30, chemin = 'D:\\Photos\\Protegee.jpg', collections = { col } }
local decisions = Rafales.decisionsSauvegarde({ {
  { decision = 'garder', fichiers = { garde } },
  { decision = 'retirer', fichiers = { retiree } },
  { decision = 'protege', fichiers = { protege } },
} })
local rafales = M.lire(M.texte('D:\\Catalogue.lrcat', decisions, 'rafales'))
assert(rafales.genre == 'rafales' and #rafales.ordre == 3)
assert(rafales.photos[10].role == 'gardee' and rafales.photos[30].role == 'gardee')
assert(rafales.photos[20].role == 'ecartee' and rafales.photos[30].collections[1] == 3)
assert(not pcall(Rafales.decisionsSauvegarde, { { { decision = 'retirer', fichiers = { retiree } } } }))
local autreGarde = { id = 40, chemin = 'D:\\Photos\\Autre.jpg', collections = { col } }
local autreRetiree = { id = 50, chemin = 'D:\\Photos\\Autre2.jpg', collections = { col } }
local deuxRafales = Rafales.decisionsSauvegarde({
  { { decision = 'garder', fichiers = { garde } }, { decision = 'retirer', fichiers = { retiree } } },
  { { decision = 'garder', fichiers = { autreGarde } }, { decision = 'retirer', fichiers = { autreRetiree } } },
})
local nouveauTexte = M.texte('D:\\Catalogue.lrcat', deuxRafales, 'rafales')
local groupes = M.lire(nouveauTexte)
assert(#groupes.groupes == 2 and #groupes.groupes[1].photos == 2 and #groupes.groupes[2].photos == 2)
local selection = M.selectionner(groupes, { 2 })
assert(#selection.ordre == 2 and selection.photos[40] and selection.photos[50] and not selection.photos[10])
local marqueur = { getName = function() return 'Rafale traitée' end }
local autreMot = { getName = function() return 'Famille' end }
local suppressions = {}
local photosMots = {}
for _, id in ipairs({ 10, 20, 40, 50 }) do
  photosMots[id] = {
    getRawMetadata = function(_, cle) assert(cle == 'keywords'); return { marqueur, autreMot } end,
    removeKeyword = function(_, mot) assert(mot == marqueur); suppressions[id] = true end,
  }
end
M.retirerMotCleRafales(selection, photosMots, 'Rafale traitée')
assert(suppressions[40] and suppressions[50] and not suppressions[10] and not suppressions[20])
suppressions = {}
M.retirerMotCleRafales(s, photosMots, 'Rafale traitée')
assert(next(suppressions) == nil)
assert(not pcall(M.selectionner, groupes, {}))
assert(not pcall(M.selectionner, groupes, { 2, 2 }))
assert(not pcall(M.lire, nouveauTexte:gsub('GROUPEPHOTO\t2\t50\n', '')))
local ancienTexte = nouveauTexte:gsub('SAUVEGARDE_COLLECTIONS_V2', 'SAUVEGARDE_COLLECTIONS_V1')
  :gsub('GROUPE\t%d+\n', ''):gsub('GROUPEPHOTO\t%d+\t%d+\n', '')
local ancienne = M.lire(ancienTexte)
assert(ancienne.ancienne and #ancienne.groupes == 1 and #ancienne.groupes[1].photos == 4)
assert(#M.selectionner(ancienne, { 1 }).ordre == 4)
assert(loadfile('lightroom-deduplicate.lrplugin/ReduireRafales.lua'))
assert(loadfile('lightroom-deduplicate.lrplugin/RestaurerCollections.lua'))
assert(loadfile('lightroom-deduplicate.lrplugin/FusionnerDoublons.lua'))
assert(loadfile('lightroom-deduplicate.lrplugin/FusionManuelle.lua'))
print('OK : sauvegarde UTF-8, chemins complets, copies virtuelles, rejet incomplet/cycle, recréation et restauration groupée.')
