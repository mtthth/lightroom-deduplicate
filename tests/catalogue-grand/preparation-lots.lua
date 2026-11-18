-- Vérifier la reprise après interruption et l'interdiction d'importer hors cible.
local repo=assert(arg[1])
local fixture={catalogue='/test/catalogue.lrcat',importExistants=true,etatsEnLots=true,
  empreinteEtats='fixture',importLot=25,photos={},cas={{id='U001',titre='Lot'}}}
local photos,properties={},{}
local catalog={path=fixture.catalogue,writes=0,fail=false}
for i=1,60 do
  local p={localIdentifier=i,path='/test/'..i..'.jpg',rating=0,changes=0}
  function p:getRawMetadata(key)
    if key=='keywords' then return {} end
    return self[key]
  end
  function p:setRawMetadata(key,value)
    assert(not (key=='rating' and value==0),'Le SDK rejette la note zéro explicite.')
    self[key]=value; self.changes=self.changes+1
  end
  function p:getContainedCollections() return {} end
  photos[i]=p
  fixture.photos[i]={id='U001-'..i,cas='U001',chemin=p.path,metadata={rating=i==1 and 5 or 0}}
end
function catalog:getPath() return self.path end
function catalog:getAllPhotos() return photos end
function catalog:batchGetRawMetadata(list)
  local result={}
  for _,p in ipairs(list) do result[p]={path=p.path,isVirtualCopy=false,rating=p.rating,pickStatus=0} end
  return result
end
function catalog:findPhotoByPath() error('La lecture groupée des chemins doit suffire.') end
function catalog:addPhoto() error('Aucun import individuel attendu.') end
function catalog:getPropertyForPlugin(_,key) return properties[key] end
function catalog:setPropertyForPlugin(_,key,value) properties[key]=value end
function catalog:withWriteAccessDo(_,callback)
  self.writes=self.writes+1
  if self.fail and self.writes==2 then self.fail=false; return 'timeout' end
  callback(); return 'executed'
end
local function collection() return {addPhotos=function() end} end
catalog.createCollectionSet=collection
catalog.createCollection=collection
catalog.createSmartCollection=function() end
catalog.setActiveSources=function() end
catalog.setSelectedPhotos=function() end
local imports={LrApplication={activeCatalog=function() return catalog end,versionString=function() return 'fixture' end},
  LrTasks={yield=function() end},LrPathUtils={parent=function() return '/test' end,
    child=function(a,b) return a..'/'..b end},LrFileUtils={}}
_PLUGIN={path='/test/preparation.lrplugin'}
function import(name) return assert(imports[name],name) end
local originalDofile=dofile
dofile=function(path) if path=='/test/Manifeste.lua' then return fixture end; return originalDofile(path) end
local originalOpen=io.open
io.open=function(path,mode)
  if path:sub(1,6)=='/test/' then return {write=function() end,close=function() end} end
  return originalOpen(path,mode)
end
local prep=assert(loadfile(repo..'/tests/catalogue-compact/Preparation.lua'))()
catalog.path='/personnel/catalogue.lrcat'
assert(not pcall(prep.executer,'initialiser') and catalog.writes==0)
catalog.path=fixture.catalogue
local last=table.remove(photos)
assert(not pcall(prep.executer,'initialiser') and catalog.writes==0)
photos[#photos+1]=last
catalog.fail=true
assert(not pcall(prep.executer,'initialiser'))
assert(properties['etats-lots-fixture']==25 and photos[1].changes==1)
prep.executer('initialiser')
assert(properties['etats-lots-fixture']==60 and photos[1].changes==1)
for i=2,#photos do assert(photos[i].rating==0 and photos[i].changes==0) end
fixture.snapshotRapide=true
for _,p in ipairs(photos) do p.getContainedCollections=function() error('Aucune lecture individuelle en mode groupé.') end end
prep.executer('verifier')
print('OK : refus hors cible, médias incomplets bloqués avant écriture, reprise à 25/60 sans réappliquer, notes zéro conservées, inventaire groupé.')
