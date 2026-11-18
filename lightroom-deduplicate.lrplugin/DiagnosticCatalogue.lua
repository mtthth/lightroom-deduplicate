-- Diagnostic de lecture uniquement : aucune photo/collection n'est modifiée.
local LrApplication = import 'LrApplication'
local LrDate = import 'LrDate'
local LrDialogs = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrPathUtils = import 'LrPathUtils'
local LrProgressScope = import 'LrProgressScope'
local LrTasks = import 'LrTasks'
local CollectionsRapides = dofile(LrPathUtils.child(_PLUGIN.path, 'CollectionsRapides.lua'))

LrTasks.startAsyncTask(function()
  LrFunctionContext.callWithContext('diagnosticCatalogue', function(contexte)
    local chemin = LrPathUtils.child(LrPathUtils.parent(_PLUGIN.path), 'diagnostic-catalogue.txt')
    local T = require('Langue').t
    local lignes = { T('Diagnostic de lecture du catalogue - ', 'Catalog reading diagnostic - ') .. os.date('%Y-%m-%d %H:%M:%S') }
    local function enregistrer(texte)
      lignes[#lignes + 1] = texte
      local f = assert(io.open(chemin, 'wb'))
      f:write(table.concat(lignes, '\n') .. '\n'); f:close()
    end
    local progression = LrProgressScope { title = T('Diagnostic des lectures du catalogue', 'Catalog reading diagnostic'), functionContext = contexte }
    local function mesurer(nom, lire)
      progression:setCaption(nom)
      local debut = LrDate.currentTime()
      local resultat = lire()
      enregistrer(string.format('%s : %.3f s', nom, LrDate.currentTime() - debut))
      return resultat
    end
    local ok, erreur = LrTasks.pcall(function()
      local catalogue = LrApplication.activeCatalog()
      local photo = catalogue:getTargetPhoto()
      if not photo then error(T('Sélectionnez une photo avant le diagnostic.', 'Select a photo before the diagnostic.'), 0) end
      local photos = {}
      for i, p in ipairs(catalogue:getTargetPhotos()) do
        if i > 100 then break end
        photos[#photos + 1] = p
      end
      mesurer(T('Lecture groupée de ' .. #photos .. ' photos sélectionnées (maximum 100)', 'Batch read of ' .. #photos .. ' selected photos (100 at most)'), function()
        local resultat = CollectionsRapides.lire(catalogue, photos, progression, {}, true)
        if not resultat then error(T('Diagnostic annulé.', 'Diagnostic cancelled.'), 0) end
      end)
    end)
    if not ok then enregistrer(T('ERREUR : ', 'ERROR: ') .. tostring(erreur)) end
    progression:done()
    LrDialogs.message(T('Diagnostic du catalogue', 'Catalog diagnostic'), table.concat(lignes, '\n'), ok and 'info' or 'critical')
  end)
end)
