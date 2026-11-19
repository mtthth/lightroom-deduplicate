local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrPathUtils = import 'LrPathUtils'
local LrFileUtils = import 'LrFileUtils'
local LrTasks = import 'LrTasks'
local LrBinding = import 'LrBinding'
local LrFunctionContext = import 'LrFunctionContext'
local LrView = import 'LrView'
-- Modules en mémoire périmés après une mise à jour : demander de recharger le module (Fraicheur.lua).
if not dofile(LrPathUtils.child(_PLUGIN.path, 'Fraicheur.lua')).verifier() then return end
local Sauvegarde = dofile(LrPathUtils.child(_PLUGIN.path, 'SauvegardeCollections.lua'))
local Annulation = require 'Annulation'
local Rafales = require 'Rafales'
local Libelles = require 'LibellesRestauration'
local T = require('Langue').t
local corbeilles = { ['Doublons à retirer'] = true, ['Rafales à retirer'] = true }
local function normaliser(s) return s:gsub('/', '\\'):lower() end
local function choisirGroupes(sauvegarde, photos)
  if sauvegarde.ancienne then
    local reponse = LrDialogs.confirm(T('Ancienne sauvegarde', 'Old backup'),
      T('Cette sauvegarde ne contient pas les limites des groupes. Elle peut uniquement être restaurée en entier.',
        'This backup does not contain group boundaries. It can only be restored as a whole.'),
      'Continuer', 'Annuler')
    return reponse == 'ok' and Sauvegarde.selectionner(sauvegarde, { 1 }) or nil
  end
  local resultat
  LrFunctionContext.callWithContext('choisirGroupesRestauration', function(contexte)
    local props = LrBinding.makePropertyTable(contexte)
    for i = 1, #sauvegarde.groupes do props['groupe' .. i] = false end
    local f, page, taillePage = LrView.osFactory(), 1, 3
    local grandeVue = false
    local totalPages = math.ceil(#sauvegarde.groupes / taillePage)
    while true do
      local debut = (page - 1) * taillePage + 1
      local fin = math.min(page * taillePage, #sauvegarde.groupes)
      local colonne = { bind_to_object = props, spacing = f:control_spacing(), fill = 1 }
      colonne[#colonne + 1] = f:static_text { title = T('Sauvegarde : ', 'Backup: ') .. (sauvegarde.date or T('date inconnue', 'unknown date')), width = 400 }
      colonne[#colonne + 1] = f:static_text { title = string.format(T('Cochez les groupes à restaurer. Page %d / %d.', 'Tick the groups to restore. Page %d / %d.'), page, totalPages), width = 400 }
      local function cocherTous(valeur)
        for i = 1, #sauvegarde.groupes do props['groupe' .. i] = valeur end
      end
      colonne[#colonne + 1] = f:row {
        f:static_text { title = T('Cocher sur toutes les pages :', 'Tick on all pages:') },
        f:push_button { title = 'Tous', action = function() cocherTous(true) end },
        f:push_button { title = 'Aucun', action = function() cocherTous(false) end },
      }
      colonne[#colonne + 1] = f:push_button {
        title = grandeVue and T('Réduire la zone des photos', 'Shrink the photo area') or T('Agrandir la zone des photos', 'Enlarge the photo area'),
        action = function(bouton) LrDialogs.stopModalWithResult(bouton, 'taille') end,
      }
      local groupesVisibles = { spacing = f:control_spacing() }
      for i = debut, fin do
        local groupe = sauvegarde.groupes[i]
        local premiere, derniere = groupe.photos[1], groupe.photos[#groupe.photos]
        local date = Libelles.dateDossier(premiere.chemin)
        local libelle = string.format(T('Groupe %d — %d photo(s)', 'Group %d — %d photo(s)'), i, #groupe.photos)
        groupesVisibles[#groupesVisibles + 1] = f:checkbox { title = libelle, value = LrView.bind('groupe' .. i), width = 400 }
        groupesVisibles[#groupesVisibles + 1] = f:static_text { title = date and (T('Date du dossier : ', 'Folder date: ') .. date) or T('Date du dossier inconnue', 'Folder date unknown'), width = 400 }
        local rangee = { spacing = f:control_spacing() }
        for _, p in ipairs(groupe.photos) do
          if photos[p.id] then
            rangee[#rangee + 1] = f:catalog_photo { photo = photos[p.id], width = 105, height = 85 }
          else
            rangee[#rangee + 1] = f:static_text { title = T('Photo absente', 'Missing photo'), width = 105, height_in_lines = 2 }
          end
          if #rangee == (grandeVue and 12 or 6) then groupesVisibles[#groupesVisibles + 1] = f:row(rangee); rangee = { spacing = f:control_spacing() } end
        end
        if #rangee > 0 then groupesVisibles[#groupesVisibles + 1] = f:row(rangee) end
        local chemins = { premiere.chemin }
        if #groupe.photos > 1 and derniere.chemin ~= premiere.chemin then chemins[#chemins + 1] = derniere.chemin end
        for n, chemin in ipairs(chemins) do
          local lignes = Libelles.lignes((n == 1 and T('Photo : ', 'Photo: ') or T('Autre photo : ', 'Other photo: ')) .. chemin, grandeVue and 80 or 55)
          for _, ligne in ipairs(lignes) do
            groupesVisibles[#groupesVisibles + 1] = f:static_text { title = ligne, width = grandeVue and 1000 or 650 }
          end
        end
        groupesVisibles[#groupesVisibles + 1] = f:separator { fill_horizontal = 1 }
      end
      colonne[#colonne + 1] = f:static_text { title = T('Faites défiler pour voir toutes les photos des groupes.', 'Scroll to see all the photos of the groups.'), width = 400 }
      -- Sur Windows le SDK ne redimensionne pas scrolled_view avec la fenêtre : prévoir une grande vue dès l'ouverture.
      colonne[#colonne + 1] = f:scrolled_view { width = grandeVue and 1400 or 700, height = grandeVue and 800 or 500, horizontal_scroller = true,
        f:column(groupesVisibles) }
      local reponse = LrDialogs.presentModalDialog {
        title = T('Choisir les groupes à restaurer', 'Choose the groups to restore'), contents = f:column(colonne),
        resizable = true, save_frame = 'restaurationGroupesFenetre',
        actionVerb = page < totalPages and T('Page suivante', 'Next page') or T('Continuer', 'Continue'),
        otherVerb = page > 1 and T('Page précédente', 'Previous page') or nil,
        cancelVerb = 'Annuler',
      }
      if reponse == 'taille' then grandeVue = not grandeVue
      elseif reponse == 'other' and page > 1 then page = page - 1
      elseif reponse ~= 'ok' then return
      elseif page < totalPages then page = page + 1
      else
        local numeros = {}
        for i = 1, #sauvegarde.groupes do if props['groupe' .. i] then numeros[#numeros + 1] = i end end
        if #numeros == 0 then
          LrDialogs.message(T('Aucun groupe sélectionné', 'No group selected'), T('Cochez au moins un groupe à restaurer.', 'Tick at least one group to restore.'), 'info')
        else
          resultat = Sauvegarde.selectionner(sauvegarde, numeros)
          return
        end
      end
    end
  end)
  return resultat
end
LrTasks.startAsyncTask(function()
  local ok, erreur = LrTasks.pcall(function()
    local choix = LrDialogs.runOpenPanel { title = T('Choisir la sauvegarde des collections avant fusion ou rafales', 'Choose the collection backup made before merging or bursts'),
      canChooseFiles = true, canChooseDirectories = false, allowsMultipleSelection = false, fileTypes = { 'txt' } }
    if not choix or not choix[1] then return end
    local sauvegarde = Sauvegarde.lire(assert(LrFileUtils.readFile(choix[1])))
    local catalogue = LrApplication.activeCatalog()
    assert(normaliser(catalogue:getPath()) == normaliser(sauvegarde.catalogue), T('Cette sauvegarde provient d’un autre catalogue.', 'This backup comes from another catalog.'))
    local attendus, photos = {}, {}
    for _, p in ipairs(sauvegarde.ordre) do attendus[p.id] = p end
    for _, photo in ipairs(catalogue:getAllPhotos()) do
      if attendus[photo.localIdentifier] then photos[photo.localIdentifier] = photo end
    end
    for _, p in ipairs(sauvegarde.ordre) do
      if not photos[p.id] and not p.virtuelle then photos[p.id] = catalogue:findPhotoByPath(p.chemin) end
    end
    -- Ne pas afficher une miniature d'une photo différente si un identifiant a été réutilisé.
    local candidates = {}
    for _, p in ipairs(sauvegarde.ordre) do if photos[p.id] then candidates[#candidates + 1] = photos[p.id] end end
    if #candidates > 0 then
      local meta = catalogue:batchGetRawMetadata(candidates, { 'path', 'isVirtualCopy' })
      for _, p in ipairs(sauvegarde.ordre) do
        local b = photos[p.id] and meta[photos[p.id]]
        if photos[p.id] and (not b or not b.path or normaliser(b.path) ~= normaliser(p.chemin) or (b.isVirtualCopy or false) ~= p.virtuelle) then photos[p.id] = nil end
      end
    end
    sauvegarde = choisirGroupes(sauvegarde, photos)
    if not sauvegarde then return end
    local liste, manquantes = {}, {}
    for _, p in ipairs(sauvegarde.ordre) do
      if not photos[p.id] and not p.virtuelle then photos[p.id] = catalogue:findPhotoByPath(p.chemin) end
      if photos[p.id] then liste[#liste + 1] = photos[p.id] else manquantes[#manquantes + 1] = p.chemin end
    end
    assert(#manquantes == 0, T('Photos absentes du catalogue (les réimporter avant de restaurer) :\n', 'Photos missing from the catalog (re-import them before restoring):\n') .. table.concat(manquantes, '\n'))
    local meta = catalogue:batchGetRawMetadata(liste, { 'path', 'isVirtualCopy' })
    for _, p in ipairs(sauvegarde.ordre) do
      local b = assert(meta[photos[p.id]])
      assert(normaliser(b.path) == normaliser(p.chemin) and (b.isVirtualCopy or false) == p.virtuelle,
        T('La photo ne correspond plus à la sauvegarde : ', 'The photo no longer matches the backup: ') .. p.chemin)
    end
    local message = string.format(T('Restaurer %d groupe(s) : réajouter les collections d’origine de %d photos, recréer les collections et ensembles disparus, '
      .. 'et sortir les photos restaurées des collections « à retirer » si elles n’y étaient pas auparavant. '
      .. 'Les autres appartenances actuelles, les métadonnées et les retouches sont conservées. Ctrl+Z annulera cette restauration.\n\n%s',
      'Restore %d group(s): add back the original collections of %d photos, recreate the missing collections and sets, and '
      .. 'take the restored photos out of the “to remove” collections if they were not there before. The other current '
      .. 'memberships, metadata and edits are kept. Ctrl+Z will undo this restoration.\n\n%s'),
      #sauvegarde.groupes, #sauvegarde.ordre, choix[1])
    if sauvegarde.genre == 'rafales' then
      message = message .. T('\n\nLe mot-clé « Rafale traitée » sera retiré des photos sélectionnées pour permettre leur réanalyse.', '\n\nThe “Rafale traitée” keyword will be removed from the selected photos so that they can be analysed again.')
    end
    if LrDialogs.confirm(T('Restaurer les collections d’origine ?', 'Restore the original collections?'), message, T('Restaurer', 'Restore'), T('Annuler', 'Cancel')) ~= 'ok' then return end
    local chemins = {}
    for _, p in ipairs(sauvegarde.ordre) do
      local retrait = false
      for _, id in ipairs(p.collections) do if corbeilles[sauvegarde.noeuds[id].nom] then retrait = true end end
      if not retrait and not p.virtuelle then chemins[#chemins + 1] = p.chemin end
    end
    local historique = require('HistoriqueCommun').chemins()
    local histOk, err = Annulation.action(catalogue, historique, T('Restaurer les collections avant fusion ou rafales', 'Restore collections from before merging or bursts'),
      { retablir = chemins, photos = {}, type = 'restauration', temoin = liste[1] }, function()
        Sauvegarde.restaurer(catalogue, sauvegarde, photos, corbeilles)
        Sauvegarde.retirerMotCleRafales(sauvegarde, photos, Rafales.MOT_CLE)
      end)
    LrDialogs.message(T('Collections restaurées', 'Collections restored'), #sauvegarde.ordre .. T(' photos restaurées dans leurs collections d’origine.\n', ' photos restored to their original collections.\n')
      .. (histOk and T('Historique des exclusions synchronisé.', 'History of exclusions synchronised.') or T('Historique texte à synchroniser : ', 'Text history to synchronise: ') .. tostring(err)), histOk and 'info' or 'warning')
  end)
  if not ok then LrDialogs.message(T('Restauration interrompue', 'Restoration interrupted'), tostring(erreur), 'critical') end
end)
