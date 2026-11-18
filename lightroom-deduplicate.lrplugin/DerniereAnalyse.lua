-- Dernière analyse des doublons, gardée en mémoire tant que Lightroom (et le module) restent ouverts : un
-- code refusé, ou une boîte fermée sans fusionner, n'oblige pas à tout recomparer. Chargé par require, ce
-- module est partagé par les appels successifs de la commande ; un rechargement du module l'efface.
--
-- La reprise ne fait jamais confiance à cette mémoire seule : FusionnerDoublons relit les métadonnées et
-- collections, refait les décisions et refuse la reprise si l'identifiant de l'analyse a changé.

local M = {}

local derniere

-- a : { catalogue (chemin), date, portee (texte), identifiant, groupes, differents, message, choisissable }
function M.memoriser(a) derniere = a end

function M.oublier() derniere = nil end

-- La dernière analyse si elle porte sur ce catalogue, sinon nil.
function M.pour(cheminCatalogue)
  if derniere and derniere.catalogue == cheminCatalogue then return derniere end
  return nil
end

return M
