-- Le registre du catalogue est durable, mais ne suit pas Undo dans Lightroom.
-- Chaque action place donc son numéro dans une métadonnée de photo annulable.
-- Le registre garde les branches et leurs deltas ; les témoins disent laquelle
-- est active. Un témoin retiré du catalogue conserve son dernier état observé :
-- retirer ensuite des photos ne doit pas effacer leurs exclusions.
local M = {}
local REGISTRE, MIROIR = 'registreExclusionsV3', 'temoinsExclusionsMiroirV3'
local CHAMP = 'operationExclusionsV3'
local function hex(s) return (s:gsub('.',function(c) return string.format('%02x',c:byte()) end)) end
local function dehex(s)
  assert(#s%2==0 and not s:find('[^%da-f]'),'Registre des exclusions invalide')
  return (s:gsub('..',function(c) return string.char(tonumber(c,16)) end))
end
local cacheTexte, cache
local function lireRegistre(texte)
  if texte==cacheTexte then return cache end
  local base=texte:match('^V3\t([%da-f]*)\n')
  assert(base and texte:sub(-1)=='\n','Registre des exclusions tronqué')
  local r={base=dehex(base),actions={}}
  for ligne in texte:sub(#base+5):gmatch('[^\n]+') do
    local id,parent,photo,path,delta=ligne:match('^(%d+)\t(%d+)\t(%d+)\t([%da-f]+)\t([%da-f]*)$')
    assert(id,'Action des exclusions invalide')
    id,parent,photo=tonumber(id),tonumber(parent),tonumber(photo)
    assert(id==#r.actions+1 and parent<id,'Branche des exclusions invalide')
    r.actions[id]={id=id,parent=parent,photo=photo,path=dehex(path),delta=dehex(delta)}
  end
  cacheTexte,cache=texte,r
  return r
end
-- plugin : identifiant à lire (par défaut ce module ; Migration lit l'ancien identifiant).
function M.lire(catalogue,ancien,plugin)
  plugin=plugin or _PLUGIN
  local texte=catalogue:getPropertyForPlugin(plugin,REGISTRE)
  if not texte then return ancien or '',0,'' end
  local r=lireRegistre(texte)
  local miroirs={}
  for id,token in (catalogue:getPropertyForPlugin(plugin,MIROIR) or ''):gmatch('(%d+)\t(%d+)\n') do
    miroirs[tonumber(id)]=tonumber(token)
  end
  local temoins,ids={},{}
  for _,a in ipairs(r.actions) do
    if not temoins[a.photo] then ids[#ids+1]=a.photo end
    temoins[a.photo]=a
  end
  table.sort(ids)
  local actif,marqueurs=0,{}
  for _,id in ipairs(ids) do
    local a=temoins[id]
    local photo=catalogue:findPhotoByPath(a.path)
    local token
    if photo and photo.localIdentifier==id then
      token=tonumber(photo:getPropertyForPlugin(plugin,CHAMP)) or 0
    else
      token=miroirs[id] or 0
    end
    assert(token==0 or (r.actions[token] and r.actions[token].photo==id),'Témoin des exclusions invalide')
    marqueurs[#marqueurs+1]=string.format('%d\t%d\n',id,token)
    if token>actif then actif=token end
  end
  local morceaux,position={},actif
  while position>0 do
    local a=r.actions[position]
    table.insert(morceaux,1,a.delta)
    position=a.parent
  end
  table.insert(morceaux,1,r.base)
  return table.concat(morceaux),actif,table.concat(marqueurs)
end
function M.aMemoriser(catalogue)
  local _,_,marqueurs=M.lire(catalogue)
  return marqueurs~=(catalogue:getPropertyForPlugin(_PLUGIN,MIROIR) or '')
end
function M.memoriser(catalogue)
  local _,_,marqueurs=M.lire(catalogue)
  if marqueurs~=(catalogue:getPropertyForPlugin(_PLUGIN,MIROIR) or '') then
    catalogue:setPropertyForPlugin(_PLUGIN,MIROIR,marqueurs)
  end
end
-- Appelé dans le même accès normal en écriture que les modifications de photos.
function M.ajouter(catalogue,ancien,delta,temoin)
  if delta=='' then return end
  assert(temoin,'Photo témoin requise pour rendre les exclusions annulables')
  local path=assert(temoin:getRawMetadata('path'))
  -- findPhotoByPath identifie un original, jamais une copie virtuelle.
  temoin=assert(catalogue:findPhotoByPath(path),'Original de la photo témoin absent')
  local texte=catalogue:getPropertyForPlugin(_PLUGIN,REGISTRE)
  if not texte then texte='V3\t'..hex(ancien or '')..'\n' end
  local r=lireRegistre(texte)
  local _,parent=M.lire(catalogue,ancien)
  local id=#r.actions+1
  temoin:setPropertyForPlugin(_PLUGIN,CHAMP,tostring(id))
  catalogue:setPropertyForPlugin(_PLUGIN,REGISTRE,texte..string.format('%d\t%d\t%d\t%s\t%s\n',
    id,parent,temoin.localIdentifier,hex(path),hex(delta)))
end
return M
