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
    local lignes = { 'Diagnostic de lecture du catalogue - ' .. os.date('%Y-%m-%d %H:%M:%S') }
    local function enregistrer(texte)
      lignes[#lignes + 1] = texte
      local f = assert(io.open(chemin, 'wb'))
      f:write(table.concat(lignes, '\n') .. '\n'); f:close()
    end
    local progression = LrProgressScope { title = 'Diagnostic des lectures du catalogue', functionContext = contexte }
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
      if not photo then error('Sélectionne une photo avant le diagnostic.', 0) end
      local photos = {}
      for i, p in ipairs(catalogue:getTargetPhotos()) do
        if i > 100 then break end
        photos[#photos + 1] = p
      end
      mesurer('Lecture groupée de ' .. #photos .. ' photos sélectionnées (maximum 100)', function()
        local resultat = CollectionsRapides.lire(catalogue, photos, progression, {}, true)
        if not resultat then error('Diagnostic annulé.', 0) end
      end)
    end)
    if not ok then enregistrer('ERREUR : ' .. tostring(erreur)) end
    progression:done()
    LrDialogs.message('Diagnostic du catalogue', table.concat(lignes, '\n'), ok and 'info' or 'critical')
  end)
end)
