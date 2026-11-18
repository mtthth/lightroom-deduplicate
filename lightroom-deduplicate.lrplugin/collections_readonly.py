"""Snapshot des appartenances : SQLite mode=ro + query_only, aucune écriture catalogue."""
import pathlib
import sqlite3
import sys
import time

REGULAR = 'com.adobe.ag.library.collection'
GROUP = 'com.adobe.ag.library.group'
SMART = 'com.adobe.ag.library.smart_collection'


def snapshot(catalog, ids):
    ids = list(dict.fromkeys(int(i) for i in ids))
    if any(i <= 0 for i in ids):
        raise ValueError('Identifiant de photo invalide')
    start = time.monotonic()
    db = sqlite3.connect(pathlib.Path(catalog).resolve().as_uri() + '?mode=ro', uri=True, timeout=3)
    try:
        db.execute('PRAGMA query_only=ON')
        db.set_progress_handler(lambda: int(time.monotonic() - start > 15), 10000)
        db.execute('BEGIN')
        # Les noms des tables/colonnes font partie du contrat vérifié ici. Une version
        # inconnue provoque une erreur, jamais un résultat partiel considéré comme vide.
        collections = {r[0]: r[1:] for r in db.execute(
            'SELECT id_local,name,parent,creationId,systemOnly FROM AgLibraryCollection')}
        links, published, found = [], set(), set()
        for offset in range(0, len(ids), 400):
            batch = ids[offset:offset + 400]
            marks = ','.join('?' for _ in batch)
            found.update(r[0] for r in db.execute(
                f'SELECT id_local FROM Adobe_images WHERE id_local IN ({marks})', batch))
            for image, cid in db.execute(
                f'SELECT image,collection FROM AgLibraryCollectionImage WHERE image IN ({marks})', batch):
                if cid not in collections:
                    raise ValueError('Collection manquante : ' + str(cid))
                name, parent, kind, system = collections[cid]
                if kind == REGULAR and not system:
                    links.append((image, cid))
                elif not system and kind != SMART:
                    raise ValueError('Type de collection inattendu : ' + str(kind))
            for image, kind in db.execute(
                'SELECT ci.image,c.creationId FROM AgLibraryPublishedCollectionImage ci '
                'LEFT JOIN AgLibraryPublishedCollection c ON c.id_local=ci.collection '
                f'WHERE ci.image IN ({marks})', batch):
                if kind.startswith('com.adobe.ag.library.collection.published'):
                    published.add(image)
                elif kind != 'com.adobe.ag.library.smart_collection.published':
                    raise ValueError('Type de publication inconnu : ' + str(kind))
        if found != set(ids):
            raise ValueError('Photos absentes du catalogue : ' + str(sorted(set(ids) - found)))
        needed = set()
        for _, cid in links:
            path = set()
            while cid:
                if cid in path or len(path) >= 100:
                    raise ValueError('Cycle ou hiérarchie trop profonde')
                path.add(cid)
                if cid not in collections:
                    raise ValueError('Parent de collection manquant : ' + str(cid))
                name, parent, kind, system = collections[cid]
                if kind not in (REGULAR, GROUP) or system:
                    raise ValueError('Hiérarchie de collections non prise en charge')
                if len(path) > 1 and kind != GROUP:
                    raise ValueError('Le parent doit être un ensemble de collections')
                needed.add(cid)
                cid = parent
        rows = ['LRDC1']
        rows += [f'P\t{i}\t{int(i in published)}' for i in ids]
        for cid in sorted(needed):
            name, parent, _, _ = collections[cid]
            rows.append(f'C\t{cid}\t{parent or 0}\t{name.encode("utf-8").hex()}')
        rows += [f'L\t{image}\t{cid}' for image, cid in links]
        rows.append(f'END\t{len(ids)}\t{len(needed)}\t{len(links)}')
        return '\n'.join(rows) + '\n'
    finally:
        db.close()


def main(request, output):
    try:
        lines = pathlib.Path(request).read_text(encoding='utf-8').splitlines()
        result = snapshot(lines[0], lines[1:])
    except Exception as exc:
        result = 'ERROR\t' + str(exc).encode('utf-8').hex() + '\n'
    pathlib.Path(output).write_bytes(result.encode('ascii'))
    return int(result.startswith('ERROR'))


if __name__ == '__main__':
    sys.exit(main(*sys.argv[1:]))
