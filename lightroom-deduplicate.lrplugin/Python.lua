-- Python 3.12 ou plus récent (Windows), nécessaire pour lire le catalogue en lecture seule et pour le
-- cache des analyses. Emplacements cherchés, du plus récent au plus ancien : installation python.org
-- pour l'utilisateur (par défaut), pour tous les utilisateurs, puis C:\Python3xx.
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local LrTasks = import 'LrTasks'
local M = {}
M.VERSIONS = { 316, 315, 314, 313, 312 }

-- dossiers : { utilisateur = …\AppData\Local\Programs\Python, programmes = C:\Program Files } (pour les tests).
function M.candidats(dossiers)
  local liste = {}
  for _, v in ipairs(M.VERSIONS) do
    local nom = 'Python' .. v
    if dossiers.utilisateur then liste[#liste + 1] = LrPathUtils.child(LrPathUtils.child(dossiers.utilisateur, nom), 'python.exe') end
    if dossiers.programmes then liste[#liste + 1] = LrPathUtils.child(LrPathUtils.child(dossiers.programmes, nom), 'python.exe') end
    liste[#liste + 1] = 'C:\\' .. nom .. '\\python.exe'
  end
  return liste
end

local trouve
-- Chemin de python.exe, ou nil.
function M.chemin()
  if trouve then return trouve end
  local dossiers = { programmes = 'C:\\Program Files' }
  local ok, home = LrTasks.pcall(LrPathUtils.getStandardFilePath, 'home')
  if ok and home then dossiers.utilisateur = LrPathUtils.child(home, 'AppData\\Local\\Programs\\Python') end
  for _, p in ipairs(M.candidats(dossiers)) do
    if LrFileUtils.exists(p) == 'file' then trouve = p; return p end
  end
  return nil
end

M.MESSAGE = 'Python 3.12 ou plus récent est nécessaire (python.org, installation par défaut).'

return M
