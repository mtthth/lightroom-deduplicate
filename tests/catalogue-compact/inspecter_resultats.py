import json
from pathlib import Path
root=Path(__file__).resolve().parents[2]/'sortie'/'catalogue-compact'/'campagne'
r=json.loads((root/'doublons-chaud.json').read_text(encoding='utf-8'))
for d in r['plan']['decisions']:
    g=Path(d['garde']['path']); case=g.relative_to(root.parent/'medias').parts[0]
    print(json.dumps(dict(groupe=d['numero'],cas=case,gardee=g.name,retirees=[Path(p['path']).name for p in d['retirees']],aVerifier=d.get('aVerifier'),motsCles=(d.get('effets') or {}).get('motsCles')),ensure_ascii=False))
for p in sorted(root.glob('rafales-*.json')):
    r=json.loads(p.read_text(encoding='utf-8'))
    print(p.name,json.dumps(r.get('rafales',{}).get('bilan'),ensure_ascii=False))
