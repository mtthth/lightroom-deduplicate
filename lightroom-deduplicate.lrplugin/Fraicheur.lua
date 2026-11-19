-- Fraîcheur des modules en mémoire. Lightroom garde les modules chargés par require() jusqu'au rechargement du
-- module externe : après une mise à jour des fichiers, une commande relue du disque appellerait d'anciens
-- modules (par exemple une fonction ajoutée depuis, absente de l'ancien Doublons.lua).
--
-- Ce fichier sert deux fois :
-- - require('Fraicheur'), au démarrage du module (Initialiser.lua), retient la signature des fichiers .lua
--   telle qu'elle était quand les modules ont été chargés ;
-- - dofile(...'Fraicheur.lua'), au début de chaque commande, recalcule la signature et la compare.
-- Une différence veut dire que des fichiers ont changé depuis le chargement : la commande s'arrête et demande de
-- recharger le module plutôt que d'échouer au milieu d'une recherche ou d'une fusion.
local LrFileUtils = import 'LrFileUtils'

local M = {}

-- Noms, tailles et dates de modification des fichiers .lua du module, triés.
function M.signature()
  local lignes = {}
  for chemin in LrFileUtils.files(_PLUGIN.path) do
    if chemin:lower():match('%.lua$') then
      local attributs = LrFileUtils.fileAttributes(chemin) or {}
      lignes[#lignes + 1] = (chemin:match('[^/\\]+$') or chemin) .. '|' .. tostring(attributs.fileSize)
        .. '|' .. tostring(attributs.fileModificationDate)
    end
  end
  table.sort(lignes)
  return table.concat(lignes, '\n')
end

M.SIGNATURE = M.signature()

-- Vrai si les modules en mémoire correspondent aux fichiers ; sinon affiche un message et rend faux.
-- À appeler depuis l'instance relue par dofile.
function M.verifier()
  local enMemoire = require 'Fraicheur'
  if enMemoire.SIGNATURE == M.SIGNATURE then return true end
  local T = require('Langue').t
  local LrDialogs = import 'LrDialogs'
  import('LrTasks').startAsyncTask(function()
    LrDialogs.message(
      T('Module à recharger', 'Plug-in needs reloading'),
      T('Les fichiers du module Deduplicate ont changé depuis son chargement (mise à jour ?). '
        .. 'Lightroom utilise encore une partie des anciens.\n\n'
        .. 'Ouvrez Fichier > Gestionnaire de modules externes, sélectionnez Deduplicate et cliquez sur '
        .. '« Recharger le module externe », ou redémarrez Lightroom, puis relancez la commande.',
        'The Deduplicate plug-in files have changed since it was loaded (update?). '
        .. 'Lightroom is still using some of the old ones.\n\n'
        .. 'Open File > Plug-in Manager, select Deduplicate and click "Reload Plug-in", '
        .. 'or restart Lightroom, then run the command again.'),
      'warning')
  end)
  return false
end

return M
