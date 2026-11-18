local racine = 'sortie/catalogue-compact/'
assert(loadfile('tests/catalogue-compact/Campagne.lua'))
assert(loadfile('tests/catalogue-compact/RestaurerTest.lua'))
assert(loadfile('tests/catalogue-compact/VideosTest.lua'))
for _, nom in ipairs({ 'preparation.lrplugin/Info.lua', 'preparation.lrplugin/Init.lua',
  'preparation.lrplugin/Preparation.lua', 'Manifeste.lua' }) do
  assert(loadfile(racine..nom)); print('Syntaxe OK : '..nom)
end
local spec=dofile(racine..'Manifeste.lua')
assert(#spec.cas==40 and #spec.photos==168)
local prefix=racine..'environnement/lightroom-deduplicate/lightroom-deduplicate.lrplugin/'
for _,nom in ipairs({'Initialiser','FusionnerDoublons','FusionManuelle','ReduireRafales','RestaurerCollections','DiagnosticCatalogue','TestManquant','TestModifier','TestRestaurer'}) do
  assert(loadfile(prefix..nom..'.lua'))
end
print('40 scénarios, 168 fichiers ; toutes les entrées isolées compilent.')
