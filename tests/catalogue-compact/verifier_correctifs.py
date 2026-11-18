"""Contrôle les régressions unitaires et les preuves réelles des quatre correctifs."""
import hashlib
import json
from pathlib import Path

repo=Path(__file__).resolve().parents[2]
root=repo/'sortie/catalogue-compact'
out=root/'campagne'
checks=[]
def check(name,ok): checks.append({'controle':name,'ok':bool(ok)})
def load(name): return json.loads((out/(name+'.json')).read_text(encoding='utf-8'))
def case(state,name): return [p for p in state['photos'] if '/'+name+'/' in p['path'].replace('\\','/')]
def sha(p):
    with p.open('rb') as f: return hashlib.file_digest(f,'sha256').hexdigest()

preuves=['corr-restaure-D14','corr-fusion-D14','corr-annulation-D14','corr-retablissement-D14',
    'corr-rafales-R10','corr-restaure-D09','corr-detail-D09-valide','corr-reduction-D05','corr-exact-D01','corr-reduction-D05-force']
for name in preuves:
    r=load(name)
    restoration=r.get('request',{}).get('restauration',{})
    check(name+' : exécution sans erreur',not any(r.get(k) or restoration.get(k) for k in ['error','loadError','taskError'])
          and not any(d.get('severity')=='critical' for d in r.get('dialogs',[])+restoration.get('dialogs',[])))

fusion=load('corr-fusion-D14')
kept=next(p for p in fusion['apres']['photos'] if p['id']==7399)
check('B01 : les deux Paris hiérarchiques et le mot-clé non exporté sont conservés',
      {'Lieux / Paris','Personnes / Paris','Technique / Interne'}=={k['path'] for k in kept['keywords']})
bursts=load('corr-rafales-R10')['rafales']['rafales']
check('B02 : deux rafales distinctes de huit cadres',len(bursts)==2 and all(len(r['cadres'])==8 for r in bursts))
folders=[]
for r in bursts:
    paths={str(Path(f['path']).parent) for c in r['cadres'] for f in c['fichiers']}
    check('B02 : aucun dossier mélangé dans la rafale '+str(r['numero']),len(paths)==1)
    folders.append(paths)
check('B02 : les deux dossiers sont représentés',len(folders)==2 and not folders[0]&folders[1])
r=load('corr-detail-D09-valide')
check('B03 : détail modifié laissé à vérifier',len(r['plan']['decisions'])==1 and bool(r['plan']['decisions'][0].get('aVerifier')))
check('B03 : photos et historique inchangés',r['avant']['photos']==r['apres']['photos'] and r['avant']['history']==r['apres']['history'])
check('B03 : aucun fichier du scénario mis à retirer',all('Doublons à retirer' not in p['collections'] for p in case(r['apres'],'D09')))
check('Variantes réduites également soumises à validation',bool(load('corr-reduction-D05')['plan']['decisions'][0].get('aVerifier')))
forced=load('corr-reduction-D05-force')
check('Validation explicite : la plus grande copie est gardée',sum('Doublons à retirer' in p['collections'] for p in case(forced['apres'],'D05'))==1
      and not any('Doublons à retirer' in p['collections'] for p in case(forced['apres'],'D05') if p['path'].endswith('IMG_1000.jpg')))
check('Doublons exacts toujours proposés automatiquement',not load('corr-exact-D01')['plan']['decisions'][0].get('aVerifier'))
for name,phase in [('corr-annulation-D14','avant'),('corr-retablissement-D14','apres')]:
    r=load(name)
    check('B06 : '+name+' rétablit toutes les photos',r['apres']['photos']==fusion[phase]['photos'])
    check('B06 : '+name+' rétablit aussi le fichier externe',r['apres']['history']==fusion[phase]['history'])
log=(out/'tests-correctifs.log').read_text(encoding='utf-8-sig')
check('19 suites du dépôt réussies',sum(s.startswith('ok      ') for s in log.splitlines())==19 and '\nÉCHEC ' not in log)
spec=json.loads((root/'manifest.json').read_text(encoding='utf-8'))
check('168 médias inchangés aux SHA-256 initiaux',all(sha(Path(p['chemin']))==p['sha256'] for p in spec['photos']))
inventory=json.loads((root/'etat-initial/inventaire.json').read_text(encoding='utf-8'))
check('Sauvegarde initiale inchangée',all(sha(root/'etat-initial'/p['sauvegarde'])==p['sha256'] for p in inventory))
result={'version':'26.11.7','lightroom':'15.6','priorites_hautes_corrigees':['B01','B02','B03','B06'],
    'preuves':[name+'.json' for name in preuves],'controles':checks,'echecs':[c for c in checks if not c['ok']],
    'sources':{p.name:sha(p) for p in (repo/'lightroom-deduplicate.lrplugin').glob('*.lua')},
    'comportement':'Les ressemblances restent à vérifier et nécessitent un forçage explicite. Les doublons exacts restent automatiques.',
    'limites':['Les anciennes fusions ne deviennent pas rétroactivement annulables : utiliser leur sauvegarde de collections.',
        'B04 (vidéos classées retouchées) et B05 (libellés personnalisés) restent hors de ces quatre correctifs.',
        'corr-detail-D09 a été écarté : le pilote répondait Continuer en boucle dans un rapport sans groupe automatique. La validation retient corr-detail-D09-valide.']}
(out/'correctifs.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps({'version':result['version'],'controles':len(checks),'echecs':result['echecs'],'preuves':str(out/'correctifs.json')},ensure_ascii=False,indent=2))
raise SystemExit(bool(result['echecs']))
