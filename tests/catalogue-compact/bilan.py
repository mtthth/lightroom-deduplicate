"""Vérifie les preuves de la campagne réelle, sans écrire dans Lightroom."""
import hashlib
import json
from pathlib import Path

root=Path(__file__).resolve().parents[2]/'sortie'/'catalogue-compact'
out=root/'campagne'
def load(name): return json.loads((out/(name+'.json')).read_text(encoding='utf-8'))
def photos(state): return {p['id']:p for p in state['photos']}
def case(state,name): return [p for p in state['photos'] if '/'+name+'/' in p['path'].replace('\\','/')]
checks=[]
def check(name,value): checks.append({'controle':name,'ok':bool(value)})

initial=json.loads((root/'verification.json').read_text(encoding='utf-8'))
check('Préparation : 889 contrôles réussis',initial['controles']==889 and not initial['echecs'])
for name in ['securite-modifie','securite-manquant']:
    r=load(name)
    check(name+' : aucune écriture catalogue/historique',r['avant']['photos']==r['apres']['photos'] and r['avant']['history']==r['apres']['history'])
    check(name+' : erreur explicite de revalidation',any('Fusion interrompue avant toute modification' in d.get('text','') for d in r['dialogs']))
r=load('fusion-collections'); undo=load('annulation-collections'); redo=load('retablissement-collections')
check('Annuler D15 par le menu : toutes les photos rétablies',r['avant']['photos']==undo['apres']['photos'])
check('Reproduction B06 sur D15 : exclusion persistante après Annuler',r['avant']['history']!=undo['apres']['history'] and '\\D15\\IMG_1000-2.jpg\t' in undo['apres']['history'])
check('Rétablir D15 par le menu : scénario et historique rétablis',case(r['apres'],'D15')==case(redo['apres'],'D15') and r['apres']['history']==redo['apres']['history'])
restored=photos(load('restauration-collections')['apres'])
check('Restauration D15 : appartenances d’origine retrouvées',all(set(p['collections'])<=set(restored[p['id']]['collections']) for p in case(r['avant'],'D15')))
check('Restauration D15 : sortie de la collection de retrait',all('Doublons à retirer' not in restored[p['id']]['collections'] for p in case(r['avant'],'D15')))
r=load('force-virtuelles'); before=photos(r['avant']); after=photos(r['apres'])
created=[p for i,p in after.items() if i not in before]
check('D19 : deux copies virtuelles recréées',len(created)==2 and all(p['virtuelle'] for p in created))
for old_id in [28109,28156]:
    old=before[old_id]
    check('D19 : réglages, nom, métadonnées et collections de '+str(old_id),any(p['develop']==old['develop'] and all(p.get(k)==old.get(k) for k in ['copyName','texts','rating','pick','gps','keywords','collections']) for p in created))
r=load('gardee-hors-retrait'); kept=photos(r['apres'])[9406]
check('D20 : gardée sortie des deux collections de retrait',all(c not in kept['collections'] for c in ['Doublons à retirer','Rafales à retirer']))
check('D20 : gardée sortie de l’historique',not any('\\D20\\IMG_1000.jpg\t' in s for s in r['apres']['history'].splitlines()))
r=load('fusion-metadonnees'); kept=photos(r['apres'])[6907]
check('D13 : priorité note/drapeau et GPS zéro conservé',kept['rating']==5 and kept['pick']==1 and kept['gps']==photos(r['avant'])[6907]['gps'])
check('D13 : titre conservé, légende complétée',kept['texts']['title']=='Titre gardée' and bool(kept['texts']['caption']))
r=load('refus-enregistre')
check('E04 : refus sans mutation du catalogue',r['avant']['photos']==r['apres']['photos'])
check('E04 : refus respecté à l’analyse suivante',bool(load('refus-respecte')['plan']['decisions'][0]['aVerifier']))
p=photos(load('refus-force')['apres'])
check('E04 : forçage avec choix de la deuxième copie',all('Doublons à retirer' in p[i]['collections'] for i in [26847,27181]) and 'Doublons à retirer' not in p[27017]['collections'])
check('R04 : restauration après réduction',case(load('retrait-libelle-personnalise')['avant'],'R04')==case(load('restauration-rafale')['apres'],'R04'))

bugs=[]
def bug(id,priority,scenario,title,source,evidence,actual,expected,nature='défaut'):
    bugs.append(dict(id=id,priorite=priority,cas=scenario,titre=title,nature=nature,source=source,preuves=evidence,observe=actual,attendu=expected))
r=load('fusion-mots-homonymes'); p=photos(r['apres'])[7399]
check('Reproduction B01 : mot-clé hiérarchique perdu',{'Lieux / Paris','Technique / Interne'}=={k['path'] for k in p['keywords']} and any(k['path']=='Personnes / Paris' for k in photos(r['avant'])[7573]['keywords']))
bug('B01','P1','D14','Mot-clé homonyme non transféré','lightroom-deduplicate.lrplugin/Doublons.lua:330',['fusion-mots-homonymes.json'],
    'Lieux / Paris est conservé, Personnes / Paris reste uniquement sur la copie écartée ; Technique / Interne est transféré.',
    'Réunir les objets mots-clés distincts, même si leurs noms terminaux sont identiques.')
r=load('rafales-deux-appareils')['rafales']
check('Reproduction B02 : deux dossiers mélangés',r['bilan']['rafales']==1 and r['bilan']['cadres']==16 and len({Path(f['path']).parent.name for c in r['rafales'][0]['cadres'] for f in c['fichiers']})==2)
bug('B02','P1','R10','Rafales simultanées de dossiers distincts mélangées','lightroom-deduplicate.lrplugin/Rafales.lua:143',['rafales-deux-appareils.json'],
    'Une rafale de 16 cadres, 4 gardés et 12 proposés au retrait. Des scènes différentes concourent dans le même bloc.',
    'Deux rafales indépendantes de 8 cadres. La séparation présente dans la clé des cadres doit aussi borner les rafales.')
r=load('faux-positif-detail'); m=load('mesures-detail')
check('Reproduction B03 : images différentes fusionnées automatiquement',not r['plan']['decisions'][0].get('aVerifier') and any('Doublons à retirer' in p['collections'] for p in case(r['apres'],'D09')) and m['pixels_differents']>0)
bug('B03','P1','D09','Petit détail significatif accepté comme doublon','lightroom-deduplicate.lrplugin/Similitude.lua:61',['faux-positif-detail.json','mesures-detail.json'],
    'L’ajout du chiffre 7 à 24 px change 378 pixels ; l’écart moyen des signatures 16 × 16 est seulement 0,0143. Fusion appliquée sans forçage.',
    'Conserver une version modifiée ou demander une vérification explicite. La signature réduite ne garantit pas l’absence de retouche locale.', 'limite de la comparaison approximative')
r=load('diagnostic-videos'); vids=[p for p in r['apres']['photos'] if p['isVideo']]; adjusted={p['id'] for p in r['retouchees']}
ds=[d for d in load('doublons-chaud')['plan']['decisions'] if '/V0' in d['garde']['path'].replace('\\','/')]
check('Reproduction B04 : vidéos vierges classées retouchées',len(vids)==8 and all(p['id'] in adjusted for p in vids) and len(ds)==3 and all(d['aVerifier']=='plusieurs copies retouchées' for d in ds))
bug('B04','P2','V01–V03','Copies vidéo exactes bloquées comme retouchées','lightroom-deduplicate.lrplugin/FusionnerDoublons.lua:447',['diagnostic-videos.json','doublons-chaud.json'],
    'Dans Lightroom 15.6, hasAdjustments renvoie les 8 MP4 jamais retouchés ; les trois groupes exacts restent à vérifier.',
    'Permettre le comportement annoncé pour les vidéos exactes tout en protégeant les véritables coupes/réglages.', 'compatibilité avec le résultat du SDK Lightroom')
p=photos(load('retrait-libelle-personnalise')['apres'])[13961]
check('Reproduction B05 : libellé personnalisé ignoré',p['texts']['label']=='À vérifier' and p['colorNameForLabel']=='white' and 'Rafales à retirer' in p['collections'])
bug('B05','P2','R04 + libellé personnalisé','Libellé existant non protecteur hors du jeu de couleurs actif','lightroom-deduplicate.lrplugin/ReduireRafales.lua:124',['libelle-personnalise.json','rafale-libelle-personnalise.json','retrait-libelle-personnalise.json'],
    'La photo 13961 porte « À vérifier », exposé comme white par colorNameForLabel. Elle est effectivement mise dans Rafales à retirer.',
    'Protéger les libellés non vides, conformément à la documentation « avec drapeau ou libellé ».')
r=load('refus-force'); z=load('annulation-E04-synchronisee')
a=photos(r['avant']); b=photos(z['apres'])
check('Reproduction B06 sur E04 : catalogue rétabli, exclusions persistantes même après synchronisation',
    all(all(p.get(k)==b[i].get(k) for k in p if k!='develop') for i,p in a.items())
    and r['avant']['history']!=z['apres']['history']
    and all('\\E04\\'+name+'\t' in z['apres']['history'] for name in ['IMG_1000.jpg','IMG_1000-3.jpg']))
bug('B06','P1','D15 et E04','Annuler rétablit le catalogue mais conserve les exclusions externes','lightroom-deduplicate.lrplugin/Annulation.lua:138',
    ['fusion-collections.json','annulation-collections.json','refus-force.json','annulation-E04-stable.json','annulation-E04-synchronisee.json'],
    'Après Annuler Fusionner les doublons dans le menu natif, les appartenances et métadonnées sont rétablies, mais les chemins annulés restent dans photos-traitees.txt. Une synchronisation explicite ne les retire pas.',
    'Retirer également les exclusions créées par la fusion annulée, comme annoncé dans le message de fin. Sinon les recherches ultérieures continuent de les ignorer.')

spec=json.loads((root/'manifest.json').read_text(encoding='utf-8'))
def sha(path):
    with path.open('rb') as f: return hashlib.file_digest(f,'sha256').hexdigest()
check('168 médias restaurés aux SHA-256 initiaux',all(Path(p['chemin']).exists() and sha(Path(p['chemin']))==p['sha256'] for p in spec['photos']))
inventory=json.loads((root/'etat-initial/inventaire.json').read_text(encoding='utf-8'))
check('Sauvegarde initiale inchangée',all(sha(root/'etat-initial'/e['sauvegarde'])==e['sha256'] for e in inventory))
log=(out/'tests-depot.log').read_text(encoding='utf-8-sig')
check('17 suites du dépôt réussies',sum(line.startswith('ok      ') for line in log.splitlines())==17 and 'ÉCHEC' not in log)
bilan={'date':'2026-11-07','lightroom':'15.6 (202609251514-f839cde9)','catalogue_initial':str(root/'Deduplicate-compact/Deduplicate-compact.lrcat'),
    'catalogue_travail':spec['catalogue'],'scenarios':40,'medias':168,'entrees_initiales':172,'entrees_apres_recreation':174,
    'methode':'Commandes réelles et SDK Lightroom ; dialogues pilotés. Annuler/rétablir D15 par les menus natifs.',
    'anomalies':bugs,'controles':checks,'echecs':[c for c in checks if not c['ok']],
    'limites':['Publications et masques IA non préconfigurés.',
        'R10 : défaut observé dans le plan réel, sans appliquer le retrait.',
        'B03 documente un faux positif réel ; aucun seuil universel ne peut garantir son absence.',
        'Tentatives de raccourcis D13 écartées : action clavier non reçue. Les menus natifs D15 et E04 ont servi aux vérifications Undo/Redo.',
        'Redo comparé sur D15 et l’historique : après redémarrage Lightroom a normalisé des champs de développement d’autres photos.',
        'Aucun correctif au module de production ; anomalies reproductibles avec le code actuel.']}
(out/'bilan.json').write_text(json.dumps(bilan,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps({'anomalies':len(bugs),'controles':len(checks),'echecs':bilan['echecs'],'bilan':str(out/'bilan.json')},ensure_ascii=False,indent=2))
raise SystemExit(bool(bilan['echecs']))
