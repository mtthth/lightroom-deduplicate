package.path = 'lightroom-deduplicate.lrplugin/?.lua;' .. package.path
local temps = 100
function import(nom)
  if nom == 'LrDate' then return { currentTime = function() return temps end } end
  if nom == 'LrTasks' then return { pcall = pcall, yield = function() end } end
  error(nom)
end
local Trace = require 'TraceLectures'
local Catalogue = require 'Catalogue'
local chemin = os.tmpname()
local function contenu()
  local f = assert(io.open(chemin, 'rb')); local s = f:read('*a'); f:close(); return s
end
local captions = {}
local progression = {
  setCaption = function(_, s) captions[#captions + 1] = s end,
  setPortionComplete = function() end, isCanceled = function() return false end,
}
local trace = Trace.ouvrir(chemin, progression)
local contexte = { numero = 676, total = 1099, id = 42, chemin = 'D:/Photos/IMG_8079.jpg', collection = 53, nom = 'Albums' }
local r = trace:appel(contexte, 'getParent', function()
  local s = contenu()
  assert(s:find('DEBUT\t1\tgetParent', 1, true))
  assert(s:find('APPEL\t1\tgetParent', 1, true))
  assert(not s:find('FIN\t1', 1, true), 'le journal doit être persisté avant un appel bloqué')
  assert(s:find('photo=676/1099', 1, true) and s:find('chemin=D:/Photos/IMG_8079.jpg', 1, true))
  temps = temps + 31
  return nil
end)
assert(r == nil and contenu():find('31.000 s', 1, true))
assert(captions[1]:find('IMG_8079.jpg', 1, true) and captions[1]:find('collection 53', 1, true))
local ok = pcall(function() trace:appel(contexte, 'getName', function() error('erreur SDK') end) end)
assert(not ok and contenu():find('ERREUR\t2', 1, true))
-- Si l'UI bloque/échoue, le journal doit la distinguer d'une attente SDK.
local traceUI = Trace.ouvrir(chemin, { setCaption = function() error('erreur UI') end })
local appele = false
ok = pcall(function() traceUI:appel(contexte, 'test UI', function() appele = true end) end)
assert(not ok and not appele)
assert(contenu():find('DEBUT\t1\ttest UI', 1, true) and not contenu():find('APPEL\t1\ttest UI', 1, true))
-- Parcours réel du helper, dont parents et accès au catalogue, avec le diagnostic activé.
local actif = false
local col = { localIdentifier = 53, getName = function() assert(actif); return 'Album' end,
  getParent = function() assert(actif); return nil end }
local photo = { localIdentifier = 42, getContainedCollections = function() return { col } end,
  getContainedPublishedCollections = function() return {} end }
local catalogue = { withPrivateWriteAccessDo = function(_, lire)
  actif = true; lire(); actif = false; return 'executed'
end }
trace.chemins[photo] = contexte.chemin
local donnees = Catalogue.lireAppartenances(catalogue, { photo }, progression, {}, true, trace)
assert(donnees[photo].collections[1].nom == 'Album')
local s = contenu()
assert(s:find('getContainedCollections', 1, true) and s:find('getContainedPublishedCollections', 1, true))
assert(s:find('nom=Album', 1, true) and s:find('Lecture terminée', 1, true))
-- Grandes étapes : durées distinctes des attentes UI et retours multiples préservés.
local profil = Trace.ouvrir(chemin, nil, 'test_profil')
local a, b, c, d = profil:mesurer('analyse', { photos = 80000, cache = false }, function()
  temps = temps + 7; return nil, false, 42, 'sauvegarde.txt'
end)
assert(a == nil and b == false and c == 42 and d == 'sauvegarde.txt')
local terminer = profil:debutEtape('attente_decision_utilisateur')
temps = temps + 60; terminer('ok')
local inachevee = profil:debutEtape('lecture_interrompue')
profil:fin('annule'); profil:fin('annule')
local journal = contenu()
assert(journal:find('ETAPE_FIN\tanalyse\tsecondes=7.000', 1, true))
assert(journal:find('cache=false', 1, true) and journal:find('secondes=60.000', 1, true))
assert(journal:find('ETAPE_FIN\tlecture_interrompue', 1, true))
assert(select(2, journal:gsub('SESSION_FIN', '')) == 1)
os.remove(chemin)
assert(loadfile('lightroom-deduplicate.lrplugin/TraceLectures.lua'))
print('OK : journal avant appel, durées, erreurs SDK/UI, photo, chemin, collection et parents.')
