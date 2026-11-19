-- Fraîcheur des modules : la signature retenue au chargement (require) est comparée à celle relue au début d'une
-- commande (dofile). Fichiers inchangés : la commande continue ; fichier modifié ou ajouté : message et arrêt.
package.path = 'lightroom-deduplicate.lrplugin/?.lua;' .. package.path
_PLUGIN = { path = 'plugin' }
local fichiers = { ['plugin/Doublons.lua'] = { fileSize = 100, fileModificationDate = 1 },
  ['plugin/Info.lua'] = { fileSize = 10, fileModificationDate = 1 }, ['plugin/notes.txt'] = { fileSize = 5 } }
local messages = {}
local modules = {
  LrFileUtils = {
    files = function(dossier)
      assert(dossier == 'plugin')
      local liste = {}
      for chemin in pairs(fichiers) do liste[#liste + 1] = chemin end
      local i = 0
      return function() i = i + 1; return liste[i] end
    end,
    fileAttributes = function(chemin) return fichiers[chemin] end,
  },
  LrDialogs = { message = function(titre, texte) messages[#messages + 1] = titre .. '\n' .. texte end },
  LrTasks = { startAsyncTask = function(f) f() end },
}
function import(nom) return assert(modules[nom], nom) end

local function relire() return dofile('lightroom-deduplicate.lrplugin/Fraicheur.lua') end

require 'Fraicheur'                                   -- chargement du module externe
assert(relire().verifier() and #messages == 0, 'fichiers inchangés : la commande continue')

fichiers['plugin/notes.txt'].fileModificationDate = 2
assert(relire().verifier(), 'seuls les fichiers .lua comptent')

fichiers['plugin/Doublons.lua'].fileModificationDate = 2
assert(not relire().verifier() and #messages == 1, 'fichier modifié : message et arrêt')
assert(messages[1]:find('Recharger le module externe', 1, true))

fichiers['plugin/Doublons.lua'].fileModificationDate = 1
fichiers['plugin/Fraicheur.lua'] = { fileSize = 50, fileModificationDate = 3 }
assert(not relire().verifier() and #messages == 2, 'fichier ajouté : message et arrêt')

print('OK : fichiers inchangés acceptés, fichier .lua modifié ou ajouté signalé avant la commande.')
