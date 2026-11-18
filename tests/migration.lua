package.path='lightroom-deduplicate.lrplugin/?.lua;'..package.path
local NOUVEAU='io.github.mtthth.deduplicate'
_PLUGIN={id=NOUVEAU}
local M=require 'Migration'
local J=require 'JournalAnnulable'

-- Préférences : la valeur de l'ancien identifiant est reprise une seule fois, sans écraser un réglage neuf.
local magasins={}
local function prefsForPlugin(id)
  id=id or NOUVEAU
  magasins[id]=magasins[id] or {}
  return magasins[id]
end
prefsForPlugin(M.ANCIEN).motCollectionRafales='brouillons'
assert(M.reprendrePreferences(prefsForPlugin), 'préférence reprise')
assert(prefsForPlugin().motCollectionRafales=='brouillons')
prefsForPlugin(M.ANCIEN).motCollectionRafales='autre'
assert(not M.reprendrePreferences(prefsForPlugin), 'reprise faite une seule fois')
assert(prefsForPlugin().motCollectionRafales=='brouillons')
magasins={}
prefsForPlugin(M.ANCIEN).motCollectionRafales=''
assert(M.reprendrePreferences(prefsForPlugin) and prefsForPlugin().motCollectionRafales=='', 'texte vide repris')
magasins={}
assert(not M.reprendrePreferences(function(id) if id then error('refusé') end return prefsForPlugin() end),
  'ancien identifiant illisible : rien à reprendre')
assert(prefsForPlugin().identifiantRepris==M.ANCIEN)

-- Catalogue : propriétés rangées par identifiant de module.
local props,photos={},{}
local function catalogue(refuserAncien)
  local c={}
  function c:getPropertyForPlugin(plugin,k)
    local id=type(plugin)=='table' and plugin.id or plugin
    if refuserAncien and id==M.ANCIEN then error('identifiant inconnu') end
    return (props[id] or {})[k]
  end
  function c:findPhotoByPath(path) return photos[path] end
  return c
end
local function poser(id,k,v) props[id]=props[id] or {}; props[id][k]=v end
local cles={etat='historiquePhotosV1',reference='historiquePhotosReferenceV2',
  operations='historiquePhotosOperationsV2',operationsMiroir='historiquePhotosOperationsMiroirV2'}

assert(M.verifierAncien(catalogue(),cles,J.lire), 'ancien identifiant jamais utilisé')
poser(M.ANCIEN,cles.etat,'h1'); poser(M.ANCIEN,cles.reference,'h1')
assert(M.verifierAncien(catalogue(),cles,J.lire), 'ancien état synchronisé')
poser(M.ANCIEN,cles.etat,'h0')
local ok,message=pcall(M.verifierAncien,catalogue(),cles,J.lire)
assert(not ok and message:find('26.11.9',1,true), 'Ctrl+Z de l’ancienne version non reporté : reprise refusée')
assert(not M.verifierAncien(catalogue(true),cles,J.lire), 'lecture refusée par Lightroom : reprise depuis le fichier')

-- Journal par photos de l'ancien identifiant : une action annulée (témoin remis à 0) est en attente.
poser(M.ANCIEN,cles.etat,'h1')
local temoin={localIdentifier=7}
function temoin:getPropertyForPlugin(plugin) assert(plugin==M.ANCIEN, 'témoin lu sous l’ancien identifiant'); return self.token end
photos['C:/t.jpg']=temoin
poser(M.ANCIEN,'registreExclusionsV3','V3\t\n1\t0\t7\t'..('C:/t.jpg'):gsub('.',function(c) return string.format('%02x',c:byte()) end)
  ..'\t'..('ligne\n'):gsub('.',function(c) return string.format('%02x',c:byte()) end)..'\n')
temoin.token='1'
poser(M.ANCIEN,cles.operationsMiroir,'ligne\n')
assert(M.verifierAncien(catalogue(),cles,J.lire), 'journal synchronisé')
temoin.token='0'
assert(not pcall(M.verifierAncien,catalogue(),cles,J.lire), 'action du journal annulée et non reportée')
print('OK : préférence des rafales reprise une fois, ancien état synchronisé accepté, annulation en attente refusée.')
