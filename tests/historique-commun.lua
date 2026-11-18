package.path = 'lightroom-deduplicate.lrplugin/?.lua;' .. package.path
_PLUGIN = { path = '/projets/lightroom-deduplicate/lightroom-deduplicate.lrplugin' }
local fichiers = {}
local paths = { parent = function(p) return p:match('^(.*)/[^/]+$') end,
  child = function(p, n) return p .. '/' .. n end }
local google = '/projets/lightroom-google-photos/photos-traitees.txt'
local ancien = '/projets/lightroom-deduplicate/photos-traitees.txt'
local dossierGoogle = '/projets/lightroom-google-photos/albums-google-photos.lrplugin'
fichiers[dossierGoogle] = true
fichiers[google] = '# Google\r\ndoublon\tC:\\g.jpg\tg.jpg\t2026\r\n'
fichiers[ancien] = '# Dedup\r\nrafale\tC:\\d.jpg\td.jpg\t2025\r\n'
local utils = { exists = function(p) return fichiers[p] ~= nil end, readFile = function(p) return fichiers[p] end }
local tasks = { pcall = pcall }
function import(n) return ({ LrPathUtils = paths, LrFileUtils = utils, LrTasks = tasks, LrApplication = {}, LrDialogs = {} })[n] end
local historique = require 'Historique'
historique.ecrire = function(p, s) fichiers[p] = s end
historique.preparer = function() end
local C = require 'HistoriqueCommun'
local props = {}
local temoin={localIdentifier=1}
function temoin:getRawMetadata() return 'C:\\temoin.jpg' end
function temoin:getPropertyForPlugin() return self.token end
function temoin:setPropertyForPlugin(_,_,v) self.token=v end
local cat = { getPropertyForPlugin = function(_, _, k) return props[k] end,
  setPropertyForPlugin = function(_, _, k, v) props[k] = v end,
  withPrivateWriteAccessDo = function(_, f) f(); return 'executed' end,
  withWriteAccessDo = function(_, _, f) f(); return 'executed' end,
  findPhotoByPath = function() return temoin end }
local A = require 'Annulation'
assert(C.chemins() == google)
assert(A.synchroniser(cat, google):find(C.MARQUEUR, 1, true))
assert(fichiers[google]:find('g.jpg', 1, true) and fichiers[google]:find('d.jpg', 1, true))
assert(fichiers[ancien]:find('d.jpg', 1, true))
local function snapshot()
  return { etat = props.historiquePhotosV1, token = temoin.token }
end
local function restaurer(s)
  -- Les propriétés globales persistent lors d'Undo ; seul le champ de photo
  -- est annulable. Le précédent faux SDK annulait à tort le journal global.
  props.historiquePhotosV1, temoin.token = s.etat, s.token
  return A.synchroniser(cat, google)
end
local avant = snapshot()
A.action(cat, google, 'restauration', { retablir = { 'C:\\d.jpg' }, temoin=temoin }, function() end)
assert(not fichiers[google]:find('d.jpg', 1, true) and fichiers[google]:find('g.jpg', 1, true))
local apres = snapshot()
restaurer(avant)
assert(fichiers[google]:find('d.jpg', 1, true))
restaurer(apres)
assert(not fichiers[google]:find('d.jpg', 1, true))

-- Un ajout Google Photos entre la fusion et Ctrl+Z doit survivre, avant ou après
-- le passage périodique du miroir. Une suppression externe doit aussi survivre.
local externe = 'rafale\tC:\\externe.jpg\texterne.jpg\t2026\r\n'
fichiers[google] = fichiers[google] .. '# édition externe\r\n' .. externe
restaurer(avant)
assert(fichiers[google]:find(externe, 1, true) and fichiers[google]:find('# édition externe', 1, true))
restaurer(apres)
fichiers[google] = historique.modifier(fichiers[google], { retablir = { 'C:\\g.jpg' } })
A.synchroniser(cat, google)
restaurer(avant)
assert(fichiers[google]:find(externe, 1, true) and not fichiers[google]:find('g.jpg', 1, true))

-- Deux actions, plusieurs Undo/Redo (y compris regroupés avant une synchro),
-- et un rechargement du module ne doivent jamais importer les ajouts externes
-- dans l'état annulable d'une ancienne action.
local function ajouter(path)
  A.action(cat, google, 'fusion', { photos = { { chemin = path } }, temoin=temoin }, function() end)
end
ajouter('C:\\a.jpg'); local un = snapshot()
fichiers[google] = fichiers[google] .. 'doublon\tC:\\autre.jpg\tautre.jpg\t2026\r\n'
A.synchroniser(cat, google)
ajouter('C:\\b.jpg'); local deux = snapshot()
package.loaded.Annulation = nil; A = require 'Annulation'
restaurer(avant)
assert(not fichiers[google]:find('a.jpg', 1, true) and not fichiers[google]:find('b.jpg', 1, true))
assert(fichiers[google]:find('autre.jpg', 1, true) and fichiers[google]:find(externe, 1, true))
restaurer(deux)
assert(fichiers[google]:find('a.jpg', 1, true) and fichiers[google]:find('b.jpg', 1, true))
restaurer(un)
assert(fichiers[google]:find('a.jpg', 1, true) and not fichiers[google]:find('b.jpg', 1, true))
-- Nouvelle branche après Undo, puis restauration d'un chemin ajouté à l'extérieur.
ajouter('C:\\c.jpg'); local branche = snapshot()
restaurer(deux)
assert(not fichiers[google]:find('c.jpg', 1, true) and fichiers[google]:find('b.jpg', 1, true))
restaurer(branche)
A.action(cat, google, 'restauration externe', { retablir = { 'C:\\externe.jpg' }, temoin=temoin }, function() end)
assert(not fichiers[google]:find('externe.jpg', 1, true))
restaurer(branche)
assert(fichiers[google]:find(externe, 1, true))

-- Compatibilité : les anciens snapshots V1 sont fusionnés par delta, sans
-- écraser un ajout externe, même si aucune référence V2 n'existait au départ.
local marque = '# type\tchemin\tfichier\tdate_prise_de_vue\r\n' .. C.MARQUEUR .. '\r\n'
props = { historiquePhotosV1 = marque, historiquePhotosMiroirV1 = marque .. externe }
temoin.token=nil
fichiers[google] = marque .. externe .. 'doublon\tC:\\tiers.jpg\ttiers.jpg\t2026\r\n'
A.synchroniser(cat, google)
assert(not fichiers[google]:find('externe.jpg', 1, true) and fichiers[google]:find('tiers.jpg', 1, true))

-- Une écriture ratée conserve les marqueurs : la même transition sera réessayée.
local initial = snapshot()
local ecrire = historique.ecrire
historique.ecrire = function() error('disque indisponible') end
local ok = A.action(cat, google, 'fusion', { photos = { { chemin = 'C:\\reessai.jpg' } }, temoin=temoin }, function() end)
assert(not ok and not fichiers[google]:find('reessai.jpg', 1, true))
historique.ecrire = ecrire
A.synchroniser(cat, google)
assert(fichiers[google]:find('reessai.jpg', 1, true))
restaurer(initial)
assert(not fichiers[google]:find('reessai.jpg', 1, true))

props.historiquePhotosV1 = 'ancien état sans marqueur'
assert(not pcall(A.synchroniser, cat, google))
assert(fichiers[google]:find('tiers.jpg', 1, true))
props.historiquePhotosV1 = nil
assert(not pcall(A.synchroniser, cat, google))
assert(fichiers[google]:find('tiers.jpg', 1, true))
assert(not pcall(C.fusionner, 'ligne invalide', ''))

-- Un autre catalogue a déjà migré le fichier partagé : adopter ce point de
-- départ sans confondre cet ancien état propre avec une annulation historique.
props = { historiquePhotosV1 = '# ancien état\r\n', historiquePhotosMiroirV1 = '# ancien état\r\n' }
temoin.token=nil
fichiers[google] = marque .. externe
A.synchroniser(cat, google)
assert(props.historiquePhotosV1 == fichiers[google])
local propre = snapshot()
ajouter('C:\\nouveau.jpg')
restaurer(propre)
assert(not fichiers[google]:find('nouveau.jpg', 1, true) and fichiers[google]:find(externe, 1, true))

-- Les modifications arrivées pendant l'attente du verrou sont relues.
local prive = cat.withPrivateWriteAccessDo
cat.withPrivateWriteAccessDo = function(self, f)
  cat.withPrivateWriteAccessDo = prive
  fichiers[google] = fichiers[google] .. 'doublon\tC:\\pendant.jpg\tpendant.jpg\t2026\r\n'
  return prive(self, f)
end
ajouter('C:\\operation.jpg')
restaurer(propre)
assert(not fichiers[google]:find('operation.jpg', 1, true) and fichiers[google]:find('pendant.jpg', 1, true))

-- Même chemin modifié plusieurs fois : ne pas annuler une édition externe
-- quand le delta net est nul, ni remplacer une ligne réécrite à l'extérieur.
local ligne = 'doublon\tC:\\unique.jpg\tunique.jpg\t2026\r\n'
local j1 = historique.journaliser('', marque, marque .. ligne)
local j2 = historique.journaliser(j1, marque .. ligne, marque)
assert(historique.rejouer(j2, '', marque .. externe) == marque .. externe)
local editee = ligne:gsub('2026', '2027')
assert(historique.rejouer(j1, '', marque .. editee) == marque .. editee)
assert(not pcall(historique.rejouer, 'journal tronqué', '', marque))

-- Sans le module Google Photos voisin : Deduplicate garde son propre fichier, sans marqueur partagé.
fichiers = { [ancien] = '# Dedup\r\nrafale\tC:\\seul.jpg\tseul.jpg\t2025\r\n' }
for k in pairs(props) do props[k] = nil end
temoin.token = nil
local actif, propre, partage = C.chemins()
assert(actif == ancien and propre == ancien and partage == false, 'module voisin absent : fichier propre')
local seul = A.synchroniser(cat, ancien)
assert(seul:find('seul.jpg', 1, true) and not seul:find(C.MARQUEUR, 1, true))
A.action(cat, ancien, 'fusion seule', { photos = { { chemin = 'C:\\seule2.jpg' } }, temoin = temoin }, function() end)
assert(fichiers[ancien]:find('seule2.jpg', 1, true) and fichiers[ancien]:find('seul.jpg', 1, true))
assert(fichiers[google] == nil, 'aucun fichier créé chez le voisin absent')
print('OK : migration, deltas Undo/Redo, éditions externes, branches, rechargement, anciens états, reprise après erreur et module seul.')
