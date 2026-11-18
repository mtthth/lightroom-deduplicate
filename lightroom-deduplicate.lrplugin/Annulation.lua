-- Les témoins de photos rendent les deltas d'exclusions annulables dans la même
-- action que les collections, mots-clés et métadonnées. Les propriétés globales
-- du catalogue ne suivent pas Undo. Le miroir conserve les éditions externes.
-- Aucun changement privé n'ajoute d'étape Ctrl+Z.
local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'
local Historique = require 'Historique'
local HistoriqueCommun = require 'HistoriqueCommun'
local LrFileUtils = import 'LrFileUtils'
local Journal = require 'JournalAnnulable'
local Migration = require 'Migration'
local T = require('Langue').t

local M = {}
local ETAT = 'historiquePhotosV1'
local MIROIR = 'historiquePhotosMiroirV1'
local REFERENCE = 'historiquePhotosReferenceV2'
local OPERATIONS = 'historiquePhotosOperationsV2'
local OPERATIONS_MIROIR = 'historiquePhotosOperationsMiroirV2'
local verrou, generation = false, 0

-- Diagnostic des gels : diagnostic-historique-etat.txt est réécrit à chaque phase (la dernière ligne dit où
-- en était la synchronisation au moment d'un gel) ; diagnostic-historique-fond.txt garde les accès en
-- écriture, les attentes de verrou et les passages lents.
local LrPathUtils = import 'LrPathUtils'
local LrDate = import 'LrDate'
local maintenant = LrDate and LrDate.currentTime or os.time
local DOSSIER_DIAGNOSTIC = LrPathUtils.parent(_PLUGIN.path)
local FICHIER_ETAT = LrPathUtils.child(DOSSIER_DIAGNOSTIC, 'diagnostic-historique-etat.txt')
local FICHIER_JOURNAL = LrPathUtils.child(DOSSIER_DIAGNOSTIC, 'diagnostic-historique-fond.txt')
local function ecrireDiagnostic(chemin, mode, ligne)
  local f = io.open(chemin, mode)
  if not f then return end
  f:write(os.date('%Y-%m-%d %H:%M:%S') .. '\t' .. ligne .. '\n')
  f:close()
end
local function phase(texte) ecrireDiagnostic(FICHIER_ETAT, 'wb', texte) end
local function noter(texte) ecrireDiagnostic(FICHIER_JOURNAL, 'ab', texte) end
local function duree(debut) return string.format('%.3f s', maintenant() - debut) end
local function lire(catalogue,cle)
  local valeur=catalogue:getPropertyForPlugin(_PLUGIN,cle)
  if cle==OPERATIONS then return (Journal.lire(catalogue,valeur)) end
  return valeur
end

local function avecVerrou(f, qui)
  local debut = maintenant()
  if verrou then phase('attente du verrou : ' .. qui .. ' (tenu par ' .. tostring(verrou) .. ')') end
  while verrou do LrTasks.sleep(0.05) end
  if maintenant() - debut > 1 then noter('VERROU\t' .. qui .. '\tattente ' .. duree(debut)) end
  verrou = qui
  local ok, a, b = LrTasks.pcall(f)
  verrou = false
  if not ok then error(a, 0) end
  return a, b
end

local function prive(catalogue, attendu, chemin)
  local actualise = false
  local debut = maintenant()
  phase('accès privé demandé')
  noter('PRIVE_DEMANDE')
  local statut = catalogue:withPrivateWriteAccessDo(function()
    phase('accès privé obtenu')
    noter('PRIVE_OBTENU\tattente ' .. duree(debut))
    -- Ctrl+Z peut avoir changé l'état pendant l'attente de l'accès au catalogue.
    for _, cle in ipairs({ ETAT, MIROIR, REFERENCE, OPERATIONS, OPERATIONS_MIROIR }) do
      if lire(catalogue, cle) ~= attendu[cle] then return end
    end
    -- Relire le fichier sous l'accès : un autre module a pu l'éditer pendant l'attente.
    local courant = Historique.contenu(chemin)
    local etat = attendu[ETAT] or courant
    local adopter = attendu[ETAT] == nil or (attendu[REFERENCE] == nil and etat == attendu[MIROIR]
      and not etat:find(HistoriqueCommun.MARQUEUR, 1, true) and courant:find(HistoriqueCommun.MARQUEUR, 1, true))
    if adopter then etat = courant end
    local reference = attendu[REFERENCE] or attendu[MIROIR] or etat
    local miroir = Historique.transition(reference, etat, courant)
    miroir = Historique.rejouer(attendu[OPERATIONS_MIROIR] or '', attendu[OPERATIONS] or '', miroir)
    if miroir ~= courant then Historique.ecrire(chemin, miroir) end
    if adopter then catalogue:setPropertyForPlugin(_PLUGIN, ETAT, etat) end
    catalogue:setPropertyForPlugin(_PLUGIN, REFERENCE, etat)
    catalogue:setPropertyForPlugin(_PLUGIN, OPERATIONS_MIROIR, attendu[OPERATIONS] or '')
    catalogue:setPropertyForPlugin(_PLUGIN, MIROIR, miroir)
    Journal.memoriser(catalogue)
    actualise = true
  end, { timeout = 30 })
  noter('PRIVE_FIN\t' .. tostring(statut) .. '\tactualise=' .. tostring(actualise) .. '\ttotal ' .. duree(debut))
  if statut ~= 'executed' then error(T('Lightroom n’a pas accordé l’accès à la synchronisation de l’historique.', 'Lightroom did not grant access to synchronise the history.'), 0) end
  return actualise
end

local ancienVerifie = false
local function synchroniser(catalogue, chemin)
  -- Premier passage sous le nouvel identifiant : aucune annulation de l'ancien ne doit rester en attente.
  if not ancienVerifie and catalogue:getPropertyForPlugin(_PLUGIN, ETAT) == nil then
    Migration.verifierAncien(catalogue, { etat = ETAT, reference = REFERENCE, operations = OPERATIONS,
      operationsMiroir = OPERATIONS_MIROIR }, Journal.lire)
  end
  ancienVerifie = true
  local commun, ancien, partage = HistoriqueCommun.chemins()
  -- Premier passage avec le module Google Photos voisin : l'historique propre rejoint le fichier partagé.
  if partage and chemin == commun and not Historique.contenu(commun):find(HistoriqueCommun.MARQUEUR, 1, true) then
    local statut = catalogue:withPrivateWriteAccessDo(function()
      local courant = Historique.contenu(commun)
      if courant:find(HistoriqueCommun.MARQUEUR, 1, true) then return end
      local etat = catalogue:getPropertyForPlugin(_PLUGIN, ETAT)
      local miroir = catalogue:getPropertyForPlugin(_PLUGIN, MIROIR)
      if etat and etat:find(HistoriqueCommun.MARQUEUR, 1, true) then
        error(T('Le marqueur de l’historique partagé a disparu : migration interrompue.', 'The shared history marker has disappeared: migration stopped.'), 0)
      end
      local localContenu = Historique.contenu(ancien)
      if LrFileUtils.exists(ancien) and not LrFileUtils.readFile(ancien) then
        error(T('Impossible de lire l’ancien historique Deduplicate.', 'Cannot read the old Deduplicate history.'), 0)
      end
      if LrFileUtils.exists(commun) and not LrFileUtils.readFile(commun) then
        error(T('Impossible de lire l’historique Google Photos.', 'Cannot read the Google Photos history.'), 0)
      end
      -- Un Ctrl+Z non synchronisé dans l'ancien module a priorité sur son miroir texte.
      if etat ~= nil and etat ~= miroir then localContenu = etat end
      local fusion = HistoriqueCommun.fusionner(courant, localContenu)
      Historique.ecrire(commun, fusion)
      catalogue:setPropertyForPlugin(_PLUGIN, ETAT, fusion)
      catalogue:setPropertyForPlugin(_PLUGIN, MIROIR, fusion)
      catalogue:setPropertyForPlugin(_PLUGIN, REFERENCE, fusion)
    end, { timeout = 30 })
    if statut ~= 'executed' then error(T('Migration de l’historique partagé impossible.', 'The shared history could not be migrated.'), 0) end
  end
  while true do
    local attendu = {}
    for _, cle in ipairs({ ETAT, MIROIR, REFERENCE, OPERATIONS, OPERATIONS_MIROIR }) do
      attendu[cle] = lire(catalogue, cle)
    end
    local etat, miroir = attendu[ETAT], attendu[MIROIR]
    local fichier = Historique.contenu(chemin)
    if partage and chemin == commun and etat ~= miroir
      and (not etat or not etat:find(HistoriqueCommun.MARQUEUR, 1, true)) then
      error(T('Une ancienne action Lightroom a été annulée. L’historique partagé ne peut pas être synchronisé automatiquement.', 'An old Lightroom action was undone. The shared history cannot be synchronised automatically.'), 0)
    end
    if etat ~= nil and etat == attendu[REFERENCE] and fichier == miroir
      and (attendu[OPERATIONS] or '') == attendu[OPERATIONS_MIROIR] and not Journal.aMemoriser(catalogue) then
      return fichier
    end
    prive(catalogue, attendu, chemin)
    -- Le snapshot a changé pendant l'attente : suivre la nouvelle valeur plutôt que l'écraser.
  end
end

function M.synchroniser(catalogue, chemin)
  return avecVerrou(function() return synchroniser(catalogue, chemin) end, 'synchronisation')
end

-- Un seul accès normal en écriture : un Ctrl+Z annule toute l'opération, quelle que soit sa taille.
-- Le résultat indique seulement si le miroir disque a pu être actualisé après la validation.
function M.action(catalogue, chemin, titre, options, modifier)
  return avecVerrou(function()
    Historique.preparer(chemin)
    phase('action « ' .. titre .. ' » : synchronisation')
    synchroniser(catalogue, chemin)
    local debut = maintenant()
    phase('action « ' .. titre .. ' » : accès en écriture demandé')
    noter('ACTION_DEMANDE\t' .. titre)
    local statut = catalogue:withWriteAccessDo(titre, function(contexte)
      phase('action « ' .. titre .. ' » : accès en écriture obtenu')
      noter('ACTION_OBTENU\tattente ' .. duree(debut))
      -- Les éditions externes servent de base, mais seul le delta de cette action
      -- entre dans Undo. Les snapshots V1 restent lisibles pour les anciennes actions.
      local avant = Historique.contenu(chemin)
      local apres = Historique.modifier(avant, options)
      local ancien = lire(catalogue, OPERATIONS) or ''
      local delta = Historique.journaliser('', avant, apres)
      modifier(contexte)
      Journal.ajouter(catalogue, ancien, delta, options.temoin)
    end, { timeout = 120 })
    noter('ACTION_FIN\t' .. tostring(statut) .. '\ttotal ' .. duree(debut))
    if statut ~= 'executed' then error(T('Lightroom n’a pas accordé l’accès à l’opération « ' .. titre .. ' ».', 'Lightroom did not grant access to the “' .. titre .. '” operation.'), 0) end
    local ok, erreur = LrTasks.pcall(synchroniser, catalogue, chemin)
    phase('action « ' .. titre .. ' » terminée')
    if ok then return true end
    return false, erreur
  end, 'action « ' .. titre .. ' »')
end

-- Le SDK n'expose pas de notification Undo. Une lecture légère du champ suit Ctrl+Z et Rétablir ;
-- chaque commande synchronise aussi avant de lire l'historique, sans attendre ce passage périodique.
function M.demarrer(chemin)
  generation = generation + 1
  local courante = generation
  LrTasks.startAsyncTask(function()
    local derniereErreur
    noter('DEMARRAGE\tgénération ' .. courante)
    while courante == generation do
      local debut = maintenant()
      phase('passage périodique : lecture')
      local ok, erreur = LrTasks.pcall(function()
        M.synchroniser(LrApplication.activeCatalog(), chemin)
      end)
      if maintenant() - debut > 1 then noter('LENT\tpassage périodique ' .. duree(debut)) end
      if not ok then noter('ERREUR\t' .. tostring(erreur):gsub('[\r\n\t]', ' ')) end
      phase('passage périodique : repos')
      if not ok and tostring(erreur) ~= derniereErreur then
        derniereErreur = tostring(erreur)
        LrDialogs.message(T('Historique non synchronisé', 'History not synchronised'), derniereErreur
          .. T('\nLe catalogue conserve l’état annulable. Le module réessaiera la synchronisation.',
            '\nThe catalog keeps the undoable state. The plug-in will try to synchronise again.'), 'warning')
      elseif ok then
        derniereErreur = nil
      end
      LrTasks.sleep(0.5)
    end
  end)
end

function M.arreter()
  generation = generation + 1
end

return M
