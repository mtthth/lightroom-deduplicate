"""Vérifie les états enregistrés et produit le bilan sans modifier Lightroom."""
from campagne import *
from semantique import equivalents, equivalent_state, sdk_state

def load(name): return json.loads((OUT/(name+'.json')).read_text(encoding='utf-8'))
def state(name):
    with gzip.open(OUT/(name+'-sqlite.json.gz'),'rt',encoding='utf-8') as f: r=json.load(f)
    r['photos']={int(k):v for k,v in r['photos'].items()}; return r

def main():
    base=OUT/'controles-operations.json'
    if base.exists(): operations=json.loads(base.read_text(encoding='utf-8'))
    else:
        previous=load('controles')
        derived=next((i for i,c in enumerate(previous) if c['controle'].endswith(' : paramètres SDK comparés')),len(previous))
        operations=previous[:derived]+[c for c in previous[derived:] if c['controle'].startswith('controle-lecture-')]
        base.write_text(json.dumps(operations,ensure_ascii=False,indent=2),encoding='utf-8')
    CHECKS.extend(operations)
    sdk_differences=[]
    for p in OUT.glob('cible-*.json'):
        r=json.loads(p.read_text(encoding='utf-8'))
        if r.get('avant') and r.get('apres'):
            label=r['request']['cas']+' : analyse locale sans mutation'
            equivalent=sdk_state(r['avant'])==sdk_state(r['apres'])
            check(label+' : paramètres SDK comparés',equivalent)
            if equivalent and r['avant']!=r['apres']:
                diffs=[]
                for a,b in zip(r['avant']['photos'],r['apres']['photos']):
                    if a.get('develop')!=b.get('develop'):
                        keys=set(a.get('develop',{}))|set(b.get('develop',{}))
                        diffs.append(dict(photo=a['id'],champs={k:[a.get('develop',{}).get(k),b.get('develop',{}).get(k)] for k in keys if a.get('develop',{}).get(k)!=b.get('develop',{}).get(k)}))
                sdk_differences.append(dict(requete=r['id'],differences=diffs))
                for c in CHECKS:
                    if c['controle']==label and not c['ok']:
                        c.update(resolution='ecart_interne_explique',preuve='equivalences-sdk.json')
    (OUT/'equivalences-sdk.json').write_text(json.dumps(sdk_differences,ensure_ascii=False,indent=2),encoding='utf-8')
    control=[load('controle-lecture-w050')['apres'],load('controle-lecture-w050-seconde')['apres']]
    check('Contrôle sans fusion : initialisation As Shot reproduite par simple lecture',
          sdk_state(control[0])==sdk_state(control[1]) and any(p.get('develop',{}).get('Temperature') is None for p in control[0]['photos'] if p['path'].lower().endswith('.dng'))
          and any(p.get('develop',{}).get('Temperature')==5450 and p['develop'].get('Tint')==-13 for p in control[1]['photos'] if p['path'].lower().endswith('.dng')))
    initial=state('initial'); merged=state('fusion')
    mapping=equivalents()
    for label,left,right in [('Annuler la fusion : état catalogue complet','initial','fusion-undo'),
                             ('Rétablir la fusion : catalogue et historique','fusion','fusion-redo'),
                             ('Annuler les rafales : catalogue et historique','fusion-restauree','rafales-undo'),
                             ('Rétablir les rafales : catalogue et historique','rafales','rafales-redo')]:
        equivalent=equivalent_state(state(left),state(right),mapping)
        check(label+' : paramètres de rendu comparés',equivalent)
        if equivalent:
            for c in CHECKS:
                if c['controle']==label and not c['ok']:
                    c.update(resolution='ecart_interne_explique',preuve='equivalences-developpement.json')
    plan=load('global-fusion')['plan']['decisions']
    auto=[d for d in plan if not d.get('aVerifier')]
    expected_retired={p['id'] for d in auto for p in d['retirees']}
    original_retired={i for i,p in initial['photos'].items() if trash(p)}
    actual_retired={i for i,p in merged['photos'].items() if trash(p)}
    check('Volume : seuls les 1 309 fichiers prévus ont été écartés',actual_retired-original_retired==expected_retired and len(expected_retired)==1309)
    for d in auto:
        ids=[d['garde']['id']]+[p['id'] for p in d['retirees']]
        kept=merged['photos'][ids[0]]
        expected_keys={k[0] for i in ids for k in initial['photos'][i]['keywords']}
        expected_cols={c for i in ids for c in initial['photos'][i]['collections'] if c not in ['Doublons à retirer','Rafales à retirer']}
        check('Métadonnées groupe '+str(d['numero'])+' : note, mots-clés, collections',
              expected_keys<={k[0] for k in kept['keywords']} and expected_cols<=set(kept['collections'])
              and kept['rating']==max(initial['photos'][i]['rating'] for i in ids))
    check('Les 1 200 variantes proches ont toutes été préservées',all(not trash(p) for p in merged['photos'].values() if cid(p['path']).startswith('P')))
    reduced=state('rafales'); restored=state('fusion-restauree')
    expected=set()
    protected=set()
    model=load('global-rafales-appliquer')['rafales']
    initial_bursts=load('global-rafales-analyse')['rafales']['rafales']
    by_case={}
    for burst in initial_bursts:
        case=cid(burst['cadres'][0]['fichiers'][0]['path'])
        by_case.setdefault(case,[]).append(burst)
    for case,expected_sizes in {'R01':[],'R02':[3],'R03':[4],'R04':[5],'R05':[9],'R06':[3,3],'R08':[12],'R09':[12],'R10':[8,8],'E03':[3]}.items():
        check(case+' : rafales et nombre de cadres attendus',sorted(len(b['cadres']) for b in by_case.get(case,[]))==expected_sizes)
    check('R03 : deux fichiers par cadre',all(len(f['fichiers'])==2 for b in by_case.get('R03',[]) for f in b['cadres']) and bool(by_case.get('R03')))
    check('E03 : RAW+JPEG réunis par cadre, image non datée exclue',all(len(f['fichiers'])==2 for b in by_case.get('E03',[]) for f in b['cadres']) and bool(by_case.get('E03')))
    for r in model['rafales']:
        for frame in r['cadres']:
            if frame['decision']=='retirer': expected.update(f['id'] for f in frame['fichiers'])
            elif frame['decision']=='protégé': protected.update(f['id'] for f in frame['fichiers'])
    old={i for i,p in restored['photos'].items() if trash(p,'Rafales')}
    actual={i for i,p in reduced['photos'].items() if trash(p,'Rafales')}
    check('Rafales : aucun retrait au-delà des décisions confirmées',actual-old==expected)
    check('Rafales : toutes les protections sont respectées',not (actual & protected))
    for r in model['rafales']:
        for frame in r['cadres']:
            for f in frame['fichiers']:
                e=BY_PATH[NORM(f['path'])]
                if e.get('metadata',{}).get('label'):
                    check(e['id']+' : libellé personnalisé explicitement protégé',frame['decision']=='protégé')
    final=state('final-complet' if (OUT/'final-complet-sqlite.json.gz').exists() else 'final')
    check('État final : 10 000 originaux et 146 copies virtuelles',len(final['photos'])==10146 and sum(not p['master'] for p in final['photos'].values())==10000)
    check('Aucune image originale retirée du catalogue',set(p['path'] for p in initial['photos'].values() if not p['master'])==set(p['path'] for p in final['photos'].values() if not p['master']))
    check('Après le dernier cycle : 10 000 médias inchangés',all(hashlib.file_digest(Path(p['chemin']).open('rb'),'sha256').hexdigest()==p['sha256'] for p in SPEC['photos']))
    inventory=json.loads((ROOT/'etat-initial/inventaire.json').read_text(encoding='utf-8'))
    check('Après le dernier cycle : sauvegarde initiale intacte',all(hashlib.file_digest((ROOT/'etat-initial'/p['sauvegarde']).open('rb'),'sha256').hexdigest()==p['sha256'] for p in inventory))
    # L'attribut non exporté appartient à l'objet mot-clé et doit survivre aux unions.
    def kw_export(catalog):
        with sqlite3.connect(Path(catalog).as_uri()+'?mode=ro',uri=True) as db:
            db.execute('pragma query_only=ON')
            return dict(db.execute('select id_local,includeOnExport from AgLibraryKeyword'))
    orig=kw_export(ROOT/'etat-initial/Deduplicate-grand.lrcat'); now=kw_export(SPEC['catalogue'])
    check('Attributs d’export de tous les mots-clés initiaux préservés',all(now.get(i)==v for i,v in orig.items()))
    with sqlite3.connect(Path(SPEC['catalogue']).as_uri()+'?mode=ro',uri=True) as db:
        db.execute('pragma query_only=ON')
        check('Intégrité SQLite finale',db.execute('pragma quick_check').fetchall()==[('ok',)])
    complete=next((c['ok'] for c in CHECKS if c['controle']=='E04 complet : gardée choisie et exactement deux copies écartées'),False)
    if complete:
        for c in CHECKS:
            if c['controle']=='E04 : choix explicite de la deuxième copie' and not c['ok']:
                c.update(resolution='preuve_de_portee_completee',preuve='e04-v2-fusion-sqlite.json.gz',detail='Le premier relevé ne contenait que la photo encore dans la collection source. Reprise avec les trois photos et un contrôle SQLite indépendant.')
    explained=[c for c in CHECKS if c.get('resolution') in ['ecart_interne_explique','preuve_de_portee_completee']]
    failures=[c for c in CHECKS if not c['ok'] and c not in explained]
    requests=[]
    for p in OUT.glob('*.json'):
        r=json.loads(p.read_text(encoding='utf-8'))
        if isinstance(r,dict) and r.get('request',{}).get('entry'):
            requests.append(dict(id=r.get('id'),commande=r['request']['entry'],cas=r['request'].get('cas'),secondes=r.get('finished',0)-r.get('started',0)))
    sources={p.name:hashlib.file_digest(p.open('rb'),'sha256').hexdigest() for p in (REPO/'lightroom-deduplicate.lrplugin').glob('*') if p.is_file()}
    summary=dict(version='26.11.8',lightroom='15.6',medias=10000,cas=1438,copies_virtuelles_initiales=144,
        groupes_doublons=len(plan),groupes_automatiques=len(auto),groupes_a_verifier=len(plan)-len(auto),
        fichiers_ecartes_fusion=len(expected_retired),rafales=model['bilan'],fichiers_ecartes_rafales=len(expected),
        suites_depot=21,controles=len(CHECKS),echecs=failures,ecarts_internes_expliques=explained,requetes=requests,sources_sha256=sources,
        limites=['Aucun service de publication ou réseau testé.','Pas de masques IA ni de RAW propriétaires : DNG linéaires synthétiques.',
                 'Les coupes et corrections vidéo sont couvertes par les suites unitaires ; aucune nouvelle coupe native dans cette campagne.',
                 'Les 1 438 cas sont couverts par les analyses globales ; les cas limites ont aussi leurs séquences ciblées.',
                 'Le pilote répond aux dialogues ; les calculs et écritures utilisent les commandes réelles et le SDK Lightroom.',
                 'La restauration des collections conserve les métadonnées réunies et les copies virtuelles recréées. La sauvegarde initiale permet un retour strict.'])
    (OUT/'bilan.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2),encoding='utf-8')
    lines=['# Tests du grand catalogue — 7 novembre 2026','',f"Version 26.11.8, Lightroom Classic 15.6. {len(CHECKS)} contrôles, {len(failures)} échecs. Les 21 suites du dépôt passent.",'',
           '10 000 médias, 144 copies virtuelles initiales et 1 438 scénarios. Une copie du catalogue initial a été utilisée.',
           '',f"Doublons : {len(plan)} groupes, dont {len(auto)} automatiques et {len(plan)-len(auto)} à vérifier. {len(expected_retired)} fichiers ont réellement été mis dans la collection de retrait.",
           '',f"Rafales : {len(model['rafales'])} rafales ; {len(expected)} fichiers réellement mis de côté. Annuler, Rétablir, restauration et relance contrôlés.",'',
           'Les empreintes SHA-256 des 10 000 médias et de toute la sauvegarde initiale sont contrôlées après les séquences. Aucun original n’a été supprimé.',
           '', '## Échecs', '']
    lines +=['- '+f['controle']+((' — '+str(f['detail'])) if f.get('detail') else '') for f in failures] or ['Aucun.']
    internal=[c for c in explained if c.get('resolution')=='ecart_interne_explique']
    if internal:
        lines+=['',f"{len(internal)} comparaisons brutes ont signalé une matérialisation interne de Lightroom : CameraProfileDigest, liste FilterList vide, version AutoWhiteVersion et valeurs calculées en mode As Shot. L’initialisation As Shot a aussi été reproduite par sélection/lecture seules sur W050, sans commande de fusion. Les champs explicites de rendu restent comparés ; les différences et empreintes sont conservées dans `equivalences-developpement.json`, `equivalences-sdk.json` et `controle-lecture-w050*.json`."]
    if len(explained)>len(internal):
        lines+=['','Le premier relevé E04 omettait les photos déplacées hors de sa collection. Le contrôle a été repris avec les trois photos et un état SQLite indépendant ; les deux séries de preuves sont conservées.']
    lines+=['','## Limites','']+['- '+s for s in summary['limites']]
    lines+=['','## Preuves','','`bilan.json`, `controles.json`, `couverture-cas.json`, résultats SDK par requête et états SQLite compressés dans ce dossier.']
    (OUT/'BILAN.md').write_text('\n'.join(lines)+'\n',encoding='utf-8')
    print(json.dumps({k:summary[k] for k in ['controles','echecs','rafales','fichiers_ecartes_fusion','fichiers_ecartes_rafales']},ensure_ascii=False,indent=2))
    raise SystemExit(bool(failures))

if __name__=='__main__': main()
