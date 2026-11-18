"""Reprend E04 avec un relevé incluant toutes les photos déplacées."""
from campagne import *
from semantique import sdk_state

CHECKS.extend(json.loads((OUT/'controles.json').read_text(encoding='utf-8')))
before=snapshot('e04-v2-avant')
r=run('e04-v2-analyse','FusionnerDoublons','E04')
d=r['plan']['decisions'][0]; chosen=d['retirees'][0]['id']
r=run('e04-v2-force','FusionnerDoublons','E04','appliquer',code='DEDUP '+r['plan']['identifiant']+' force 1:2')
after=snapshot('e04-v2-fusion')
ids=[d['garde']['id']]+[p['id'] for p in d['retirees']]
check('E04 complet : gardée choisie et exactement deux copies écartées',not trash(after['photos'][chosen]) and all(trash(after['photos'][i]) for i in ids if i!=chosen))
check('E04 complet : relevé SDK des trois photos conservé',len(r['apres']['photos'])==3)
u=run('e04-v2-undo','undo','E04')
check('E04 complet : annuler photos et exclusions',sdk_state(u['apres'])==sdk_state(r['avant']))
redo=run('e04-v2-redo','redo','E04')
check('E04 complet : rétablir photos et exclusions',sdk_state(redo['apres'])==sdk_state(r['apres']))
restored=restore('e04-v2-restaurer',r)
u=run('e04-v2-restauration-undo','undo','E04')
check('E04 complet : annuler restauration',sdk_state(u['apres'])==sdk_state(r['apres']))
redo=run('e04-v2-restauration-redo','redo','E04')
check('E04 complet : rétablir restauration',sdk_state(redo['apres'])==sdk_state(restored['apres']))
snapshot('final-complet')
