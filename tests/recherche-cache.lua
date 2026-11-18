-- Exécute la fonction de recherche de production avec le vrai cache SQLite/Python,
-- sur des fichiers de test et des lecteurs d'image déterministes.
local fs = require 'lfs'
local racine, temp = assert(arg[1]), assert(arg[2])
local python = arg[3] or 'C:/Python314/python.exe'
local dossier = racine .. '/tests/cache-integration'
assert(not fs.attributes(dossier), 'Le dossier de test existe déjà')
assert(fs.mkdir(dossier))
_PLUGIN = { path = racine .. '/lightroom-deduplicate.lrplugin' }
package.path = _PLUGIN.path .. '/?.lua;' .. package.path
local function lire(path) local f = io.open(path, 'rb'); if not f then return nil end; local s = f:read('*a'); f:close(); return s end
local sequence = 0
local fichiers = {
  exists = function(p) return fs.attributes(p, 'mode') == 'file' and 'file' or nil end,
  readFile = lire, delete = function(p) assert(os.remove(p)) end,
  copy = function(a,b) local f = assert(io.open(b, 'wb')); f:write(assert(lire(a))); f:close() end,
}
local taches = { pcall = pcall, yield = function() end, sleep = function() end,
  startAsyncTask = function(f) f() end, execute = function(cmd) local ok, _, code = os.execute(cmd); return ok and 0 or code end }
function import(nom)
  if nom == 'LrFileUtils' then return fichiers end
  if nom == 'LrPathUtils' then return { child = function(a,b) return a .. '/' .. b end, getStandardFilePath = function() return temp end } end
  if nom == 'LrTasks' then return taches end
  if nom == 'LrDate' then return { currentTime = os.clock } end
  if nom == 'LrMD5' then return { digest = function() sequence = sequence + 1; return 'integration-' .. os.time() .. '-' .. sequence end } end
  error(nom)
end
local Cache = require 'CacheAnalyses'
local comptes = { f = 0, s = 0 }
local chemins = {}
for i = 1, 4 do
  assert(fs.mkdir(dossier .. '/' .. i))
  chemins[i] = dossier .. '/' .. i .. (i < 4 and '/IMG.jpg' or '/OTHER.jpg')
end
local function ecrire(i, caractere)
  local f = assert(io.open(chemins[i], 'wb')); f:write('jpeg:' .. string.rep(caractere, 32)); f:close()
end
ecrire(1, 'a'); ecrire(2, 'a'); ecrire(3, 'b'); ecrire(4, 'd')
local Empreintes = { empreinte = function(path) comptes.f = comptes.f + 1; return assert(lire(path)) end }
local Vignettes = { magick = function() return python end,
  signature = function(path)
    comptes.s = comptes.s + 1
    local b = assert(lire(path)):sub(-1)
    return { signature = string.rep(string.char(b == 'a' and 0 or b == 'b' and 1 or 100), 768),
      largeur = b == 'b' and 320 or 640, hauteur = b == 'b' and 240 or 480 }
  end }
local diag = { compteurs = function() end, debutEtape = function() return function() end end,
  mesurer = function(_, _, _, f) return f() end }
local progression = { isCanceled = function() return false end, setCaption = function() end, setPortionComplete = function() end }
local source = assert(lire(_PLUGIN.path .. '/FusionnerDoublons.lua'))
local debut = assert(source:find('local function classesDuGroupe', 1, true))
local fin = assert(source:find('-- Complète les copies des groupes', debut, true))
local preparer = assert(load('return function(Empreintes,Vignettes,LrTasks,LrDate,Doublons,Similitude,Parallele) '
  .. 'local PARALLELE=4; local function nomFichier(p) return p:match("[^/\\\\]+$") or p end; '
  .. source:sub(debut, fin - 1) .. '\nreturn chercherGroupes end'))()
local chercher = preparer(Empreintes, Vignettes, taches, { currentTime = os.clock }, require 'Doublons', require 'Similitude', require 'Parallele')
local function lancer()
  local copies = {}
  for i, path in ipairs(chemins) do copies[i] = { id = i, chemin = path, taille = 37, date = 1 } end
  local cache = Cache.ouvrir(dossier, python, diag)
  local resultat = chercher(copies, progression, diag, cache)
  assert(not cache.desactive, 'Le cache doit réellement fonctionner, sans fallback')
  return resultat, cache
end
local froid = lancer()
assert(#froid.groupes == 1 and #froid.groupes[1] == 3 and comptes.f == 4 and comptes.s == 2)
comptes.f, comptes.s = 0, 0
local chaud, cache = lancer()
assert(#chaud.groupes == 1 and #chaud.groupes[1] == 3 and comptes.f == 0 and comptes.s == 0)
assert(cache.stats.F.reutilises == 4 and cache.stats.S.reutilises == 2)
for i, c in ipairs(froid.groupes[1]) do assert(chaud.groupes[1][i].id == c.id and chaud.groupes[1][i].empreinte == c.empreinte) end
local R = dofile(_PLUGIN.path .. '/RevalidationFichiers.lua')
local decision = (require 'Doublons').decider(chaud.groupes[1])
assert(R.verifier({ decision }, progression, Empreintes, Vignettes, cache))
assert(comptes.f == 3 and comptes.s == 2, 'la fusion doit relire même après une analyse entièrement servie par le cache')
comptes.f, comptes.s = 0, 0
ecrire(3, 'c')
local change = lancer()
assert(#change.groupes == 1 and #change.groupes[1] == 2 and comptes.f == 1 and comptes.s == 1)
-- Un cache endommagé doit déclencher un recalcul, jamais des résultats vides/crédibles.
local f = assert(io.open(dossier .. '/cache-analyses.sqlite3', 'wb')); f:write('not sqlite'); f:close()
local copies = {}
for i, path in ipairs(chemins) do copies[i] = { id = i, chemin = path, taille = 37, date = 1 } end
local corrompu = Cache.ouvrir(dossier, python, diag)
local resultat = chercher(copies, progression, diag, corrompu)
assert(corrompu.desactive and #resultat.groupes == 1 and #resultat.groupes[1] == 2)
for i, path in ipairs(chemins) do assert(os.remove(path)); assert(fs.rmdir(dossier .. '/' .. i)) end
assert(os.remove(dossier .. '/cache-analyses.sqlite3')); assert(fs.rmdir(dossier))
-- Régression : les copies exactes B et B' relient deux groupes nom/date,
-- A~B et B'~C, sans que A ressemble à C. La décision finale doit les protéger.
local synthese = {
  { id = 1, chemin = 'C:/a/X.jpg', date = 1, taille = 10 },
  { id = 2, chemin = 'C:/b/X.jpg', date = 1, taille = 10 },
  { id = 3, chemin = 'C:/c/Y.jpg', date = 1, taille = 10 },
  { id = 4, chemin = 'C:/d/Y.jpg', date = 1, taille = 10 },
}
local hashes = { ['C:/a/X.jpg'] = 'A', ['C:/b/X.jpg'] = 'B', ['C:/c/Y.jpg'] = 'B', ['C:/d/Y.jpg'] = 'C' }
local valeurs, tailles = { A = 0, B = 2, C = 4 }, { A = 640, B = 320, C = 160 }
local empreintes = { empreinte = function(p) return hashes[p] end }
local images = { magick = function() return 'magick' end, signature = function(p)
  local cle = hashes[p]
  return { signature = string.rep(string.char(valeurs[cle]), 768), largeur = tailles[cle], hauteur = tailles[cle] }
end }
local sansCache = { charger = function() end, obtenir = function() end, retenir = function() end, enregistrer = function() end }
local D, S, Choix = require 'Doublons', require 'Similitude', require 'Choix'
local recherche = preparer(empreintes, images, taches, { currentTime = os.clock }, D, S, require 'Parallele')
local groupes = recherche(synthese, progression, diag, sansCache).groupes
assert(#groupes == 1 and #groupes[1] == 4)
local d = D.decider(groupes[1])
assert(d.garde.id == 1 and d.aVerifier and not S.memeVue(images.signature(synthese[1].chemin), images.signature(synthese[4].chemin)))
assert(#Choix.appliquer({ d }, { exclus = {}, forces = {} }).aFusionner == 0)
assert(not pcall(R.verifier, { d }, progression, empreintes, images, sansCache))
-- Un forçage explicite reste possible et relit toujours les preuves.
local forcee = Choix.appliquer({ d }, { exclus = {}, forces = { [1] = 1 } }).forcees[1]
assert(R.verifier({ forcee }, progression, empreintes, images, sansCache))
-- Si la gardée finale est B, chaque image est réellement dans son seuil.
tailles.B = 800
groupes = recherche(synthese, progression, diag, sansCache).groupes
d = D.decider(groupes[1])
assert(hashes[d.garde.chemin] == 'B' and d.aVerifier)
assert(#Choix.appliquer({ d }, { exclus = {}, forces = {} }).aFusionner == 0)
local validee = Choix.appliquer({ d }, { exclus = {}, forces = { [1] = 1 } }).forcees[1]
assert(R.verifier({ validee }, progression, empreintes, images, sansCache))
print('OK : recherche froide/chaude identique, zéro empreinte/signature recalculée à chaud, invalidation ciblée et fallback cache corrompu.')
print('OK : ressemblances en chaîne protégées, vérification de la gardée finale et forçage explicite.')
-- Copie renommée et redatée : seules les mêmes dimensions la relient, et seulement si l'option est cochée.
local parDims = {
  { id = 1, chemin = 'C:/a/PPD-001.jpg', date = 1, taille = 180, largeurCatalogue = 862, hauteurCatalogue = 695 },
  { id = 2, chemin = 'C:/b/img2021.jpg', date = 2, taille = 70, largeurCatalogue = 862, hauteurCatalogue = 695 },
  { id = 3, chemin = 'C:/c/autre.jpg', date = 3, taille = 90, largeurCatalogue = 695, hauteurCatalogue = 862 },
  { id = 4, chemin = 'C:/d/carre.jpg', date = 4, taille = 90, largeurCatalogue = 500, hauteurCatalogue = 500 },
}
local vues = { ['C:/a/PPD-001.jpg'] = 50, ['C:/b/img2021.jpg'] = 51, ['C:/c/autre.jpg'] = 200, ['C:/d/carre.jpg'] = 50 }
local reduites = 0
local imagesDims = { magick = function() return 'magick' end, signature = function(p)
  reduites = reduites + 1
  return { signature = string.rep(string.char(vues[p]), 768), largeur = 862, hauteur = 695 }
end }
local rechercheDims = preparer({ empreinte = function(p) return 'jpeg:' .. p end }, imagesDims, taches,
  { currentTime = os.clock }, D, S, require 'Parallele')
local sans = rechercheDims(parDims, progression, diag, sansCache, {})
assert(#sans.groupes == 0 and reduites == 0, 'sans l’option, aucun rapprochement ni miniature')
local avec = rechercheDims(parDims, progression, diag, sansCache, { memesDimensions = true })
assert(#avec.groupes == 1 and #avec.groupes[1] == 2 and #avec.differents == 0, 'seule la même vue est rapprochée')
assert(reduites == 3, 'une miniature par image de dimensions partagées (rotation comprise), jamais pour la carrée seule')
d = D.decider(avec.groupes[1])
assert(d.garde.id == 1 and d.aVerifier:find('noms différents', 1, true))
print('OK : rapprochement optionnel par dimensions, rotation comprise, toujours à vérifier.')

