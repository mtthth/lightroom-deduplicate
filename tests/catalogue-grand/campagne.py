"""Campagne SDK réelle, états indépendants en SQLite strictement lecture seule."""
import gzip
import hashlib
import json
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import time

REPO=Path(__file__).resolve().parents[2]
ROOT=REPO/'sortie/catalogue-grand'
SPEC=json.loads((ROOT/'manifest.json').read_text(encoding='utf-8'))
OUT=ROOT/SPEC['campagne']
CHECKS=[]
NORM=lambda p:str(p).replace('/','\\').casefold()
BY_PATH={NORM(p['chemin']):p for p in SPEC['photos']}

def check(name,condition,detail=None):
    CHECKS.append(dict(controle=name,ok=bool(condition),detail=detail))
    (OUT/'controles.json').write_text(json.dumps(CHECKS,ensure_ascii=False,indent=2),encoding='utf-8')
    print(('OK ' if condition else 'ECHEC ')+name,flush=True)

def snapshot(name):
    saved=OUT/(name+'-sqlite.json.gz')
    if saved.exists():
        with gzip.open(saved,'rt',encoding='utf-8') as f: previous=json.load(f)
        previous['photos']={int(k):v for k,v in previous['photos'].items()}
        return previous
    db=sqlite3.connect(Path(SPEC['catalogue']).as_uri()+'?mode=ro',uri=True)
    db.execute('pragma query_only=ON'); db.execute('BEGIN')
    cs={r[0]:(r[1],r[2]) for r in db.execute('select id_local,name,parent from AgLibraryCollection')}
    ks={r[0]:(r[1],r[2]) for r in db.execute('select id_local,name,parent from AgLibraryKeyword')}
    def hierarchy(table,id):
        names=[]
        while id:
            n,id=table[id]
            if n is not None: names.insert(0,n)
        return ' / '.join(names)
    rows=db.execute('''select i.id_local,i.masterImage,i.rating,i.pick,i.colorLabels,i.copyName,
        r.absolutePath,d.pathFromRoot,f.baseName,f.extension from Adobe_images i
        join AgLibraryFile f on f.id_local=i.rootFile join AgLibraryFolder d on d.id_local=f.folder
        join AgLibraryRootFolder r on r.id_local=d.rootFolder''')
    photos={r[0]:dict(id=r[0],master=r[1],rating=r[2] or 0,pick=r[3],label=r[4],copy=r[5],
        path=str(Path(r[6])/r[7]/(r[8]+'.'+r[9])),collections=[],keywords=[]) for r in rows}
    for i,c in db.execute('select image,collection from AgLibraryCollectionImage'):
        if i in photos: photos[i]['collections'].append(hierarchy(cs,c))
    for i,k in db.execute('select image,tag from AgLibraryKeywordImage'):
        if i in photos: photos[i]['keywords'].append([k,hierarchy(ks,k)])
    for i,txt in db.execute('select image,text from Adobe_imageDevelopSettings'):
        if i in photos: photos[i]['develop_sha256']=hashlib.sha256((txt or '').encode()).hexdigest()
    db.close()
    for p in photos.values(): p['collections'].sort(); p['keywords'].sort()
    history=(ROOT/'environnement/lightroom-google-photos/photos-traitees.txt').read_text(encoding='utf-8')
    state=dict(photos=photos,history=history)
    with gzip.open(OUT/(name+'-sqlite.json.gz'),'wt',encoding='utf-8') as f: json.dump(state,f,ensure_ascii=False)
    return state

def run(name,entry,case='ALL',mode='analyse',**args):
    result=OUT/(name+'.json')
    pending=OUT/'requete.lua'
    if pending.exists() and (OUT/'requete-id.txt').read_text(encoding='utf-8')==name:
        start=time.monotonic()
        while pending.exists() or not result.exists():
            assert time.monotonic()-start<3600,'Commande en attente trop longtemps : '+name
            time.sleep(.5)
    if not result.exists():
        cmd=[sys.executable,str(REPO/'tests/catalogue-compact/piloter.py'),name,entry,
             '--racine',str(ROOT),'--timeout','3600','--cas',case,'--mode',mode]
        for k,v in args.items():
            if v is True: cmd+=['--'+k]
            elif isinstance(v,list): cmd+=['--'+k,*map(str,v)]
            else: cmd+=['--'+k,str(v)]
        with (OUT/(name+'.log')).open('w',encoding='utf-8') as f:
            p=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT)
        assert p.returncode==0,(name,p.returncode)
    r=json.loads(result.read_text(encoding='utf-8'))
    for source in (ROOT/'environnement/lightroom-deduplicate').glob('diagnostic*.txt'):
        target=OUT/(name+'-'+source.name)
        if not target.exists(): target.write_bytes(source.read_bytes())
    restore=r.get('request',{}).get('restauration',{})
    errors=[str(x.get(k)) for x in [r,restore] for k in ['error','loadError','taskError'] if x.get(k)]
    errors +=[str(d) for d in r.get('dialogs',[])+restore.get('dialogs',[]) if d.get('severity')=='critical'
              and not (args.get('perturber') and 'Fusion interrompue avant toute modification' in d.get('text',''))]
    check(name+' : commande sans erreur',not errors,errors)
    return r

def cid(path): return BY_PATH[NORM(path)]['cas']
def trash(p,kind='Doublons'): return kind+' à retirer' in p['collections']
def backup(r):
    texts='\n'.join(d.get('text','') for d in r.get('dialogs',[]))
    paths=re.findall(r'([A-Z]:[^\r\n]*collections-avant-[^\r\n]*\.txt)',texts)
    assert paths,texts
    return paths[-1].strip()
def restore(name,r):
    path=backup(r)
    groups=[int(n) for n in re.findall(r'^GROUPE\t(\d+)',Path(path).read_text(encoding='utf-8'),re.M)]
    assert groups,path
    return run(name,'RestaurerCollections',mode='appliquer',sauvegarde=path,groupes=groups)

def main():
    initial=snapshot('initial')
    check('10 000 originaux et 144 copies virtuelles',len(initial['photos'])==10144 and sum(not p['master'] for p in initial['photos'].values())==10000)
    cold=run('global-doublons-froid','FusionnerDoublons')
    warm=run('global-doublons-chaud','FusionnerDoublons')
    ds=cold.get('plan',{}).get('decisions',[])
    check('Recherche froide et chaude : mêmes décisions',cold.get('plan',{}).get('decisions')==warm.get('plan',{}).get('decisions'))
    check('Analyse sans mutation des photos',initial['photos']==snapshot('apres-analyses')['photos'])
    cases={c['id']:[] for c in SPEC['cas']}
    for d in ds:
        paths=[d['garde']['path']]+[p['path'] for p in d['retirees']]
        labels={cid(p) for p in paths}
        check('Groupe '+str(d['numero'])+' : un seul scénario',len(labels)==1,sorted(labels))
        for c in labels: cases[c].append(d)
    for c in SPEC['cas']:
        name=c['id']; groups=cases[name]
        if name[0] in 'XTM' and name[1:].isdigit():
            check(name+' : groupe exact automatique',len(groups)==1 and not groups[0].get('aVerifier'))
        elif name[0] in 'UPWB' and name[1:].isdigit():
            check(name+' : aucune fusion automatique',not any(not d.get('aVerifier') for d in groups))
    (OUT/'couverture-cas.json').write_text(json.dumps({k:[d['numero'] for d in v] for k,v in cases.items()},indent=2),encoding='utf-8')
    bursts=run('global-rafales-analyse','ReduireRafales')
    rs=bursts.get('rafales',{}).get('rafales',[])
    bycase={}
    for r in rs:
        files=[f for frame in r['cadres'] for f in frame['fichiers']]
        labels={cid(f['path']) for f in files}; folders={NORM(Path(f['path']).parent) for f in files}
        check('Rafale '+str(r['numero'])+' : dossier et scénario uniques',len(labels)==1 and len(folders)==1)
        for c in labels: bycase.setdefault(c,[]).append(r)
    for n in range(200):
        c=f'B{n+1:03d}'; actual=bycase.get(c,[])
        expected=[12] if n%2==0 else [6,6]
        check(c+' : découpage attendu',sorted(len(r['cadres']) for r in actual)==expected)
    # Vérification des décisions réellement présentées, puis des écritures réelles.
    fusion=run('global-fusion','FusionnerDoublons',mode='appliquer')
    after=snapshot('fusion')
    auto=[d for d in fusion.get('plan',{}).get('decisions',[]) if not d.get('aVerifier')]
    check('Fusion en volume réellement appliquée',bool(auto) and any(d.get('title')=='Doublons fusionnés' for d in fusion.get('dialogs',[])))
    for d in auto:
        check('Fusion groupe '+str(d['numero'])+' : gardée protégée et copies écartées',
              not trash(after['photos'][d['garde']['id']]) and all(trash(after['photos'][p['id']]) for p in d['retirees']))
        ids=[d['garde']['id']]+[p['id'] for p in d['retirees']]
        kept=after['photos'][ids[0]]
        expected_keys={k[0] for i in ids for k in initial['photos'][i]['keywords']}
        expected_cols={c for i in ids for c in initial['photos'][i]['collections'] if c not in ['Doublons à retirer','Rafales à retirer']}
        check('Fusion groupe '+str(d['numero'])+' : métadonnées et appartenances réunies',
              expected_keys<={k[0] for k in kept['keywords']} and expected_cols<=set(kept['collections'])
              and kept['rating']==max(initial['photos'][i]['rating'] for i in ids))
    check('Les variantes proches ne sont jamais écartées automatiquement',
          all(not trash(p) for p in after['photos'].values() if cid(p['path']).startswith('P')))
    run('global-fusion-undo','undo'); undone=snapshot('fusion-undo')
    check('Annuler la fusion : état catalogue complet',undone['photos']==initial['photos'])
    check('Annuler la fusion : historique externe',undone['history']==initial['history'])
    run('global-fusion-redo','redo'); redone=snapshot('fusion-redo')
    check('Rétablir la fusion : catalogue et historique',redone==after)
    restore('global-fusion-restaurer',fusion); restored=snapshot('fusion-restauree')
    check('Restauration : appartenances initiales de tous les originaux',all(set(p['collections'])<=set(restored['photos'][i]['collections']) for i,p in initial['photos'].items()))
    reduction=run('global-rafales-appliquer','ReduireRafales',mode='appliquer')
    reduced=snapshot('rafales')
    frames=[f for r in reduction.get('rafales',{}).get('rafales',[]) for f in r['cadres']]
    print('DECISIONS RAFAlES',sorted({f.get('decision','?') for f in frames}),flush=True)
    check('Réduction réellement appliquée',any(d.get('title')=='Rafales mises de côté' for d in reduction.get('dialogs',[])))
    for frame in frames:
        check('Rafale cadre '+str(frame['numero'])+' : décision respectée',
              all(trash(reduced['photos'][f['id']],'Rafales')==(frame['decision']=='retirer') for f in frame['fichiers']))
    run('global-rafales-undo','undo'); undone=snapshot('rafales-undo')
    check('Annuler les rafales : catalogue et historique',undone==restored)
    run('global-rafales-redo','redo'); check('Rétablir les rafales : catalogue et historique',snapshot('rafales-redo')==reduced)
    repeat=run('global-rafales-relancer','ReduireRafales')
    check('Deuxième réduction : aucun nouveau retrait',not repeat.get('rafales',{}).get('rafales'))
    restore('global-rafales-restaurer',reduction)
    (OUT/'phase-volume-terminee.json').write_text(json.dumps(dict(controles=len(CHECKS),echecs=[c for c in CHECKS if not c['ok']]),ensure_ascii=False,indent=2),encoding='utf-8')

if __name__=='__main__': main()
