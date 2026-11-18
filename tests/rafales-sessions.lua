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
  edit_field = function(_, v) return v end }
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
print('Protections des rafales : OK')
