"""Recharge seulement le pilote de tests entre deux commandes SDK."""
from campagne import ROOT, OUT
from pathlib import Path
import json
import time
import sys
import re
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'catalogue-compact'))
from generer import lua

assert not (OUT/'requete.lua').exists(),'Attendre la fin de la commande réelle'
plugin=ROOT/'environnement/lightroom-deduplicate/lightroom-deduplicate.lrplugin'
p=plugin/'Campagne.lua'; t=p.read_text(encoding='utf-8')
assert 'local snapshotScope' in t
if 'local snapshotScope, snapshotSource' not in t:
    t=t.replace('local snapshotScope','local snapshotScope, snapshotSource',1)
t=re.sub(r'  local photos=[^\n]+', '''  local photos=snapshotScope or c:getAllPhotos()
  if snapshotSource then
    local union,seen={},{}
    for _,p in ipairs(photos) do if not seen[p.localIdentifier] then seen[p.localIdentifier]=true; union[#union+1]=p end end
    for _,p in ipairs(snapshotSource:getPhotos()) do if not seen[p.localIdentifier] then seen[p.localIdentifier]=true; union[#union+1]=p end end
    photos=union
  end''',t,count=1)
t=t.replace('visit(c); assert(#matches==1',"require('Catalogue').lectureGroupee(c,function() visit(c) end); assert(#matches==1")
if 'snapshotSource=matches[1]' not in t:
    t=t.replace('local all=matches[1]:getPhotos(); snapshotScope=all;', 'snapshotSource=matches[1]; local all=matches[1]:getPhotos(); snapshotScope=all;')
t=t.replace('local selection={}\n  for _,p in ipairs(all) do\n    local isVirtual=p:getRawMetadata(\'isVirtualCopy\')', "local selection={}\n  local raw=c:batchGetRawMetadata(all,{'isVirtualCopy'})\n  for _,p in ipairs(all) do\n    local isVirtual=raw[p].isVirtualCopy")
p.write_text(t,encoding='utf-8')
generation=(OUT/'worker-generation.txt').read_text(encoding='utf-8')
name='recharger-pilote-'+str(int(time.time()))
payload="import('LrTasks').startAsyncTask(function() import('LrTasks').sleep(20); dofile("+lua(str(p))+") end)\nreturn {id='"+name+"',entry='snapshot'}"
(OUT/'requete-id.txt').write_text(name,encoding='utf-8')
tmp=OUT/'requete.tmp'; tmp.write_text(payload,encoding='utf-8'); tmp.rename(OUT/'requete.lua')
start=time.monotonic()
while (OUT/'worker-generation.txt').read_text(encoding='utf-8')==generation or (OUT/'requete.lua').exists():
    assert time.monotonic()-start<120,'Rechargement non reçu'
    time.sleep(.5)
print('Pilote rechargé, sélection groupée et copies virtuelles actualisées.',flush=True)
