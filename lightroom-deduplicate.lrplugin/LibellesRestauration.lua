local M = {}

-- Date dans un nom de dossier, sans la confondre avec la date de sauvegarde.
function M.dateDossier(chemin)
  local dossier = chemin:match('^(.*)[/\\][^/\\]*$') or ''
  local date
  for partie in dossier:gmatch('[^/\\]+') do
    date = partie:match('(%d%d%d%d%-%d%d%-%d%d)') or date
  end
  return date
end

-- Coupe sans séparer les octets d'un caractère UTF-8. Le chemin reste complet.
function M.lignes(texte, largeur)
  local lignes, ligne, n = {}, {}, 0
  for caractere in texte:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
    if n == largeur then lignes[#lignes + 1] = table.concat(ligne); ligne, n = {}, 0 end
    ligne[#ligne + 1] = caractere; n = n + 1
  end
  if #ligne > 0 then lignes[#lignes + 1] = table.concat(ligne) end
  return lignes
end
return M
