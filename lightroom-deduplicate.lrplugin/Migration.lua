-- Passage de l'identifiant fr.matthieu.deduplicate (versions jusqu'à 26.11.9) à io.github.mtthth.deduplicate.
-- Lightroom range sous l'identifiant du module ses préférences et, dans le catalogue, l'état annulable de
-- l'historique des photos écartées. L'historique lui-même est un fichier : avec le nouvel identifiant, le
-- module repart de ce fichier (Annulation l'adopte quand le catalogue ne contient encore aucun état).
-- Il reste donc à reprendre la préférence des rafales, et à refuser la reprise tant qu'une annulation
-- (Ctrl+Z) faite avec l'ancienne version n'est pas reportée dans le fichier : elle serait perdue.
-- Pur Lua, sans import, pour pouvoir être testé à part.
local M = {}
M.ANCIEN = 'fr.matthieu.deduplicate'

-- prefsForPlugin : LrPrefs.prefsForPlugin. Reprend une seule fois ; vrai si une valeur a été reprise.
function M.reprendrePreferences(prefsForPlugin)
  local prefs = prefsForPlugin()
  if prefs.identifiantRepris then return false end
  local repris = false
  local ok, anciennes = pcall(prefsForPlugin, M.ANCIEN)
  if ok and anciennes and prefs.motCollectionRafales == nil and anciennes.motCollectionRafales ~= nil then
    prefs.motCollectionRafales = anciennes.motCollectionRafales
    repris = true
  end
  prefs.identifiantRepris = M.ANCIEN
  return repris
end

-- Vérifie, avant la première synchronisation sous le nouvel identifiant, que l'ancien n'a laissé aucune
-- annulation en attente. cles : { etat, reference, operations, operationsMiroir } ; lireOperations :
-- JournalAnnulable.lire(catalogue, valeur, plugin). Si Lightroom refuse la lecture sous l'ancien
-- identifiant, rien ne peut être vérifié et la reprise se fait depuis le fichier.
function M.verifierAncien(catalogue, cles, lireOperations)
  local function lire(cle)
    local ok, valeur = pcall(catalogue.getPropertyForPlugin, catalogue, M.ANCIEN, cle)
    if not ok then error({ illisible = true }) end
    return valeur
  end
  local ok, enAttente = pcall(function()
    local etat = lire(cles.etat)
    if etat == nil then return false end
    if etat ~= lire(cles.reference) then return true end
    local operations = lireOperations(catalogue, lire(cles.operations), M.ANCIEN)
    return (operations or '') ~= (lire(cles.operationsMiroir) or '')
  end)
  if not ok then
    if type(enAttente) == 'table' and enAttente.illisible then return false end
    error(enAttente, 0)
  end
  if enAttente then
    error('Une annulation (Ctrl+Z) faite avec la version précédente de Deduplicate n’a pas encore été reportée '
      .. 'dans l’historique des photos écartées. Réinstallez la version 26.11.9 le temps qu’elle se synchronise '
      .. '(quelques secondes, Lightroom ouvert), puis revenez à cette version.', 0)
  end
  return true
end

return M
