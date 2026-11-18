-- Historique des photos écartées. Si le module Albums Google Photos est installé dans le dossier voisin
-- (lightroom-google-photos), les deux modules partagent son fichier : Google Photos ne propose alors pas
-- au téléchargement les photos déjà écartées. Sinon, Deduplicate garde son propre fichier.
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local M = {}
M.MARQUEUR = '# historique-commun-deduplicate-google-v1'
-- Renvoie le fichier utilisé, le fichier propre à Deduplicate et vrai si le premier est partagé.
function M.chemins()
  local projet = LrPathUtils.parent(_PLUGIN.path)
  local propre = LrPathUtils.child(projet, 'photos-traitees.txt')
  local voisin = LrPathUtils.child(LrPathUtils.parent(projet), 'lightroom-google-photos')
  if not LrFileUtils.exists(LrPathUtils.child(voisin, 'albums-google-photos.lrplugin')) then
    return propre, propre, false
  end
  return LrPathUtils.child(voisin, 'photos-traitees.txt'), propre, true
end
function M.fusionner(commun, ancien)
  local deja, lignes = {}, {}
  local function ajouter(contenu)
    for ligne in (contenu or ''):gmatch('[^\r\n]+') do
      local chemin = ligne:sub(1, 1) ~= '#' and ligne:match('^[^\t]+\t([^\t]+)\t[^\t]*\t')
      if chemin then
        local cle = chemin:gsub('/', '\\'):lower()
        if not deja[cle] then lignes[#lignes + 1] = ligne; deja[cle] = true end
      elseif ligne:sub(1, 1) == '#' then
        if ligne ~= M.MARQUEUR and not ligne:match('^# type\t') then lignes[#lignes + 1] = ligne end
      else
        error('Ligne invalide dans un historique : fusion interrompue', 0)
      end
    end
  end
  ajouter(commun); ajouter(ancien)
  return '# type\tchemin\tfichier\tdate_prise_de_vue\r\n' .. M.MARQUEUR .. '\r\n'
    .. (#lignes > 0 and (table.concat(lignes, '\r\n') .. '\r\n') or '')
end
return M
