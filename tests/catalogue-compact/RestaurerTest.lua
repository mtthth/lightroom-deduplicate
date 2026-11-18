-- Appelé depuis une requête du pilote déjà borné au catalogue synthétique.
-- Répond seulement aux dialogues ; la restauration utilise le vrai SDK.
return function(request)
  local originalImport=import
  local App=import 'LrApplication'
  local Tasks=import 'LrTasks'
  local Paths=import 'LrPathUtils'
  local root=Paths.parent(Paths.parent(Paths.parent(_PLUGIN.path)))
  local spec=dofile(Paths.child(root,'Manifeste.lua'))
  local function norm(s) return s:gsub('/','\\'):lower() end
  assert(norm(App.activeCatalog():getPath())==norm(spec.catalogue))
  assert(spec.catalogue:find('Deduplicate%-execution'))
  assert(norm(request.sauvegarde):sub(1,#norm(root))==norm(root))
  local result={dialogs={},sauvegarde=request.sauvegarde}
  local props,pending={},0
  local dialogs={}; setmetatable(dialogs,{__index=originalImport('LrDialogs')})
  local bindings={}; setmetatable(bindings,{__index=originalImport('LrBinding')})
  local tasks={}; setmetatable(tasks,{__index=Tasks})
  bindings.makePropertyTable=function(...)
    local p=originalImport('LrBinding').makePropertyTable(...); props[#props+1]=p; return p
  end
  dialogs.runOpenPanel=function() return {request.sauvegarde} end
  dialogs.presentModalDialog=function(options)
    assert(options.title=='Choisir les groupes à restaurer','Dialogue inattendu : '..options.title)
    for _,p in ipairs(props) do
      for _,n in ipairs(request.groupes or {1}) do assert(p['groupe'..n]~=nil); p['groupe'..n]=true end
    end
    result.dialogs[#result.dialogs+1]={title=options.title,reponse='ok'}
    return 'ok'
  end
  dialogs.confirm=function(title,text)
    assert(title=='Restaurer les collections d’origine ?','Confirmation inattendue : '..title)
    result.dialogs[#result.dialogs+1]={title=title,text=text,reponse='ok'}; return 'ok'
  end
  dialogs.message=function(title,text,severity)
    result.dialogs[#result.dialogs+1]={title=title,text=text,severity=severity}
  end
  tasks.startAsyncTask=function(callback,...)
    pending=pending+1
    return Tasks.startAsyncTask(function()
      local ok,err=Tasks.pcall(callback)
      if not ok then result.taskError=tostring(err) end
      pending=pending-1
    end,...)
  end
  import=function(name)
    if name=='LrDialogs' then return dialogs elseif name=='LrBinding' then return bindings
    elseif name=='LrTasks' then return tasks end
    return originalImport(name)
  end
  local ok,err=Tasks.pcall(function() dofile(Paths.child(_PLUGIN.path,'RestaurerCollections.lua')) end)
  import=originalImport
  if not ok then result.loadError=tostring(err) end
  while pending>0 do Tasks.sleep(.1) end
  return result
end
