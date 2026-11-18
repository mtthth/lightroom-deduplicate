-- Préparation contrôlée du catalogue compact ; aucun accès SQLite en écriture.
local App = import 'LrApplication'
local Tasks = import 'LrTasks'
local Paths = import 'LrPathUtils'
local Files = import 'LrFileUtils'
local M = {}
local ensembles,collections,motsCles={},{},{}
local root = Paths.parent(_PLUGIN.path)
local spec = dofile(Paths.child(root, 'Manifeste.lua'))
local function norm(s) return s:gsub('/', '\\'):lower() end
local function catalog()
  local c = App.activeCatalog()
  assert(norm(c:getPath()) == norm(spec.catalogue), 'Refus : catalogue différent du catalogue compact.')
  return c
end
local function write(path, value)
  local f = assert(io.open(Paths.child(root,path),'wb')); f:write(value); f:close()
end
local function log(value)
  local f = assert(io.open(Paths.child(root,'preparation.log'),'ab')); f:write(tostring(value),'\n'); f:close()
end
local function gate(c, name, f)
  assert(c:withWriteAccessDo('Catalogue compact : '..name, f, {timeout=120}) == 'executed', 'Accès catalogue refusé')
end
local function collection(c, names)
  local parent,cle=nil,''
  for i=1,#names-1 do
    cle=cle..'\0'..names[i]
    ensembles[cle]=ensembles[cle] or c:createCollectionSet(names[i],parent,true)
    parent=ensembles[cle]
  end
  cle=cle..'\0'..names[#names]
  collections[cle]=collections[cle] or c:createCollection(names[#names],parent,true)
  return collections[cle]
end
local function keyword(c, names, nonexport)
  local parent,cle=nil,''
  for _,name in ipairs(names) do
    cle=cle..'\0'..name
    motsCles[cle]=motsCles[cle] or c:createKeyword(name,{},not (nonexport and name=='Interne'),parent,true)
    parent=motsCles[cle]
  end
  return parent
end
local function state(c,p,s)
  for k,v in pairs(s.metadata or {}) do
    if k=='rating' and v==0 then
      assert((p:getRawMetadata('rating') or 0)==0,'Une image attendue non notée possède déjà une note.')
    else p:setRawMetadata(k,v) end
  end
  for _,names in ipairs(s.collections or {}) do collection(c,names):addPhotos({p}) end
  for _,names in ipairs(s.keywords or {}) do p:addKeyword(keyword(c,names,s.nonexport)) end
  if s.develop then p:applyDevelopSettings(s.develop,'Cas tordu synthétique') end
end
local function init()
  local c=catalog(); log('DEBUT '..App.versionString()..' '..c:getPath())
  local byCase, all, byPath = {}, {}, {}
  ensembles,collections,motsCles={},{},{}
  local cleEtats=spec.etatsEnLots and ('etats-lots-'..assert(spec.empreinteEtats))
  local dernier=cleEtats and (tonumber(c:getPropertyForPlugin(_PLUGIN,cleEtats)) or 0) or 0
  local existants={}
  if spec.importExistants then
    local liste=c:getAllPhotos()
    local raw=c:batchGetRawMetadata(liste,{'path','isVirtualCopy'})
    for _,p in ipairs(liste) do
      if not raw[p].isVirtualCopy then existants[norm(raw[p].path)]=p end
    end
    for _,e in ipairs(spec.photos) do
      assert(existants[norm(e.chemin)],'Terminer l’import natif avant les états : '..e.id)
    end
    log('CACHE IMPORT '..#liste..' ; ETATS ACHEVES '..dernier)
  end
  local lot=math.max(1,math.min(50,tonumber(spec.importLot) or 1))
  for debut=1,#spec.photos,lot do
    gate(c,'import '..debut,function()
      for i=debut,math.min(debut+lot-1,#spec.photos) do
        local e=spec.photos[i]
        local p=existants[norm(e.chemin)] or c:findPhotoByPath(e.chemin) or c:addPhoto(e.chemin)
        assert(p,'Import impossible : '..e.id)
        all[#all+1]=p; byPath[e.chemin]=p
        byCase[e.cas]=byCase[e.cas] or {}; table.insert(byCase[e.cas],p)
        local fait=(cleEtats and i<=dernier) or (not cleEtats and c:getPropertyForPlugin(_PLUGIN,'etat-'..e.id))
        if not fait then
          state(c,p,e)
          if not cleEtats then c:setPropertyForPlugin(_PLUGIN,'etat-'..e.id,true) end
        end
        if not cleEtats then log('PHOTO '..e.id..' '..p.localIdentifier..' '..e.chemin) end
      end
      if cleEtats then c:setPropertyForPlugin(_PLUGIN,cleEtats,math.min(debut+lot-1,#spec.photos)) end
    end)
    log('PROGRESSION '..math.min(debut+lot-1,#spec.photos)..'/'..#spec.photos)
    Tasks.yield()
  end
  local allCollection
  gate(c,'collections des scénarios',function()
    local top=c:createCollectionSet('Sessions - catalogue de test',nil,true)
    allCollection=c:createCollection('00 - Tous les cas',top,true); allCollection:addPhotos(all)
    for _,s in ipairs(spec.cas) do
      local cc=c:createCollection(s.id..' - '..s.titre,top,true); cc:addPhotos(byCase[s.id])
    end
    c:createSmartCollection('Notes de 4 ou 5 étoiles',{combine='intersect',{criteria='rating',operation='>=',value=4}},top,true)
  end)
  c:setActiveSources({allCollection}); Tasks.yield()
  for _,e in ipairs(spec.photos) do
    for i,v in ipairs(e.virtuals or {}) do
      local property='virtuelle-'..e.id..'-'..i
      if not c:getPropertyForPlugin(_PLUGIN,property) then
        local p=byPath[e.chemin]; c:setSelectedPhotos(p,{p}); Tasks.yield()
        local copies=c:createVirtualCopies(v.name)
        assert(copies and #copies==1,'Création virtuelle impossible : '..e.id)
        gate(c,'virtuelle '..e.id,function()
          state(c,copies[1],v)
          collection(c,{'Sessions - catalogue de test',e.cas..' - '..(function()
            for _,s in ipairs(spec.cas) do if s.id==e.cas then return s.titre end end
          end)()}):addPhotos(copies)
          allCollection:addPhotos(copies)
          c:setPropertyForPlugin(_PLUGIN,property,copies[1].localIdentifier)
        end)
        log('VIRTUELLE '..e.id..' '..i..' '..copies[1].localIdentifier)
      end
    end
  end
  c:setActiveSources({allCollection}); c:setSelectedPhotos(all[1],{})
  log('FIN INITIALISATION')
end

local function snapshot()
  local c=catalog(); local lines={'catalogue\t'..c:getPath(),'lightroom\t'..App.versionString()}
  local photos=c:getAllPhotos(); local masters,virtuals=0,0
  if spec.snapshotRapide then
    local raw=c:batchGetRawMetadata(photos,{'isVirtualCopy','path','rating','pickStatus','dateTimeOriginal'})
    lines[#lines+1]='mode\tlecture SDK groupée ; collections et mots-clés contrôlés séparément par auditer.py'
    for _,p in ipairs(photos) do
      local r=raw[p]; local v=r.isVirtualCopy
      if v then virtuals=virtuals+1 else masters=masters+1 end
      lines[#lines+1]=table.concat({'photo',tostring(p.localIdentifier),v and 'virtuelle' or 'original',r.path,
        tostring(r.rating),tostring(r.pickStatus),tostring(r.dateTimeOriginal),'',''},'\t')
    end
    lines[#lines+1]='originaux\t'..masters; lines[#lines+1]='virtuelles\t'..virtuals
    write('etat-sdk.tsv',table.concat(lines,'\n')..'\n')
    log('VERIFICATION '..masters..' originaux '..virtuals..' virtuelles (SDK groupé)')
    return
  end
  for _,p in ipairs(photos) do
    local v=p:getRawMetadata('isVirtualCopy'); if v then virtuals=virtuals+1 else masters=masters+1 end
    local cols={}; for _,cc in ipairs(p:getContainedCollections()) do cols[#cols+1]=cc:getName() end
    local kw={}; for _,k in ipairs(p:getRawMetadata('keywords') or {}) do kw[#kw+1]=k:getName() end
    lines[#lines+1]=table.concat({'photo',tostring(p.localIdentifier),v and 'virtuelle' or 'original',p:getRawMetadata('path'),
      tostring(p:getRawMetadata('rating')),tostring(p:getRawMetadata('pickStatus')),tostring(p:getRawMetadata('dateTimeOriginal')),
      table.concat(cols,' | '),table.concat(kw,' | ')},'\t')
  end
  lines[#lines+1]='originaux\t'..masters; lines[#lines+1]='virtuelles\t'..virtuals
  write('etat-sdk.tsv',table.concat(lines,'\n')..'\n')
  log('VERIFICATION '..masters..' originaux '..virtuals..' virtuelles')
end

local function adjust()
  local c=catalog()
  for _,e in ipairs(spec.photos) do
    if #(e.virtuals or {})>0 then
      local p=assert(c:findPhotoByPath(e.chemin))
      for i,v in ipairs(e.virtuals) do
        local id=c:getPropertyForPlugin(_PLUGIN,'virtuelle-'..e.id..'-'..i)
        for _,copy in ipairs(p:getRawMetadata('virtualCopies') or {}) do
          if copy.localIdentifier==id then gate(c,'normaliser virtuelle '..e.id,function() state(c,copy,v) end) end
        end
      end
    end
  end
end

local function perturb(command)
  catalog()
  for _,e in ipairs(spec.photos) do
    if (command=='manquant' and e.id=='E01-02') or (command=='modifier' and e.id=='E02-02') then
      local backup=e.chemin..'.initial'
      if not Files.exists(backup) then assert(Files.copy(e.chemin,backup)) end
      if command=='manquant' then
        assert(Files.move(e.chemin,e.chemin..'.absent'))
      else
        local f=assert(io.open(e.chemin,'rb')); local b=f:read('*a'); f:close()
        -- Changer l'EXIF sans modifier la taille ni endommager le JPEG.
        local new,n=b:gsub('Deduplicate %- synth', 'Xeduplicate - synth',1); assert(n==1)
        local g=assert(io.open(e.chemin,'wb')); g:write(new); g:close()
      end
    end
  end
end
local function restore()
  catalog()
  for _,e in ipairs(spec.photos) do
    local backup=e.chemin..'.initial'
    if Files.exists(backup) then
      local f=assert(io.open(backup,'rb')); local b=f:read('*a'); f:close()
      local g=assert(io.open(e.chemin,'wb')); g:write(b); g:close()
    end
  end
end

function M.executer(command)
  spec=dofile(Paths.child(root,'Manifeste.lua'))
  catalog()
  if command=='initialiser' then init(); snapshot()
  elseif command=='verifier' then snapshot()
  elseif command=='actualiser' then adjust(); snapshot()
  elseif command=='manquant' or command=='modifier' then perturb(command)
  elseif command=='restaurer' then restore()
  else error('Commande inconnue : '..tostring(command)) end
end
function M.demarrer()
  if M.demarre then return end
  M.demarre=true
  Tasks.startAsyncTask(function()
    Tasks.sleep(2)
    while true do
      local f=io.open(Paths.child(root,'commande.txt'),'rb')
      if f then
        local command=(f:read('*a') or ''):match('^%s*(%S+)'); f:close()
        local c=App.activeCatalog()
        if c and norm(c:getPath())==norm(spec.catalogue) then
          local ok,err=Tasks.pcall(function() M.executer(command) end)
          write('resultat-commande.txt',(ok and 'OK ' or 'ERREUR ')..tostring(command)..'\n'..tostring(err or '')..'\n')
          Files.move(Paths.child(root,'commande.txt'),Paths.child(root,'commande-'..os.time()..'.faite'))
          log((ok and 'OK ' or 'ERREUR ')..tostring(command)..' '..tostring(err or ''))
        end
      end
      Tasks.sleep(1)
    end
  end)
end
return M
