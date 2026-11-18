"""Vérifie les preuves réelles des corrections vidéo et libellés personnalisés."""
import hashlib
import json
from pathlib import Path

repo=Path(__file__).resolve().parents[2]
root=repo/'sortie/catalogue-compact'
out=root/'campagne'
checks=[]
def load(n): return json.loads((out/(n+'.json')).read_text(encoding='utf-8'))
def check(n,ok): checks.append({'controle':n,'ok':bool(ok)})
def case(state,name): return [p for p in state['photos'] if '/'+name+'/' in p['path'].replace('\\','/')]
def sha(p):
    with p.open('rb') as f: return hashlib.file_digest(f,'sha256').hexdigest()
names=['moyennes-videos-V01','moyennes-videos-V02-vierge','moyennes-videos-V03-vierge',
       'moyennes-videos-modifiees-natives','moyennes-video-protection-reelle',
       'moyennes-video-reset-seconde','moyennes-video-seule-retouche-validee',
       'moyennes-video-retablie','moyennes-videos-V03-retablies','moyennes-videos-V04-differentes',
       'moyennes-libelle-R04','moyennes-libelle-R04-applique','moyennes-libelle-R08',
       'moyennes-restauration-R04','moyennes-diagnostic-final','moyennes-photo-exacte-regression']
for name in names:
    r=load(name); resto=r.get('request',{}).get('restauration',{})
    check(name+' sans erreur',not any(r.get(k) or resto.get(k) for k in ['error','loadError','taskError'])
          and not any(x.get('severity')=='critical' for x in r.get('dialogs',[])+resto.get('dialogs',[])))
for name in ['moyennes-videos-V01','moyennes-videos-V02-vierge','moyennes-videos-V03-vierge','moyennes-videos-V03-retablies']:
    r=load(name); ds=r['plan']['decisions']
    check('Vidéos vierges proposées : '+name,len(ds)==1 and not ds[0].get('aVerifier')
          and all(p.get('retouchee') is False for p in [ds[0]['garde']]+ds[0]['retirees']))
r=load('moyennes-videos-V01')
check('V01 : fusion effectivement appliquée',sum('Doublons à retirer' in p['collections'] for p in case(r['apres'],'V01'))==1)
check('Photos exactes toujours proposées automatiquement',
      not load('moyennes-photo-exacte-regression')['plan']['decisions'][0].get('aVerifier'))
r=load('moyennes-videos-modifiees-natives')['request']['reglagesVideo']
edited=[v for v in r if '/V03/' in v['path'].replace('\\','/')]
check('Deux corrections vidéo réelles et une coupe de 0,25 s',len(edited)==2
      and all(v['develop']['Exposure2012']!=0 for v in edited)
      and any(v['develop']['TrimStart']=={'numerator':1,'denominator':4} and v['trimmedDurationInSeconds']==.75 for v in edited))
r=load('moyennes-video-protection-reelle')
check('Deux vidéos réellement retouchées restent à vérifier',r['plan']['decisions'][0]['aVerifier']=='plusieurs copies retouchées')
check('Analyse des vidéos retouchées sans écriture',r['avant']['photos']==r['apres']['photos'] and r['avant']['history']==r['apres']['history'])
r=load('moyennes-video-seule-retouche-validee'); d=r['plan']['decisions'][0]
check('Une seule vidéo retouchée : conserver celle avec la coupe',d['garde']['id']==11049 and d['garde']['retouchee'] is True
      and not d.get('aVerifier') and d['retirees'][0]['retouchee'] is False)
r=load('moyennes-video-retablie')['request']['reglagesVideo']
check('Huit clips rétablis : exposition neutre et durée entière',len(r)==8 and all(
    v['develop']['Exposure2012']==0 and v['develop']['Exposure']==0
    and v['develop']['TrimStart']['numerator']==0
    and v['develop']['TrimEnd']['numerator']/v['develop']['TrimEnd']['denominator']==v['durationInSeconds']
    and v['trimmedDurationInSeconds']==v['durationInSeconds'] for v in r))
r=load('moyennes-videos-V04-differentes')
check('V04 : octets vidéo différents toujours conservés',not r.get('plan',{}).get('decisions')
      and r['avant']['photos']==r['apres']['photos'] and r['avant']['history']==r['apres']['history'])
r=load('moyennes-libelle-R04-applique')
p=next(p for p in r['apres']['photos'] if p['id']==13961)
frames=[f for burst in r['rafales']['rafales'] for f in burst['cadres'] if any(x['id']==13961 for x in f['fichiers'])]
check('Libellé personnalisé protégé malgré la couleur white',p['texts']['label']=='À vérifier' and p['colorNameForLabel']=='white'
      and len(frames)==1 and frames[0]['decision']=='protégé' and any('À vérifier' in x for x in frames[0]['raisons']))
check('Après réduction, photo libellée hors retrait',r['rafales']['bilan']['retires']==2 and 'Rafales à retirer' not in p['collections'])
check('R08 : toutes les huit protections reconnues',load('moyennes-libelle-R08')['rafales']['bilan']['proteges']==8)
check('R04 : restauration après test',case(r['avant'],'R04')==case(load('moyennes-restauration-R04')['apres'],'R04'))
diag=load('moyennes-diagnostic-final')
check('Le SDK général signalait les huit vidéos vierges retouchées au départ',
      sum(bool(p.get('video')) for p in load('diagnostic-videos')['retouchees'])==8)
check('V02 vierge reste signalée retouchée par le SDK général',
      {10721,10887}<={p['id'] for p in diag['retouchees'] if p.get('video')})
log=(out/'tests-moyennes.log').read_text(encoding='utf-8-sig')
check('21 suites réussies',sum(s.startswith('ok      ') for s in log.splitlines())==21 and '\nÉCHEC ' not in log)
spec=json.loads((root/'manifest.json').read_text(encoding='utf-8'))
check('168 médias inchangés aux empreintes initiales',all(sha(Path(p['chemin']))==p['sha256'] for p in spec['photos']))
inventory=json.loads((root/'etat-initial/inventaire.json').read_text(encoding='utf-8'))
check('Sauvegarde initiale inchangée',all(sha(root/'etat-initial'/p['sauvegarde'])==p['sha256'] for p in inventory))
result={'version':'26.11.8','lightroom':'15.6','priorites_moyennes_corrigees':['B04','B05'],
        'preuves':[n+'.json' for n in names],'controles':checks,'echecs':[c for c in checks if not c['ok']],
        'sources':{p.name:sha(p) for p in (repo/'lightroom-deduplicate.lrplugin').glob('*.lua')},
        'comportement':'Les réglages et coupes réels déterminent la protection vidéo ; les libellés non vides protègent indépendamment du jeu de couleurs.',
        'limites':['Un réglage vidéo inconnu ou incomplet reste à vérifier.',
            'Les tentatives de modification SDK non confirmées ont été écartées ; les coupes et réinitialisations ont été vérifiées dans l’interface native.']}
(out/'correctifs-moyennes.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps({'version':result['version'],'controles':len(checks),'echecs':result['echecs'],'bilan':str(out/'correctifs-moyennes.json')},ensure_ascii=False,indent=2))
raise SystemExit(bool(result['echecs']))
