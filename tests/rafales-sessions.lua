-- Exécuter : texlua tests/rafales-sessions.lua
package.path = 'lightroom-deduplicate.lrplugin/?.lua;' .. package.path
local R = require 'Rafales'
local Noms = require 'Noms'

assert(not R.collectionProtege({ 'Sessions - Google Photos', 'exemple' }))
assert(not R.collectionProtege({ 'Racine', 'Mes SESSIONS 2026' }))
assert(not R.collectionProtege({ 'Racine', 'Sessions', 'Enfant' }))
assert(R.collectionProtege({ 'Sessions - Google Photos' }, ''))
assert(R.collectionProtege({ 'Sessions - Google Photos' }, 'vacances'))
assert(not R.collectionProtege({ 'Racine', 'Vacances' }, ' vacances '))
assert(R.collectionProtege({ 'Albums - Google Photos' }, 'sessions'))
assert(R.collectionProtege({ 'Outillage' }, 'sessions'))
assert(not R.collectionProtege({ Noms.ENSEMBLE_EPOQUES }, ''))

local function cadre(raisons)
  local c = { fichiers = { { raisons = raisons } } }
  R.proteger(c)
  return c
end
local sessions = 'collection « Sessions - Google Photos / exemple »'
local album = 'collection « Albums - Google Photos / exemple »'
local bloc = { cadre({}), cadre({}), cadre({ album }), cadre({ 'retouches Lightroom' }) }
local rafale = { blocs = { bloc } }
R.decider({ rafale })
assert(bloc[1].decision == 'garder' and bloc[2].decision == 'retirer')
assert(bloc[3].decision == 'protégé' and bloc[4].decision == 'protégé')
assert(cadre({ sessions }).protege)
assert(loadfile('lightroom-deduplicate.lrplugin/ReduireRafales.lua'))
local prefs = {}
function import(nom)
  if nom == 'LrPrefs' then return { prefsForPlugin = function() return prefs end } end
  if nom == 'LrView' then return { bind = function(cle) return cle end } end
  error(nom)
end
local reglages = dofile('lightroom-deduplicate.lrplugin/Reglages.lua')
local props = { observateurs = {}, addObserver = function(self, cle, f) self.observateurs[cle] = f end }
local factory = { static_text = function(_, v) return v end, row = function(_, v) return v end,
  edit_field = function(_, v) return v end, popup_menu = function(_, v) return v end }
reglages.sectionsForTopOfDialog(factory, props)
assert(props.motCollectionRafales == 'sessions')
props.observateurs.motCollectionRafales(nil, nil, '')
assert(prefs.motCollectionRafales == '')
assert(props.motsDossiersDesordre == 'désordre, mal rang' and props.motsDossiersTelecharges == 'manquantes')
props.observateurs.motsDossiersDesordre(nil, nil, 'A trier')
assert(prefs.motsDossiersDesordre == 'A trier')
local props2 = { observateurs = {}, addObserver = props.addObserver }
reglages.sectionsForTopOfDialog(factory, props2)
assert(props2.motCollectionRafales == '' and props2.motsDossiersDesordre == 'A trier')
-- Cadres voisins d'une rafale : jamais la même photo pour le rapprochement par dimensions.
local d = 'E:/Photos/202x/2023/230701. Concert/'
assert(R.prisesDistinctes({ chemin = d .. 'P1250640.JPG', date = 100 }, { chemin = d .. 'P1250641.JPG', date = 101 }))
assert(not R.prisesDistinctes({ chemin = d .. 'P1250640.JPG', date = 100 }, { chemin = d .. 'P1250640-2.JPG', date = 100 }))
assert(not R.prisesDistinctes({ chemin = d .. 'P1250640.JPG', date = 100 }, { chemin = 'F:/Autre/P1250641.JPG', date = 100 }))
assert(not R.prisesDistinctes({ chemin = d .. 'P1250640.JPG', date = 100 }, { chemin = d .. 'P1250641.JPG', date = 400 }))
assert(not R.prisesDistinctes({ chemin = d .. 'P1250640.JPG', date = 100 }, { chemin = d .. 'DSC01234.JPG', date = 100 }))
assert(not R.prisesDistinctes({ chemin = d .. 'P1250640.JPG' }, { chemin = d .. 'P1250641.JPG' }))
local Sm = require 'Similitude'
local vue = string.rep(string.char(100), 768)
local classes = {}
for i = 0, 4 do
  classes[#classes + 1] = { pixels = 1000, octets = 5000 - i, largeur = 4, hauteur = 3, signature = vue,
    copies = { { chemin = d .. 'P125064' .. i .. '.JPG', date = 100 } } }
end
classes[#classes + 1] = { pixels = 500, octets = 100, largeur = 4, hauteur = 3, signature = vue,
  copies = { { chemin = 'F:/Export/copie.jpg', date = 999999 } } }
local function compatibles(a, b) return not R.prisesDistinctes(a.copies[1], b.copies[1]) end
assert(#Sm.regrouper(classes) == 1)
local groupes = Sm.regrouper(classes, compatibles)
assert(#groupes == 5 and #groupes[1] == 2 and groupes[1][2] == classes[6], 'rafale séparée, copie gardée')
print('Protections des rafales : OK')
