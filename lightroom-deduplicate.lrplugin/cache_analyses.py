"""Cache SQLite indépendant du catalogue. Ne modifie jamais les fichiers source."""
import hashlib
import os
import pathlib
import re
import sqlite3
import stat
import sys

KINDS = {'F', 'G', 'S'}


def stamp(path):
    try:
        s = os.stat(path)
        if not stat.S_ISREG(s.st_mode):
            return None
        return ':'.join(map(str, (s.st_size, s.st_mtime_ns, s.st_ctime_ns, s.st_dev, s.st_ino)))
    except OSError:
        return None


def valid(kind, payload):
    if kind == 'F':
        return bool(re.fullmatch(rb'(?:jpeg|brut|mdat):[a-fA-F0-9]{32}|gros:\d+:[a-fA-F0-9]{64}', payload))
    if kind == 'G':
        return bool(re.fullmatch(rb'complet:[a-fA-F0-9]{64}', payload))
    m = re.match(rb'([1-9]\d*),([1-9]\d*):', payload)
    return bool(m and len(payload[m.end():]) == 768)


def version(kind, plugin, magick):
    source = plugin / ('Vignettes.lua' if kind == 'S' else 'Empreintes.lua')
    v = hashlib.sha256(source.read_bytes()).hexdigest()
    if kind == 'S':
        v += '|' + magick + '|' + str(stamp(magick))
    return 'cache-v1|' + v


def execute(request):
    lines = request.splitlines()
    if len(lines) < 7 or lines[0] != 'LRCACHE1' or lines[-1] != 'END':
        raise ValueError('Requête de cache tronquée')
    mode, kind = lines[1].split('\t')
    if mode not in ('LOAD', 'SAVE') or kind not in KINDS:
        raise ValueError('Opération de cache invalide')
    dbpath, plugin, magick = (bytes.fromhex(x).decode('utf-8') for x in lines[2:5])
    v = version(kind, pathlib.Path(plugin), magick)
    db = sqlite3.connect(dbpath, timeout=2)
    try:
        db.execute('CREATE TABLE IF NOT EXISTS entries (path TEXT NOT NULL, kind TEXT NOT NULL, '
                   'version TEXT NOT NULL, stamp TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(path,kind))')
        out, hits, writes, changed = ['LRCACHE1'], 0, 0, 0
        for line in lines[5:-1]:
            fields = line.split('\t')
            path = bytes.fromhex(fields[0]).decode('utf-8')
            key = os.path.normcase(os.path.abspath(path))
            now = stamp(path)
            if mode == 'LOAD':
                payload = None
                if now is not None:
                    row = db.execute('SELECT version,stamp,payload FROM entries WHERE path=? AND kind=?', (key, kind)).fetchone()
                    if row and row[0] == v and row[1] == now and isinstance(row[2], bytes) and valid(kind, row[2]):
                        payload = row[2]; hits += 1
                out.append('\t'.join(('R', fields[0], now.encode().hex() if now else '-', payload.hex() if payload else '-')))
            else:
                if len(fields) != 3:
                    raise ValueError('Entrée de cache tronquée')
                before = bytes.fromhex(fields[1]).decode('ascii')
                payload = bytes.fromhex(fields[2])
                if not valid(kind, payload):
                    raise ValueError('Résultat de cache invalide')
                if now is None or before != now:
                    changed += 1
                    continue
                db.execute('INSERT INTO entries VALUES (?,?,?,?,?) ON CONFLICT(path,kind) DO UPDATE SET '
                           'version=excluded.version,stamp=excluded.stamp,payload=excluded.payload', (key, kind, v, now, payload))
                writes += 1
        db.commit()
        out.append(f'END\t{len(lines[5:-1])}\t{hits}\t{writes}\t{changed}')
        return '\n'.join(out) + '\n'
    finally:
        db.close()


def main(request, output):
    try:
        result = execute(pathlib.Path(request).read_text(encoding='ascii'))
    except Exception as exc:
        result = 'ERROR\t' + str(exc).encode('utf-8').hex() + '\n'
    pathlib.Path(output).write_bytes(result.encode('ascii'))
    return int(result.startswith('ERROR'))


if __name__ == '__main__':
    sys.exit(main(*sys.argv[1:]))
