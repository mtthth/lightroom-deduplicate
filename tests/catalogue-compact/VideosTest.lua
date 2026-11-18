-- Lecture seule des réglages vidéo réels, après les manipulations natives.
return function(request)
  local App,Paths=import 'LrApplication',import 'LrPathUtils'
  local root=Paths.parent(Paths.parent(Paths.parent(_PLUGIN.path)))
  local spec=dofile(Paths.child(root,'Manifeste.lua'))
  local c=App.activeCatalog()
  local function norm(s) return s:gsub('/','\\'):lower() end
  assert(norm(c:getPath())==norm(spec.catalogue) and c:getPath():find('Deduplicate%-execution'))
  local rows={}
  for _,p in ipairs(c:getAllPhotos()) do
    if p:getRawMetadata('isVideo') then
      rows[#rows+1]={id=p.localIdentifier,path=p:getRawMetadata('path'),develop=p:getDevelopSettings(),
        durationInSeconds=p:getRawMetadata('durationInSeconds'),trimmedDurationInSeconds=p:getRawMetadata('trimmedDurationInSeconds')}
    end
  end
  return rows
end
