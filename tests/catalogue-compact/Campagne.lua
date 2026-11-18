-- Pilote les vraies commandes du module dans le seul catalogue synthétique.
-- Seuls les dialogues sont répondus par le scénario ; SDK, calculs et écritures sont réels.
local originalImport = import
local Tasks=import 'LrTasks'
local App=import 'LrApplication'
local Paths=import 'LrPathUtils'
local Files=import 'LrFileUtils'
local Date=import 'LrDate'
local Json=require 'TestJson'
local root=Paths.parent(Paths.parent(Paths.parent(_PLUGIN.path)))
local spec=dofile(Paths.child(root,'Manifeste.lua'))
local output=Paths.child(root,spec.campagne or 'campagne')
Files.createAllDirectories(output)
local function norm(s) return (s or ''):gsub('/','\\'):lower() end
local function checked()
  local c=App.activeCatalog()
  assert(norm(c:getPath())==norm(spec.catalogue) and c:getPath():find('Deduplicate%-execution'), 'Catalogue de travail synthétique requis')
  return c
end
local function save(name,value)
  local p=Paths.child(output,name)
  local f=assert(io.open(p..'.tmp','wb')); f:write(Json.encode(value)); f:close()
  assert(Files.move(p..'.tmp',p))
end
local function collectionPath(cc)
  local parts={cc:getName()}; local p=cc:getParent()
  while p do table.insert(parts,1,p:getName()); p=p:getParent() end
  return table.concat(parts,' / ')
end
local function keywordPath(k)
  local parts={k:getName()}; local p=k:getParent()
  while p do table.insert(parts,1,p:getName()); p=p:getParent() end
  return table.concat(parts,' / ')
end
local function snapshot(c)
  local result=Json.array()
  for _,p in ipairs(c:getAllPhotos()) do
    local cols,keys=Json.array(),Json.array()
    for _,cc in ipairs(p:getContainedCollections()) do cols[#cols+1]=collectionPath(cc) end
    for _,k in ipairs(p:getRawMetadata('keywords') or {}) do keys[#keys+1]={id=k.localIdentifier,path=keywordPath(k)} end
    table.sort(cols)
    local texts={}
    for _,k in ipairs(require('Doublons').CHAMPS_TEXTE) do texts[k]=p:getFormattedMetadata(k) end
    local v=p:getRawMetadata('isVirtualCopy')
    local row={id=p.localIdentifier,path=p:getRawMetadata('path'),virtuelle=v or false,
      collections=cols,keywords=keys,rating=p:getRawMetadata('rating') or 0,pick=p:getRawMetadata('pickStatus') or 0,
      gps=p:getRawMetadata('gps'),texts=texts,copyName=p:getFormattedMetadata('copyName')}
    row.colorNameForLabel=p:getRawMetadata('colorNameForLabel')
    row.isVideo=p:getRawMetadata('isVideo') or false
    row.develop=p:getDevelopSettings()
    if row.isVideo then
      row.durationInSeconds=p:getRawMetadata('durationInSeconds')
      row.trimmedDurationInSeconds=p:getRawMetadata('trimmedDurationInSeconds')
    end
    result[#result+1]=row
  end
  table.sort(result,function(a,b) return a.id<b.id end)
  local history=select(1,require('HistoriqueCommun').chemins())
  local f=io.open(history,'rb'); local text=f and f:read('*a') or ''; if f then f:close() end
  return {photos=result,history=text,source=(function()
    local sources=Json.array(); for _,s in ipairs(c:getActiveSources()) do sources[#sources+1]=s:getName() end; return sources
  end)()}
end
local function selectCase(c,request)
  local matches={}
  local wanted=request.cas or 'ALL'
  local function visit(parent)
    for _,cc in ipairs(parent:getChildCollections()) do
      local name=cc:getName()
      if (wanted=='ALL' and name=='00 - Tous les cas') or name:sub(1,#wanted+3)==wanted..' - ' then matches[#matches+1]=cc end
    end
    for _,s in ipairs(parent:getChildCollectionSets()) do visit(s) end
  end
  visit(c); assert(#matches==1,'Collection du scénario ambiguë : '..wanted)
  c:setActiveSources({matches[1]}); Tasks.yield()
  local all=matches[1]:getPhotos(); table.sort(all,function(a,b) return a.localIdentifier<b.localIdentifier end)
  local selection={}
  for _,p in ipairs(all) do
    local isVirtual=p:getRawMetadata('isVirtualCopy')
    if request.virtuelles or not isVirtual then
      local accept=not request.ids
      for _,id in ipairs(request.ids or {}) do if p.localIdentifier==id then accept=true end end
      if accept then selection[#selection+1]=p end
    end
  end
  assert(#selection>0,'Sélection vide')
  c:setSelectedPhotos(selection[1],request.selectionUnique and {} or selection)
  Tasks.yield()
  return selection
end
local function copyApi(api)
  local t={}; for k,v in pairs(api) do t[k]=v end; return t
end
local function cleanCopy(p)
  return {id=p.id,path=p.chemin,virtuelle=p.virtuelle or false,note=p.note,drapeau=p.drapeau,gps=p.gps,
    empreinte=p.empreinte,pixels=p.pixels,retouchee=p.retouchee,virtuelles=p.virtuelles,raison=p.pourquoi}
end
local function cleanEffects(e)
  if not e then return nil end
  local keys,cols,removed=Json.array(),Json.array(),Json.array()
  for _,k in ipairs(e.motsCles or {}) do keys[#keys+1]={nom=k.nom,id=k.objet and k.objet.localIdentifier} end
  for _,cc in ipairs(e.collections or {}) do cols[#cols+1]={id=cc.id,nom=cc.nom} end
  for _,q in ipairs(e.quittees or {}) do removed[#removed+1]={photo=q.copie.id,collection=q.collection.id} end
  return {motsCles=keys,collections=cols,quittees=removed,note=e.note,drapeau=e.drapeau,gps=e.gps,textes=e.textes}
end
local function cleanPlan(model)
  local ds=Json.array()
  for i,d in ipairs(model.decisions) do
    local retirees=Json.array(); for _,p in ipairs(d.retirees) do retirees[#retirees+1]=cleanCopy(p) end
    ds[#ds+1]={numero=i,garde=cleanCopy(d.garde),retirees=retirees,aVerifier=d.aVerifier,versions=d.versions,pourquoi=d.pourquoi,effets=cleanEffects(d.effets)}
  end
  local nbVersions=0; for _,d in ipairs(model.decisions) do if d.versions then nbVersions=nbVersions+1 end end
  return {decisions=ds,identifiant=model.identifiant,differents=nbVersions,notes=model.notes}
end
local function cleanBursts(source,rafales,bilan)
  local rs=Json.array()
  for _,r in ipairs(rafales) do
    local frames=Json.array()
    for _,c in ipairs(r) do
      local fs=Json.array(); for _,f in ipairs(c.fichiers) do fs[#fs+1]={id=f.id,path=f.chemin} end
      frames[#frames+1]={numero=c.numero,t=c.t,decision=c.decision,raisons=c.raisons,nettete=c.nettete,fichiers=fs}
    end
    rs[#rs+1]={numero=r.numero,cadres=frames}
  end
  return {source=source,rafales=rs,bilan=bilan}
end
local function run(request)
  local c=checked()
  local result={id=request.id,request=request,dialogs=Json.array(),started=Date.currentTime()}
  if request.entry=='snapshot' then result.apres=snapshot(c); save(request.id..'.json',result); return end
  if request.entry=='undo' or request.entry=='redo' then
    local Undo=import 'LrUndo'
    result.avant=snapshot(c)
    if request.entry=='undo' then assert(Undo.canUndo()); Undo.undo()
    else assert(Undo.canRedo()); Undo.redo() end
    Tasks.sleep(1)
    require('Annulation').synchroniser(c,require('HistoriqueCommun').chemins())
    result.apres=snapshot(c)
    save(request.id..'.json',result); return
  end
  if request.entry=='prepare' then
    selectCase(c,request); result.apres=snapshot(c); save(request.id..'.json',result); return
  end
  if request.entry=='setLabel' then
    local selected=selectCase(c,request)
    assert(request.label and #selected==1,'Un libellé et une seule photo requis')
    c:withWriteAccessDo('Test : libellé personnalisé',function() selected[1]:setRawMetadata('label',request.label) end,{timeout=30})
    result.apres=snapshot(c); save(request.id..'.json',result); return
  end
  if request.entry=='diagnostic' then
    local adjusted=c:findPhotos{searchDesc={criteria='hasAdjustments',operation='isTrue',value=true}}
    result.retouchees=Json.array()
    for _,p in ipairs(adjusted) do result.retouchees[#result.retouchees+1]={id=p.localIdentifier,path=p:getRawMetadata('path'),video=p:getRawMetadata('isVideo')} end
    result.apres=snapshot(c); save(request.id..'.json',result); return
  end
  selectCase(c,request); result.avant=snapshot(c)
  local props,dialogs,bindings,tasks={},{},copyApi(originalImport('LrBinding')),copyApi(Tasks)
  local realDialogs=originalImport('LrDialogs'); setmetatable(dialogs,{__index=realDialogs})
  bindings.makePropertyTable=function(...)
    local p=originalImport('LrBinding').makePropertyTable(...); props[#props+1]=p; return p
  end
  local dialogCount=0
  local rienAFusionner=false
  local function answer(title,kind,args)
    dialogCount=dialogCount+1; assert(dialogCount<20,'Boucle de dialogues détectée')
    local response='ok'
    if rienAFusionner and title=='Résultat de la recherche des doublons' then response='cancel' end
    if request.mode=='analyse' and (title=='Résultat de la recherche des doublons' or title=='Mettre de côté les cadres en trop ?' or kind=='confirm') then response='cancel' end
    if title=='Fusion manuelle' and request.gardee then
      for _,p in ipairs(props) do if p.gardee then p.gardee=request.gardee end end
    end
    if title=='Résultat de la recherche des doublons' then
      if request.code then for _,p in ipairs(props) do if p.code~=nil then p.code=request.code end end end
      if request.perturber then
        local path=assert(request.perturber.path); assert(norm(path):sub(1,#norm(spec.medias))==norm(spec.medias))
        local f=assert(io.open(path,'rb')); local content=f:read('*a'); f:close()
        local b=assert(io.open(path..'.campagne-initial','wb')); b:write(content); b:close()
        if request.perturber.manquant then assert(Files.move(path,path..'.campagne-absent'))
        else
          local changed,n=content:gsub('Deduplicate %- synth','Xeduplicate - synth',1); assert(n==1)
          local g=assert(io.open(path,'wb')); g:write(changed); g:close()
        end
      end
    end
    result.dialogs[#result.dialogs+1]={title=title,type=kind,reponse=response,args=args}
    return response
  end
  dialogs.presentModalDialog=function(options) return answer(options.title,'modal',{action=options.actionVerb}) end
  dialogs.confirm=function(title,text,a,b,other) return answer(title,'confirm',{text=text,action=a,cancel=b,other=other}) end
  dialogs.message=function(title,text,severity)
    if title=='Rien à fusionner' then rienAFusionner=true end
    result.dialogs[#result.dialogs+1]={title=title,text=text,severity=severity,type='message'}
  end
  dialogs.runOpenPanel=function(options)
    assert(request.sauvegarde,'Sauvegarde explicite requise')
    result.dialogs[#result.dialogs+1]={title=options.title,type='open',path=request.sauvegarde}
    return {request.sauvegarde}
  end
  local pending=0
  tasks.startAsyncTask=function(callback,...)
    pending=pending+1
    return Tasks.startAsyncTask(function()
      local ok,err=Tasks.pcall(callback)
      if not ok then result.taskError=tostring(err) end
      pending=pending-1
    end,...)
  end
  local report=require 'RapportHtml'; local oldPage=report.page
  local bursts=require 'RapportRafales'; local oldBursts=bursts.page
  report.page=function(model) result.plan=cleanPlan(model); return oldPage(model) end
  bursts.page=function(source,rafales,bilan) result.rafales=cleanBursts(source,rafales,bilan); return oldBursts(source,rafales,bilan) end
  local allowed={FusionnerDoublons=true,FusionManuelle=true,ReduireRafales=true,RestaurerCollections=true}
  assert(allowed[request.entry],'Commande non autorisée')
  import=function(name)
    if name=='LrDialogs' then return dialogs elseif name=='LrBinding' then return bindings elseif name=='LrTasks' then return tasks end
    return originalImport(name)
  end
  local ok,err=Tasks.pcall(function() dofile(Paths.child(_PLUGIN.path,request.entry..'.lua')) end)
  import=originalImport
  if not ok then result.loadError=tostring(err) end
  while pending>0 do Tasks.sleep(0.1) end
  report.page=oldPage; bursts.page=oldBursts
  Tasks.sleep(0.5)
  result.apres=snapshot(c); result.finished=Date.currentTime()
  save(request.id..'.json',result)
end
-- Le SDK peut exécuter LrInitPlugin et LrEnablePlugin, et un rechargement ne
-- termine pas nécessairement les anciennes tâches. Un seul lecteur de requêtes.
local generation=import('LrUUID').generateUUID()
local generationPath=Paths.child(output,'worker-generation.txt')
do local f=assert(io.open(generationPath,'wb')); f:write(generation); f:close() end
local function active()
  local f=io.open(generationPath,'rb'); if not f then return false end
  local v=f:read('*a'); f:close(); return v==generation
end
Tasks.startAsyncTask(function()
  Tasks.sleep(2)
  if not active() then return end
  save('worker-actif-'..os.time()..'.json',{catalogue=App.activeCatalog():getPath()})
  while active() do
    local path=Paths.child(output,'requete.lua')
    if Files.exists(path) then
      local ok,err=Tasks.pcall(function()
        checked(); local request=dofile(path)
        local good,failure=Tasks.pcall(function() run(request) end)
        if not good then save(request.id..'.json',{id=request.id,error=tostring(failure)}) end
      end)
      if not ok then
        local f=io.open(Paths.child(output,'requete-id.txt'),'rb')
        local id=f and f:read('*a'); if f then f:close() end
        if not id or not id:match('^[%w_%-]+$') then id='erreur-worker-'..import('LrUUID').generateUUID() end
        save(id..'.json',{id=id,error=tostring(err)})
      end
      Files.move(path,Paths.child(output,'requete-'..import('LrUUID').generateUUID()..'.faite'))
    end
    Tasks.sleep(0.25)
  end
end)
