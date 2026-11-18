-- Exécuter : texlua tests/catalogue.lua
-- Faux SDK : les lectures doivent partager un accès, jamais changer le catalogue.
package.path = 'lightroom-deduplicate.lrplugin/?.lua;' .. package.path
local actifs, acces, yields, lus = false, 0, 0, 0
function import(nom)
  assert(nom == 'LrTasks')
  return { pcall = pcall, yield = function() assert(not actifs); yields = yields + 1 end }
end
local Catalogue = require 'Catalogue'
local catalogue = {}
function catalogue:withPrivateWriteAccessDo(f, options)
  assert(not actifs, 'accès imbriqué')
  assert(options.timeout == 5)
  acces = acces + 1; actifs = true
  local ok, erreur = pcall(f)
  actifs = false
  if not ok then error(erreur) end
  return 'executed'
end
local function noeud(id, nom, parent)
  local n = { localIdentifier = id, noms = 0, parents = 0 }
  function n:getName() assert(actifs); self.noms = self.noms + 1; return nom end
  function n:getParent() assert(actifs); self.parents = self.parents + 1; return parent end
  return n
end
local function photo(id, cols, publiee)
  local p = { localIdentifier = id }
  function p:getContainedCollections() assert(actifs); lus = lus + 1; return cols end
  function p:getContainedPublishedCollections() assert(actifs); return publiee and { true } or {} end
  return p
end
local function progression(annulation)
  local p = { captions = 0 }
  function p:setCaption() assert(not actifs); self.captions = self.captions + 1 end
  function p:isCanceled() return annulation and annulation() or false end
  function p:setPortionComplete(fin, total) assert(not actifs and fin <= total) end
  return p
end
local racine = noeud(1, 'Albums')
local annee = noeud(2, '2026', racine)
local album = noeud(3, 'Vacances', annee)
local autre = noeud(4, 'Vacances', racine)
local corbeille = noeud(5, 'Doublons à retirer')
local photos = {}
for i = 1, 1099 do photos[i] = photo(i, { album, autre, corbeille }, i % 2 == 0) end
local p = progression()
local resultat = Catalogue.lireAppartenances(catalogue, photos, p, { ['Doublons à retirer'] = true }, true)
assert(acces == 44 and yields == 44 and p.captions == 44)
for i, ph in ipairs(photos) do
  local info = assert(resultat[ph])
  assert(info.publiee == (i % 2 == 0))
  assert(#info.collections == 3)
  assert(info.collections[1].nom == 'Albums / 2026 / Vacances')
  assert(info.collections[2].nom == 'Albums / Vacances')
  assert(info.collections[1].id ~= info.collections[2].id)
  assert(info.collections[3].exclue and not info.collections[1].exclue)
  assert(info.collections[1].objet == album and not info.collections[1].dynamique)
end
assert(album.noms == 1 and album.parents == 1 and racine.noms == 1 and annee.parents == 1)
local court = Catalogue.lireAppartenances(catalogue, { photos[1] }, progression(), {}, false)
assert(court[photos[1]].collections[1].nom == 'Albums / Vacances')
assert(album.noms == 2, 'le cache ne doit pas survivre à une analyse')
local avant = acces
assert(Catalogue.lireAppartenances(catalogue, photos, progression(function() return true end), {}, true) == nil)
assert(acces == avant, 'annulation avant le premier accès')
local avantLus = lus
assert(Catalogue.lireAppartenances(catalogue, photos, progression(function() return lus >= avantLus + 2 end), {}, true) == nil)
assert(lus == avantLus + 2, 'annulation dans un lot')
local occupe = { withPrivateWriteAccessDo = function() return 'aborted' end }
local ok = pcall(function() Catalogue.lireAppartenances(occupe, photos, progression(), {}, true) end)
assert(not ok, 'un timeout doit arrêter l’analyse et non ignorer les collections')
local panne = photo(5000, {})
function panne:getContainedCollections() error('lecture impossible') end
ok = pcall(function() Catalogue.lireAppartenances(catalogue, { panne }, progression(), {}, true) end)
assert(not ok, 'une erreur ne doit jamais être remplacée par une appartenance vide')
local boucle = noeud(999, 'Boucle')
function boucle:getParent() return self end
ok = pcall(function()
  Catalogue.lireAppartenances(catalogue, { photo(5001, { boucle }) }, progression(), {}, true)
end)
assert(not ok, 'cycle de collections détecté')
-- Vérification après fusion : une seule lecture des collections « à retirer », sans lecture par photo.
local function collection(nom, contenu)
  local c = { lectures = 0 }
  function c:getName() return nom end
  function c:getPhotos() assert(actifs); self.lectures = self.lectures + 1; return contenu end
  return c
end
local aRetirer, ailleurs = collection('Doublons à retirer', { photos[3], photos[7] }), collection('Vacances', { photos[1] })
local avecCorbeilles = { getChildCollections = function() return { ailleurs, aRetirer } end,
  withPrivateWriteAccessDo = catalogue.withPrivateWriteAccessDo }
avantLus = lus
local ids = Catalogue.lectureGroupee(avecCorbeilles, function()
  return (Catalogue.photosDesCollections(avecCorbeilles, { 'Doublons à retirer', 'Rafales à retirer' }, true))
end)
assert(ids[3] and ids[7] and not ids[1], 'seules les collections à retirer sont lues')
assert(aRetirer.lectures == 1 and ailleurs.lectures == 0 and lus == avantLus, 'une lecture par collection, aucune par photo')
local illisible = { getChildCollections = function() error('lecture impossible') end }
assert(select(2, Catalogue.photosDesCollections(illisible, { 'Doublons à retirer' })) == 0, 'lecture lâche : liste vide')
assert(not pcall(Catalogue.photosDesCollections, illisible, { 'Doublons à retirer' }, true), 'lecture stricte : erreur visible')
-- La détection des publications protège toujours les copies qui seraient écartées.
local Doublons = require 'Doublons'
local copies = {
  { id = 1, chemin = 'C:/2026/IMG.jpg', empreinte = 'identique', collections = {}, publiee = false },
  { id = 2, chemin = 'C:/2026/IMG-2.jpg', empreinte = 'identique', collections = {}, publiee = true },
}
assert(Doublons.decider(copies).aVerifier == 'une copie à retirer est publiée')
for _, fichier in ipairs({ 'Catalogue', 'FusionManuelle', 'FusionnerDoublons', 'DiagnosticCatalogue', 'RapportHtml', 'Info' }) do
  assert(loadfile('lightroom-deduplicate.lrplugin/' .. fichier .. '.lua'))
end
print('OK : 1099 photos, 44 accès groupés, chemins, publications, exclusions, cache, annulation, timeout, erreurs, cycle et syntaxe.')
