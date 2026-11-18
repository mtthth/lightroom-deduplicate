package.path = 'lightroom-deduplicate.lrplugin/?.lua;' .. package.path
function import() return {} end
local Rapides = require 'CollectionsRapides'
local lectures, ajouts, retraits = 0, 0, 0
local catalogue = { getCollectionByLocalIdentifier = function(_, id)
  lectures = lectures + 1; assert(id == 3)
  return { addPhotos = function() ajouts = ajouts + 1 end, removePhotos = function() retraits = retraits + 1 end }
end }
local p1, p2 = { localIdentifier = 10 }, { localIdentifier = 20 }
local function hex(s) return (s:gsub('.', function(c) return string.format('%02x', c:byte()) end)) end
local s = 'LRDC1\nP\t10\t0\nP\t20\t1\nC\t1\t0\t' .. hex('Albums')
  .. '\nC\t2\t1\t' .. hex('2026') .. '\nC\t3\t2\t' .. hex('Été')
  .. '\nL\t10\t3\nL\t20\t3\nEND\t2\t3\t2\n'
local r = Rapides.decoder(s, catalogue, { p1, p2 }, { ['Été'] = true }, true)
assert(lectures == 0, 'aucun accès SDK pendant la lecture du snapshot')
assert(not r[p1].publiee and r[p2].publiee)
local c = r[p1].collections[1]
assert(c.nom == 'Albums / 2026 / Été' and c.exclue and c.objet == r[p2].collections[1].objet)
c.objet:addPhotos({ p1 }); c.objet:removePhotos({ p2 })
assert(lectures == 1 and ajouts == 1 and retraits == 1, 'les modifications passent par le SDK et partagent la résolution')
local court = Rapides.decoder(s, catalogue, { p1, p2 }, {}, false)
assert(court[p1].collections[1].nom == 'Albums / Été')
assert(not pcall(function() Rapides.decoder(s:gsub('END[^\n]+\n', ''), catalogue, { p1, p2 }, {}, true) end))
assert(not pcall(function() Rapides.decoder(s, catalogue, { p1 }, {}, true) end))
-- Une photo présente dans deux groupes (proposé et versions) est dédoublonnée par le script Python.
local double = Rapides.decoder(s, catalogue, { p1, p2, p1 }, {}, true)
assert(double[p1] and double[p2], 'photo répétée dans la liste des candidates')
assert(not pcall(function() Rapides.decoder('ERROR\t' .. hex('Erreur de lecture'), catalogue, {}, {}, true) end))
local disparu = Rapides.decoder(s, { getCollectionByLocalIdentifier = function() return nil end }, { p1, p2 }, {}, true)
assert(not pcall(function() disparu[p1].collections[1].objet:addPhotos({ p1 }) end))
assert(loadfile('lightroom-deduplicate.lrplugin/CollectionsRapides.lua'))
assert(loadfile('lightroom-deduplicate.lrplugin/FusionManuelle.lua'))
assert(loadfile('lightroom-deduplicate.lrplugin/FusionnerDoublons.lua'))
print('OK : snapshot sans appels SDK, chemins UTF-8, publications, exclusions, modifications SDK, échec si incomplet/disparu.')
