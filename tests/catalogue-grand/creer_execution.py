"""Copie fermée et pilote isolé : aucune écriture directe dans SQLite."""
import json
from pathlib import Path
import shutil
import sys
from datetime import datetime
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'catalogue-compact'))
from generer import lua

repo=Path(__file__).resolve().parents[2]
root=repo/'sortie/catalogue-grand'
spec=json.loads((root/'etat-initial/manifest.json').read_text(encoding='utf-8'))
assert not Path(spec['catalogue']+'.lock').exists(), 'Fermer Lightroom'
assert not list(root.rglob('*.lrcat.lock')), 'Fermer toutes les copies de test dans Lightroom'
name='execution-'+datetime.now().strftime('%Y%m%d-%H%M%S')
work=root/name; work.mkdir()
cat=work/'Deduplicate-execution-grand.lrcat'
shutil.copyfile(root/'etat-initial/Deduplicate-grand.lrcat',cat)
shutil.copytree(root/'etat-initial/Deduplicate-grand.lrcat-data',cat.with_suffix('.lrcat-data'))
spec.update(catalogue=str(cat),campagne=name+'/preuves')
(root/'manifest.json').write_text(json.dumps(spec,ensure_ascii=False,indent=2),encoding='utf-8')
(root/'Manifeste.lua').write_text('return '+lua(spec),encoding='utf-8')
plugin=root/'environnement/lightroom-deduplicate/lightroom-deduplicate.lrplugin'
shutil.copytree(repo/'lightroom-deduplicate.lrplugin',plugin,dirs_exist_ok=True,ignore=shutil.ignore_patterns('__pycache__'))
guard="local c=import('LrApplication').activeCatalog()\nif not c or c:getPath():gsub('/','\\\\'):lower()~=("+lua(str(cat))+"):gsub('/','\\\\'):lower() then return end\n"
for name in ['Initialiser','FusionnerDoublons','FusionManuelle','ReduireRafales','RestaurerCollections','DiagnosticCatalogue']:
    p=plugin/(name+'.lua'); p.write_text(guard+p.read_text(encoding='utf-8'),encoding='utf-8')
p=plugin/'Info.lua'; t=p.read_text(encoding='utf-8').replace("'io.github.mtthth.deduplicate'","'io.github.mtthth.deduplicate.grand'").replace("LrPluginName = 'Deduplicate'","LrPluginName = 'Deduplicate - TEST grand'")
t=t.replace("LrInitPlugin = 'Initialiser.lua',","LrInitPlugin = 'Initialiser.lua',\n  LrForceInitPlugin = true,")
p.write_text(t,encoding='utf-8')
shutil.copyfile(root/'etat-initial/photos-traitees.txt',root/'environnement/lightroom-google-photos/photos-traitees.txt')
shutil.copyfile(repo/'sortie/catalogue-compact/environnement/lightroom-deduplicate/lightroom-deduplicate.lrplugin/TestJson.lua',plugin/'TestJson.lua')
t=(repo/'tests/catalogue-compact/Campagne.lua').read_text(encoding='utf-8')
t=t.replace('local function snapshot(c)','local snapshotScope\nlocal function snapshot(c)')
t=t.replace('for _,p in ipairs(c:getAllPhotos()) do',"local photos=snapshotScope or c:getAllPhotos()\n  if #photos>500 then\n    local rows=Json.array()\n    local raw=c:batchGetRawMetadata(photos,{'path','rating','pickStatus','isVirtualCopy'})\n    for _,p in ipairs(photos) do local r=raw[p]; rows[#rows+1]={id=p.localIdentifier,path=r.path,rating=r.rating or 0,pick=r.pickStatus or 0,virtuelle=r.isVirtualCopy or false} end\n    local h=io.open(select(1,require('HistoriqueCommun').chemins()),'rb'); local history=h and h:read('*a') or ''; if h then h:close() end\n    return {photos=rows,history=history,mode='SDK groupé ; état détaillé SQLite en lecture seule externe'}\n  end\n  for _,p in ipairs(photos) do")
t=t.replace('local all=matches[1]:getPhotos();','local all=matches[1]:getPhotos(); snapshotScope=all;')
t=t.replace("local response='ok'","local response='ok'\n    if kind=='confirm' and title=='Réduire les rafales' then response='cancel' end")
t=t.replace("path..'.campagne-initial'","path..'.'..request.id..'.campagne-initial'").replace("path..'.campagne-absent'","path..'.'..request.id..'.campagne-absent'")
t=t.replace("local f=assert(io.open(path,'rb')); local content", "result.perturbation={path=path,backup=path..'.'..request.id..'.campagne-initial',absent=path..'.'..request.id..'.campagne-absent'}\n        local f=assert(io.open(path,'rb')); local content")
(plugin/'Campagne.lua').write_text(t,encoding='utf-8')
p=plugin/'Initialiser.lua'; p.write_text(p.read_text(encoding='utf-8')+"\ndofile(import('LrPathUtils').child(_PLUGIN.path,'Campagne.lua'))\n",encoding='utf-8')
print(cat)
