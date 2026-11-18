"""Copie de l'état initial, uniquement après fermeture propre de Lightroom."""
import hashlib
import argparse
import json
from pathlib import Path
import shutil
import sqlite3

root=Path(__file__).resolve().parents[2]/'sortie'/'catalogue-compact'
parser=argparse.ArgumentParser()
parser.add_argument('--racine',type=Path,default=root)
root=parser.parse_args().racine.resolve()
spec=json.loads((root/'manifest.json').read_text(encoding='utf-8'))
cat=Path(spec['catalogue'])
assert cat.is_file()
assert not Path(str(cat)+'.lock').exists(), 'Fermer le catalogue dans Lightroom avant la sauvegarde.'
wal=Path(str(cat)+'-wal')
assert not wal.exists() or wal.stat().st_size==0, 'Journal SQLite non vide : fermeture incomplète.'
verification=json.loads((root/'verification.json').read_text(encoding='utf-8'))
assert verification['echecs']==[], 'Vérification non terminée.'
db=sqlite3.connect(cat.as_uri()+'?mode=ro&immutable=1',uri=True)
assert db.execute('pragma quick_check').fetchall()==[('ok',)]
db.close()
dest=root/'etat-initial'
assert not (dest/'inventaire.json').exists(), 'Sauvegarde initiale déjà terminée.'
dest.mkdir(exist_ok=True)
files=[cat,cat.with_suffix('.lrcat-data'),root/'manifest.json',root/'Manifeste.lua',root/'verification.json',root/'etat-sdk.tsv',
       root/'environnement'/'lightroom-google-photos'/'photos-traitees.txt']
inventory=[]
for source in files:
    if not source.exists(): continue
    target=dest/source.name
    if source.is_dir():
        shutil.copytree(source,target,dirs_exist_ok=True)
        pairs=[(p,target/p.relative_to(source)) for p in source.rglob('*') if p.is_file()]
    else:
        shutil.copyfile(source,target)
        pairs=[(source,target)]
    for original_path,copied_path in pairs:
        with original_path.open('rb') as f: original=hashlib.file_digest(f,'sha256').hexdigest()
        with copied_path.open('rb') as f: copied=hashlib.file_digest(f,'sha256').hexdigest()
        assert original==copied
        inventory.append(dict(source=str(original_path),sauvegarde=str(copied_path.relative_to(dest)),sha256=copied,octets=copied_path.stat().st_size))
(dest/'inventaire.json').write_text(json.dumps(inventory,ensure_ascii=False,indent=2),encoding='utf-8')
(dest/'RESTAURATION.md').write_text('''# Revenir à l’état initial

Fermer Lightroom. Conserver à part l’état de test courant, puis recopier
`Deduplicate-compact.lrcat` et `Deduplicate-compact.lrcat-data` de ce dossier
dans le dossier `Deduplicate-compact/`, à leur emplacement d’origine.
Recopier `photos-traitees.txt` dans `environnement/lightroom-google-photos/`.
Conserver à part les éventuels refus de groupes et caches produits depuis.

Les médias restent dans `medias/` : leurs empreintes initiales sont dans le
manifeste. La commande TEST de restauration rétablit E01/E02 depuis les copies
`.initial` si les perturbations ont été utilisées. Rouvrir ensuite le catalogue.

La sauvegarde contient le catalogue créé par Lightroom et ses états de test.
Les contrôles de préparation ont réussi ; les tests de fusion restent à exécuter.
'''.replace('Deduplicate-compact',cat.stem),encoding='utf-8')
print(json.dumps(dict(sauvegarde=str(dest),fichiers=len(inventory),integrite='ok'),ensure_ascii=False))
