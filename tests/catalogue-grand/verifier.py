"""Contrôles indépendants des médias et des attentes du grand jeu, sans Lightroom."""
from collections import Counter
import hashlib
import json
from pathlib import Path
import struct
import subprocess

from PIL import Image

ROOT = Path(__file__).resolve().parents[2] / 'sortie/catalogue-grand'


def verify():
    spec = json.loads((ROOT / 'manifest.json').read_text(encoding='utf-8'))
    assert len(spec['photos']) == 10000 and len(spec['cas']) == 1438
    assert sum(len(p.get('virtuals', [])) for p in spec['photos']) == 144
    by_id = {p['id']: p for p in spec['photos']}
    assert len(by_id) == 10000
    paths = set()
    formats = Counter()
    for p in spec['photos']:
        path = Path(p['chemin']).resolve()
        assert path.is_relative_to((ROOT / 'medias').resolve())
        assert path == (ROOT / p['relatif']).resolve()
        assert str(path).casefold() not in paths
        paths.add(str(path).casefold())
        assert path.stat().st_size == p['octets'], p['id']
        with path.open('rb') as stream:
            assert hashlib.file_digest(stream, 'sha256').hexdigest() == p['sha256'], p['id']
        extension = path.suffix.lower()
        formats[extension] += 1
        if extension in ('.jpg', '.jpeg'):
            with Image.open(path) as im:
                assert im.width > 0 and im.height > 0
                im.verify()
        elif extension == '.dng':
            with path.open('rb') as stream:
                assert stream.read(4) == b'II*\x00'
                offset = struct.unpack('<I', stream.read(4))[0]
                stream.seek(offset)
                count = struct.unpack('<H', stream.read(2))[0]
                tags = {}
                for _ in range(count):
                    tag, typ, n, value = struct.unpack('<HHII', stream.read(12))
                    tags[tag] = (typ, n, value)
                assert tags[50706] == (1, 4, 0x00000401)
                width, height = tags[256][2], tags[257][2]
                assert tags[262][2] == 34892 and tags[277][2] == 3
                assert tags[279][2] == width * height * 6
                assert tags[273][2] + tags[279][2] <= p['octets']
        elif extension == '.mp4':
            # Parcourir les boîtes, y compris les grandes boîtes free, sans les charger.
            with path.open('rb') as stream:
                end = path.stat().st_size
                position = 0
                types = set()
                while position < end:
                    stream.seek(position)
                    header = stream.read(8)
                    assert len(header) == 8
                    size, kind = struct.unpack('>I4s', header)
                    minimum = 8
                    if size == 1:
                        size = struct.unpack('>Q', stream.read(8))[0]
                        minimum = 16
                    elif size == 0:
                        size = end - position
                    assert minimum <= size <= end - position, p['id']
                    position += size
                    types.add(kind)
                assert position == end and {b'ftyp', b'moov', b'mdat'} <= types

    membership = []
    hashes = {'exacts': set(), 'videos-volume': set(), 'metadonnees-volume': set()}
    for case in spec['cas']:
        entries = [by_id[i] for i in case['fichiers']]
        assert all(p['cas'] == case['id'] for p in entries)
        membership.extend(case['fichiers'])
        digests = {p['sha256'] for p in entries}
        family = case['famille']
        if family in hashes:
            assert len(digests) == 1, case['id']
            digest = next(iter(digests))
            assert digest not in hashes[family], case['id']
            hashes[family].add(digest)
        elif family in ('uniques', 'proches', 'raw-jpeg', 'rafales-volume'):
            assert len(digests) == len(entries), case['id']
    assert Counter(membership) == Counter(by_id.keys())
    unique_hashes = [p['sha256'] for p in spec['photos'] if p['cas'].startswith('U')]
    assert len(set(unique_hashes)) == 4000

    # Décoder réellement un JPEG, un RAW linéaire et une vidéo générée.
    for name in ['U001/Archive 00/IMG_0000.jpg', 'W001/IMG_1000.dng', 'M001/CLIP_1000.mp4']:
        subprocess.run(['ffmpeg', '-v', 'error', '-i', str(ROOT / 'medias' / name),
                        '-frames:v', '1', '-f', 'null', '-'], check=True, capture_output=True)
    result = dict(ok=True, medias=10000, scenarios=1438, copies_virtuelles_prevues=144,
                  formats=dict(formats), empreintes_verifiees=10000,
                  groupes_exacts_controles={k: len(v) for k, v in hashes.items()},
                  import_lightroom_verifie=False)
    (ROOT / 'verification-medias.json').write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    verify()
