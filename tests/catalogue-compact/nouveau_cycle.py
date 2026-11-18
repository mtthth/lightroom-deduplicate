"""Prépare une copie neuve sans changer le catalogue ni le module actifs.

L'activation et les essais dans Lightroom sont une étape distincte, à réaliser
après fermeture du catalogue de travail actuellement ouvert.
"""
import datetime
import hashlib
import json
from pathlib import Path
import shutil
import sqlite3

from generer import lua


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def preparer():
    repo = Path(__file__).resolve().parents[2]
    root = repo / 'sortie/catalogue-compact'
    backup = root / 'etat-initial'
    inventory = json.loads((backup / 'inventaire.json').read_text(encoding='utf-8'))
    for item in inventory:
        path = (backup / item['sauvegarde']).resolve()
        assert path.is_relative_to(backup.resolve()), 'Chemin de sauvegarde invalide.'
        assert sha(path) == item['sha256'], f'Sauvegarde initiale altérée : {path}'
    spec = json.loads((backup / 'manifest.json').read_text(encoding='utf-8'))
    for photo in spec['photos']:
        path = Path(photo['chemin']).resolve()
        assert path.is_relative_to((root / 'medias').resolve()), 'Média hors du jeu synthétique.'
        assert sha(path) == photo['sha256'], f'Média synthétique altéré : {path}'

    stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
    execution = root / ('execution-cycle-' + stamp)
    out = root / ('campagne-cycle-' + stamp)
    execution.mkdir(exist_ok=False)
    out.mkdir(exist_ok=False)
    cat = execution / 'Deduplicate-execution.lrcat'
    shutil.copyfile(backup / 'Deduplicate-compact.lrcat', cat)
    shutil.copytree(backup / 'Deduplicate-compact.lrcat-data', cat.with_suffix('.lrcat-data'))
    assert sha(cat) == sha(backup / 'Deduplicate-compact.lrcat')
    for item in inventory:
        source = Path(item['sauvegarde'])
        if source.parts[0] == 'Deduplicate-compact.lrcat-data':
            assert sha(cat.with_suffix('.lrcat-data').joinpath(*source.parts[1:])) == item['sha256']
    with sqlite3.connect(cat.as_uri() + '?mode=ro&immutable=1', uri=True) as database:
        assert database.execute('PRAGMA quick_check').fetchall() == [('ok',)]
        entries, virtuals = database.execute(
            'SELECT count(*), sum(CASE WHEN coalesce(masterImage,0)<>0 THEN 1 ELSE 0 END) FROM Adobe_images'
        ).fetchone()
    assert (entries, virtuals) == (172, 4), 'Nombre inattendu de photos ou de copies virtuelles.'

    spec['catalogue'] = str(cat)
    spec['campagne'] = out.name
    (out / 'manifest.json').write_text(json.dumps(spec, ensure_ascii=False, indent=2), encoding='utf-8')
    (out / 'Manifeste.lua').write_text('return ' + lua(spec), encoding='utf-8')
    log = root / 'campagne/tests-cycle-complet-preparation.log'
    suites = None
    if log.exists():
        content = log.read_text(encoding='utf-8-sig')
        successes = sum(line.startswith('ok      ') for line in content.splitlines())
        assert successes == 21 and 'ÉCHEC' not in content, 'Journal des suites incomplet.'
        shutil.copyfile(log, out / log.name)
        suites = {'reussies': successes, 'journal': log.name, 'sha256': sha(log)}
    configuration = {
        'statut': 'prepare_non_active',
        'catalogue': str(cat), 'campagne': str(out),
        'etat_initial_sha256': sha(cat), 'entrees': entries, 'copies_virtuelles': virtuals,
        'scenarios': len(spec['cas']), 'medias': len(spec['photos']),
        'scenarios_lightroom_executes': 0,
        'suites_automatisees': suites,
        'integrite_sauvegarde': 'ok', 'integrite_medias': 'ok', 'integrite_sqlite': 'ok',
        'source': {p.name: sha(p) for p in (repo / 'lightroom-deduplicate.lrplugin').glob('*.lua')},
        'pilote': {p.name: sha(p) for p in Path(__file__).parent.glob('*.lua')},
        'blocage': 'Accès à la capture et à la saisie Windows indisponible.',
        'reprise': [
            'Rétablir l’accès à Windows et fermer Lightroom proprement.',
            'Archiver les états du module isolé, puis activer ce manifeste, le module actualisé et l’historique initial.',
            'Ouvrir la copie neuve et exécuter les 40 scénarios, restaurations et Annuler/Rétablir.',
        ],
    }
    (out / 'configuration.json').write_text(json.dumps(configuration, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(configuration, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    preparer()
