"""Conserve les sauvegardes des fichiers perturbés hors du dossier des médias."""
from campagne import *

destination=OUT/'perturbations'; destination.mkdir(exist_ok=True)
inventory=[]
for name in ['e01-revalidation','e02-revalidation']:
    result=json.loads((OUT/(name+'.json')).read_text(encoding='utf-8'))
    original=Path(result['request']['perturber']['path'])
    expected=BY_PATH[NORM(original)]['sha256']
    assert hashlib.file_digest(original.open('rb'),'sha256').hexdigest()==expected
    for suffix in ['initial','absent']:
        p=Path(str(original)+'.'+name+'.campagne-'+suffix)
        if p.exists():
            assert p.resolve().is_relative_to(Path(SPEC['medias']).resolve()) and p!=original
            target=destination/(name+'-'+suffix+'.bin')
            assert not target.exists()
            p.rename(target)
            inventory.append(dict(ancien_chemin=str(p),preuve=str(target),sha256=hashlib.file_digest(target.open('rb'),'sha256').hexdigest()))
(destination/'inventaire.json').write_text(json.dumps(inventory,ensure_ascii=False,indent=2),encoding='utf-8')
print(str(len(inventory))+' fichiers de preuve conservés hors des médias.')
