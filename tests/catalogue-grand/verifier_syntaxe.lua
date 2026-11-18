local root='sortie/catalogue-grand/'
local spec=assert(loadfile(root..'Manifeste.lua'))()
assert(#spec.photos==10000 and #spec.cas==1438 and spec.importLot==25)
for _,name in ipairs({'Info','Init','Lancer','Preparation'}) do
  assert(loadfile(root..'preparation.lrplugin/'..name..'.lua'))
end
for _,name in ipairs({'Info','Initialiser','FusionnerDoublons','FusionManuelle',
  'ReduireRafales','RestaurerCollections','DiagnosticCatalogue'}) do
  assert(loadfile(root..'environnement/lightroom-deduplicate/lightroom-deduplicate.lrplugin/'..name..'.lua'))
end
print('Syntaxe Lua OK : 10 000 médias, 1 438 cas ; préparation et entrées isolées.')
