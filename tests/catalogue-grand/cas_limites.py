"""Séquences ciblées sur la même copie après la campagne en volume."""
from campagne import *
import shutil

def photos(state): return {p['id']:p for p in state['photos']}
def inspect(name,case):
    return run(name,'FusionnerDoublons',case)
def identical(name,r):
    check(name,r['avant']['photos']==r['apres']['photos'] and r['avant']['history']==r['apres']['history'])

def main():
    assert (OUT/'phase-volume-terminee.json').exists(),'Terminer la campagne en volume'
    checks=json.loads((OUT/'controles.json').read_text(encoding='utf-8')); CHECKS.extend(checks)
    # Chaque petit cas est aussi analysé dans son propre périmètre.
    for c in SPEC['cas'][:40]:
        if c['id'].startswith('R'): continue
        r=inspect('cible-'+c['id'],c['id'])
        identical(c['id']+' : analyse locale sans mutation',r)
        if c['id'] in ['D05','D06','D09','D10','D17','D18']:
            check(c['id']+' : variantes à vérifier',bool(r.get('plan',{}).get('decisions')) and all(d.get('aVerifier') for d in r['plan']['decisions']))
        if c['id'] in ['V01','V02','V03']:
            check(c['id']+' : vidéo vierge exacte automatique',len(r.get('plan',{}).get('decisions',[]))==1 and not r['plan']['decisions'][0].get('aVerifier'))
        if c['id']=='D13':
            kept=next(p for p in r['apres']['photos'] if not p['virtuelle'] and Path(p['path']).name=='IMG_1000.jpg')
            check('D13 : note, drapeau, titre et légende réunis',kept['rating']==5 and kept['pick']==1 and kept['texts']['title']=='Titre gardée' and bool(kept['texts']['caption']))
            check('D13 : GPS zéro préservé',kept['gps']['latitude']==0 and kept['gps']['longitude']==0)
        if c['id']=='D14':
            kept=next(p for p in r['apres']['photos'] if not p['virtuelle'] and Path(p['path']).name=='IMG_1000.jpg')
            check('D14 : mots-clés homonymes et non exporté réunis',{'Lieux / Paris','Personnes / Paris','Technique / Interne'}<={k['path'] for k in kept['keywords']})
    # Les deux copies virtuelles de la seconde image sont réellement recréées.
    preparation=run('d19-selection','prepare','D19')
    masters=[p for p in preparation['apres']['photos'] if not p['virtuelle']]
    kept=next(p for p in masters if Path(p['path']).name=='IMG_1000.jpg')
    r=run('d19-force','FusionManuelle','D19','appliquer',gardee=kept['id'])
    # Renouveler la portée après la création des copies, sans conserver la liste initiale du SDK.
    refreshed=run('d19-apres-selection','prepare','D19')
    r['apres']=refreshed['apres']
    before=photos(r['avant']); after=photos(r['apres']); created=[p for i,p in after.items() if i not in before]
    check('D19 : deux copies virtuelles recréées',len(created)==2 and all(p['virtuelle'] for p in created))
    originals=[p for p in before.values() if p['virtuelle'] and NORM(p['path'])!=NORM(kept['path'])]
    keys=['develop','copyName','texts','rating','pick','gps','keywords','collections']
    for p in originals:
        check('D19 : tous les réglages et métadonnées de la copie '+str(p['id']),any(all(x.get(k)==p.get(k) for k in keys) for x in created))
    restore('d19-restaurer',r)
    r=run('d20-selection','prepare','D20')
    kept=next(p for p in r['apres']['photos'] if not p['virtuelle'] and Path(p['path']).name=='IMG_1000.jpg')
    r=run('d20-force','FusionManuelle','D20','appliquer',gardee=kept['id'])
    p=photos(r['apres'])[kept['id']]
    check('D20 : gardée sortie des deux retraits',not any(c in p['collections'] for c in ['Doublons à retirer','Rafales à retirer']))
    check('D20 : gardée sortie de l’exclusion externe',not any(NORM(kept['path']) in NORM(line) for line in r['apres']['history'].splitlines() if not line.startswith('#')))
    restore('d20-restaurer',r)
    # Refus d'un sous-ensemble retrouvé dans un groupe plus grand.
    r=run('e04-selection','prepare','E04')
    ids=[p['id'] for p in r['apres']['photos'] if not p['virtuelle']][:2]
    subset=run('e04-partiel','FusionnerDoublons','E04',ids=ids)
    check('E04 : sélection partielle de deux photos',len(subset['plan']['decisions'])==1 and len(subset['plan']['decisions'][0]['retirees'])==1)
    r=run('e04-refuser','FusionnerDoublons','E04','appliquer',ids=ids,code='DEDUP '+subset['plan']['identifiant']+' non 1')
    identical('E04 : refus sans mutation des photos',r)
    larger=inspect('e04-refus-respecte','E04')
    check('E04 : refus respecté dans le groupe de trois',len(larger['plan']['decisions'])==1 and bool(larger['plan']['decisions'][0].get('aVerifier')))
    force=run('e04-force','FusionnerDoublons','E04','appliquer',code='DEDUP '+larger['plan']['identifiant']+' force 1:2')
    d=larger['plan']['decisions'][0]; chosen=d['retirees'][0]['id']
    check('E04 : choix explicite de la deuxième copie',not trash(photos(force['apres'])[chosen]) and sum(trash(p) for p in force['apres']['photos'])==2)
    u=run('e04-undo','undo','E04'); check('E04 : annuler photos et historique',u['apres']==force['avant'])
    redo=run('e04-redo','redo','E04'); check('E04 : rétablir photos et historique',redo['apres']==force['apres'])
    restored=restore('e04-restaurer',force)
    u=run('e04-restauration-undo','undo','E04')
    check('E04 : annuler la restauration et son historique',u['apres']==force['apres'])
    redo=run('e04-restauration-redo','redo','E04')
    check('E04 : rétablir la restauration et son historique',redo['apres']==restored['apres'])
    for case in ['E01','E02']:
        e=next(p for p in SPEC['photos'] if p['cas']==case)
        path=Path(e['chemin']); name=case.lower()+'-revalidation'
        backupfile=Path(str(path)+'.'+name+'.campagne-initial')
        absent=Path(str(path)+'.'+name+'.campagne-absent')
        try:
            r=run(name,'FusionnerDoublons',case,'appliquer',perturber=e['id'],**({'manquant':True} if case=='E01' else {}))
            identical(case+' : revalidation bloque toute mutation',r)
            check(case+' : message explicite de revalidation',any('Fusion interrompue avant toute modification' in d.get('text','') for d in r.get('dialogs',[])))
        finally:
            if backupfile.exists(): shutil.copyfile(backupfile,path)
            elif absent.exists(): shutil.copyfile(absent,path)
        check(case+' : fichier physiquement restauré',hashlib.file_digest(path.open('rb'),'sha256').hexdigest()==e['sha256'])
    # Protection du libellé personnalisé hors jeu de couleurs.
    r=run('r04-selection','prepare','R04')
    original=json.loads((OUT/'global-rafales-analyse.json').read_text(encoding='utf-8'))
    ident=next(f['id'] for burst in original['rafales']['rafales'] for frame in burst['cadres']
               for f in frame['fichiers'] if cid(f['path'])=='R04' and frame['decision']=='retirer')
    run('r04-libelle','setLabel','R04','appliquer',ids=[ident],label='À vérifier')
    r=run('r04-reduire','ReduireRafales','R04','appliquer')
    check('R04 : libellé personnalisé protège la photo',not trash(photos(r['apres'])[ident],'Rafales'))
    check('R04 : cadre auparavant écartable explicitement protégé',any(frame['decision']=='protégé' for burst in r['rafales']['rafales'] for frame in burst['cadres'] if any(f['id']==ident for f in frame['fichiers'])))
    restore('r04-restaurer',r)
    for c in ['D05','P001']:
        r=inspect(c.lower()+'-avant-force',c)
        check(c+' : toutes les variantes à vérifier',bool(r['plan']['decisions']) and all(d.get('aVerifier') for d in r['plan']['decisions']))
        if r['plan']['decisions']:
            force=run(c.lower()+'-force','FusionnerDoublons',c,'appliquer',code='DEDUP '+r['plan']['identifiant']+' force 1')
            check(c+' : forçage réellement appliqué',any(d.get('title')=='Doublons fusionnés' for d in force.get('dialogs',[])))
            restore(c.lower()+'-restaurer',force)
    check('10 000 médias aux empreintes originales',all(hashlib.file_digest(Path(p['chemin']).open('rb'),'sha256').hexdigest()==p['sha256'] for p in SPEC['photos']))
    inventory=json.loads((ROOT/'etat-initial/inventaire.json').read_text(encoding='utf-8'))
    check('Sauvegarde initiale intégralement préservée',all(hashlib.file_digest((ROOT/'etat-initial'/p['sauvegarde']).open('rb'),'sha256').hexdigest()==p['sha256'] for p in inventory))
    snapshot('final')
    (OUT/'bilan.json').write_text(json.dumps(dict(controles=len(CHECKS),echecs=[c for c in CHECKS if not c['ok']],version='26.11.8',suites_depot=21),ensure_ascii=False,indent=2),encoding='utf-8')

if __name__=='__main__': main()
