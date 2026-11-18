package.path = 'lightroom-deduplicate.lrplugin/?.lua;' .. package.path
local L = require 'LibellesRestauration'
assert(L.dateDossier('C:\\Photos\\2026-08-15\\image.jpg') == '2026-08-15')
assert(L.dateDossier('C:\\Photos\\image-2026-08-15.jpg') == nil)
assert(L.dateDossier('C:/2020-01-01/sessions/2026-08-15/img.jpg') == '2026-08-15')
local texte = 'Photo : C:\\Photographies été\\2026-08-15\\photo longue.jpg'
local lignes = L.lignes(texte, 12)
assert(#lignes > 1 and table.concat(lignes) == texte)
assert(loadfile('lightroom-deduplicate.lrplugin/RestaurerCollections.lua'))
print('Libellés de restauration : OK')
