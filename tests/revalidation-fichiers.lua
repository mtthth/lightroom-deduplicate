package.path = 'lightroom-deduplicate.lrplugin/?.lua;' .. package.path
local R = dofile('lightroom-deduplicate.lrplugin/RevalidationFichiers.lua')
local a = { chemin = 'A.jpg', empreinte = 'jpeg:aaa' }
local b = { chemin = 'B.jpg', empreinte = 'jpeg:aaa' }
local valeurs, lectures, sig = { ['A.jpg'] = 'jpeg:aaa', ['B.jpg'] = 'jpeg:aaa' }, 0, 0
local moteur = { empreinte = function(path) lectures = lectures + 1; return valeurs[path] end,
  empreinteComplete = function(path, annule) lectures = lectures + 1; return valeurs[path] end }
local images = { signature = function(path) sig = sig + 1; return { signature = 'pixels', largeur = 640, hauteur = 480 } end }
local progression = { isCanceled = function() return false end, setCaption = function() end, setPortionComplete = function() end }
local cache = { obtenir = function() error('cache interdit pendant la revalidation') end, retenir = function() end }
assert(R.verifier({ { garde = a, retirees = { b } } }, progression, moteur, images, cache))
assert(lectures == 2 and sig == 0)
valeurs['B.jpg'] = 'jpeg:bbb'
assert(not pcall(R.verifier, { { garde = a, retirees = { b } } }, progression, moteur, images, cache))
valeurs['B.jpg'] = nil
assert(not pcall(R.verifier, { { garde = a, retirees = { b } } }, progression, moteur, images, cache))
valeurs['B.jpg'] = 'jpeg:bbb'; b.empreinte = 'jpeg:bbb'
a.preuveComparaison = { chemin = a.chemin, signature = 'pixels', largeur = 640, hauteur = 480 }
b.preuveComparaison = { chemin = b.chemin, signature = 'pixels', largeur = 640, hauteur = 480 }
assert(R.verifier({ { garde = a, retirees = { b } } }, progression, moteur, images, cache))
b.preuveComparaison.signature = 'ancienne image'
assert(not pcall(R.verifier, { { garde = a, retirees = { b } } }, progression, moteur, images, cache))
b.preuveComparaison = nil
assert(not pcall(R.verifier, { { garde = a, retirees = { b } } }, progression, moteur, images, cache))
-- En parallèle (comme Parallele.pourChaque, qui ignore les erreurs d'une tâche) : même rigueur. Une image
-- dont la tâche échoue ou n'est pas traitée n'est pas validée.
b.preuveComparaison = { chemin = b.chemin, signature = 'pixels', largeur = 640, hauteur = 480 }
local function pourChaque(elements, tache)
  for _, e in ipairs(elements) do pcall(tache, e) end
  return true
end
sig = 0
assert(R.verifier({ { garde = a, retirees = { b } } }, progression, moteur, images, cache, nil, pourChaque))
assert(sig == 2, 'chaque image relue une fois')
b.preuveComparaison.signature = 'ancienne image'
assert(not pcall(R.verifier, { { garde = a, retirees = { b } } }, progression, moteur, images, cache, nil, pourChaque))
b.preuveComparaison.signature = 'pixels'
local enPanne = { signature = function(path) if path == 'B.jpg' then error('magick') end return images.signature(path) end }
assert(not pcall(R.verifier, { { garde = a, retirees = { b } } }, progression, moteur, enPanne, cache, nil, pourChaque),
  'une tâche en erreur ne valide pas son image')
-- Une image non traitée ou ratée une fois est relue seule ; elle n'est validée que si cette lecture réussit.
assert(R.verifier({ { garde = a, retirees = { b } } }, progression, moteur, images, cache, nil,
  function() return true end), 'une image non traitée est relue')
local rates = 0
local passager = { signature = function(path)
  if path == 'B.jpg' and rates == 0 then rates = 1; return nil end
  return images.signature(path)
end }
local journal = {}
local diag = { compteurs = function(_, nom, v) journal[#journal + 1] = { nom = nom, v = v } end }
assert(R.verifier({ { garde = a, retirees = { b } } }, progression, moteur, passager, cache, diag, pourChaque),
  'un échec passager est rattrapé')
assert(journal[#journal].nom == 'revalidation_echec' and journal[#journal].v.seconde == 'ok')
b.preuveComparaison.largeur = 480
local ok, message = pcall(R.verifier, { { garde = a, retirees = { b }, forcee = true } }, progression, moteur, images, cache, nil, pourChaque)
assert(not ok and message:find('dimensions 640x480 au lieu de 480x480', 1, true), message)
b.preuveComparaison.largeur = 640
assert(not R.verifier({ { garde = a, retirees = { b } } }, progression, moteur, images, cache, nil,
  function() return false end), 'annulation pendant les miniatures')
b.preuveComparaison = nil
a.empreinte, b.empreinte = 'complet:sha', 'complet:sha'; valeurs['A.jpg'], valeurs['B.jpg'] = a.empreinte, b.empreinte
assert(R.verifier({ { garde = a, retirees = { b } } }, progression, moteur, images, cache))
local avant = lectures
progression.isCanceled = function() return true end
assert(not R.verifier({ { garde = a, retirees = { b } } }, progression, moteur, images, cache))
assert(lectures == avant)
assert(loadfile('lightroom-deduplicate.lrplugin/CacheAnalyses.lua'))
assert(loadfile('lightroom-deduplicate.lrplugin/FusionnerDoublons.lua'))
print('OK : relecture indépendante du cache, fichier modifié/absent, signature périmée, vidéos intégrales, annulation.')
