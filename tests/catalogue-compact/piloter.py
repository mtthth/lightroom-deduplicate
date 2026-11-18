"""Soumet un scénario au pilote SDK, attend le résultat et en affiche un résumé."""
import argparse
import json
from pathlib import Path
import time
import re
import sys
from generer import lua
sys.stdout.reconfigure(encoding='utf-8')

root=Path(__file__).resolve().parents[2]/'sortie'/'catalogue-compact'
p=argparse.ArgumentParser(); p.add_argument('id'); p.add_argument('entry'); p.add_argument('--cas',default='ALL')
p.add_argument('--racine',type=Path,default=root); p.add_argument('--timeout',type=int,default=240)
p.add_argument('--mode',default='analyse'); p.add_argument('--gardee',type=int); p.add_argument('--sauvegarde')
p.add_argument('--code'); p.add_argument('--ids',type=int,nargs='+'); p.add_argument('--virtuelles',action='store_true')
p.add_argument('--perturber'); p.add_argument('--manquant',action='store_true')
p.add_argument('--label')
p.add_argument('--groupes',type=int,nargs='+')
a=p.parse_args(); request={k:v for k,v in vars(a).items() if v is not None}
root=a.racine.resolve(); spec=json.loads((root/'manifest.json').read_text(encoding='utf-8'))
request.pop('racine'); request.pop('timeout')
assert re.fullmatch(r'[A-Za-z0-9_-]+',a.id), 'Identifiant de requête non valide.'
if a.perturber:
    spec=json.loads((root/'manifest.json').read_text(encoding='utf-8'))
    e=next(e for e in spec['photos'] if e['id']==a.perturber)
    request['perturber']={'path':e['chemin'],'manquant':a.manquant}
request.pop('manquant',None)
out=root/spec.get('campagne','campagne'); out.mkdir(exist_ok=True)
assert not (out/'requete.lua').exists(), 'Une requête est déjà en attente.'
assert not (out/(a.id+'.json')).exists(), 'Identifiant déjà utilisé.'
payload='return '+lua(request)
if a.entry=='RestaurerCollections':
    assert a.sauvegarde and a.mode=='appliquer', 'Sauvegarde explicite et mode appliquer requis.'
    helper=str(Path(__file__).with_name('RestaurerTest.lua'))
    payload=('local detail=dofile('+lua(helper)+')('+lua(request)+')\n'
             +'local request='+lua(request)+'\nrequest.entry="snapshot"; request.restauration=detail\nreturn request')
if a.entry=='VideoTest':
    helper=str(Path(__file__).with_name('VideosTest.lua'))
    payload=('local detail=dofile('+lua(helper)+')('+lua(request)+')\n'
             +'local request='+lua(request)+'\nrequest.entry="snapshot"; request.reglagesVideo=detail\nreturn request')
(out/'requete-id.txt').write_text(a.id,encoding='utf-8')
tmp=out/'requete.tmp'; tmp.write_text(payload,encoding='utf-8'); tmp.rename(out/'requete.lua')
start=time.monotonic()
while True:
    if time.monotonic()-start>a.timeout: raise SystemExit(f'Résultat non reçu sous {a.timeout} secondes.')
    try:
        r=json.loads((out/(a.id+'.json')).read_text(encoding='utf-8'))
        if not (out/'requete.lua').exists(): break
    except (FileNotFoundError,json.JSONDecodeError): pass
    time.sleep(.5)
summary={k:r[k] for k in ['id','error','loadError','taskError'] if k in r}
if 'plan' in r:
    ds=r['plan']['decisions']; summary.update(groupes=len(ds),a_verifier=sum(bool(d.get('aVerifier')) for d in ds),identifiant=r['plan']['identifiant'])
if 'rafales' in r: summary['rafales']=r['rafales']['bilan']
summary['messages']=[d for d in r.get('dialogs',[]) if d['type']=='message']
if r.get('request',{}).get('restauration'): summary['restauration']=r['request']['restauration']
if r.get('finished'): summary['secondes']=round(r['finished']-r['started'],3)
print(json.dumps(summary,ensure_ascii=False,indent=2))
