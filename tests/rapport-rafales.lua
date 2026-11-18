package.path = 'lightroom-deduplicate.lrplugin/?.lua;' .. package.path
local R = require 'RapportRafales'
local garde = { nom = '<garde>', decision = 'garder', fichiers = { { chemin = 'a&b.jpg' } }, apercuRapport = 'vignettes/1.jpg', nettete = 12.5 }
local protege = { nom = 'protégé', decision = 'protégé', raisons = { 'collection <test>' }, fichiers = { { chemin = 'p.jpg' } } }
local retire = { nom = 'retiré', decision = 'retirer', pourquoi = 'moins net', fichiers = { { chemin = 'r.jpg' } } }
local page = R.page('Dossier <test>', { { blocs = { { garde, protege, retire } } } }, { rafales = 1, cadres = 3, retires = 1, proteges = 1 })
for _, texte in ipairs({ 'Dossier &lt;test&gt;', '&lt;garde&gt;', 'a&amp;b.jpg', 'collection &lt;test&gt;', 'moins net', 'vignettes/1.jpg', 'Aperçu indisponible' }) do
  assert(page:find(texte, 1, true), texte)
end
assert(loadfile('lightroom-deduplicate.lrplugin/ReduireRafales.lua'))
print('Rapport des rafales : OK')
