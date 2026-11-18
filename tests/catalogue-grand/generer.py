"""Prépare 10 000 médias isolés ; le .lrcat est créé uniquement par Lightroom."""
from __future__ import annotations

from collections import Counter
from datetime import datetime, timedelta
import hashlib
import importlib.util
import json
from pathlib import Path
import random
import shutil
import struct

from PIL import Image, ImageDraw, ImageFilter

REPO = Path(__file__).resolve().parents[2]
ROOT = REPO / 'sortie/catalogue-grand'
COMPACT = REPO / 'sortie/catalogue-compact'
module_spec = importlib.util.spec_from_file_location('compact_generer', REPO / 'tests/catalogue-compact/generer.py')
compact = importlib.util.module_from_spec(module_spec)
module_spec.loader.exec_module(compact)


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def image(seed, label, frame=0):
    rng = random.Random(seed)
    im = Image.new('RGB', (640, 426), tuple(rng.randrange(30, 190) for _ in range(3)))
    draw = ImageDraw.Draw(im)
    for _ in range(60):
        x, y = rng.randrange(610), rng.randrange(396)
        draw.rectangle((x, y, x + rng.randrange(5, 70), y + rng.randrange(5, 50)),
                       fill=tuple(rng.randrange(256) for _ in range(3)))
    # Détail fin déterministe : rend la netteté et la recompression observables.
    for x in range(10, 300, 4):
        draw.line((x, 300, x, 420), fill=(x % 255, 15, 20), width=1)
    draw.ellipse((400 + frame, 100, 470 + frame, 170), fill='white')
    draw.rectangle((0, 0, 640, 45), fill='white')
    draw.text((10, 12), label, fill='black', font_size=18)
    return im


def generate():
    assert not ROOT.exists(), 'Destination déjà présente : aucun écrasement autorisé.'
    assert shutil.disk_usage(REPO).free > 5 * 1024**3, 'Au moins 5 Gio libres requis.'
    initial = json.loads((COMPACT / 'etat-initial/manifest.json').read_text(encoding='utf-8'))
    for entry in initial['photos']:
        assert sha(Path(entry['chemin'])) == entry['sha256'], 'Média compact altéré.'
    ROOT.mkdir()
    media = ROOT / 'medias'
    cases, photos = initial['cas'], initial['photos']
    for entry in photos:
        path = ROOT / entry['relatif']
        path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(entry['chemin'], path)
        entry['chemin'] = str(path)
    print('Socle compact copié : 168 médias, 40 cas.', flush=True)

    current = None

    def case(ident, title, family, expected):
        nonlocal current
        current = dict(id=ident, titre=title, famille=family, attendu=expected, fichiers=[], sequence=[])
        cases.append(current)

    def add(name, im=None, source=None, date=None, quality=90, video=None, **state):
        path = media / current['id'] / name
        path.parent.mkdir(parents=True, exist_ok=True)
        if source:
            shutil.copyfile(source, path)
        elif video is not None:
            path.write_bytes(video)
        elif path.suffix == '.dng':
            compact.dng(path, im, date)
        else:
            exif = Image.Exif()
            exif[271] = 'Deduplicate synthétique grand'
            exif[274] = 1
            if date:
                stamp = date.strftime('%Y:%m:%d %H:%M:%S')
                exif[306] = stamp
                exif[34665] = {36867: stamp, 36868: stamp, 37521: '000'}
            im.save(path, quality=quality, subsampling=0, exif=exif)
        entry = dict(id=f"{current['id']}-{len(current['fichiers']) + 1:03}", cas=current['id'],
                     relatif=path.relative_to(ROOT).as_posix(), chemin=str(path), **state)
        current['fichiers'].append(entry['id'])
        photos.append(entry)
        return path

    for batch in range(40):
        case(f'U{batch + 1:03}', 'Cent scènes distinctes', 'uniques', 'Aucune fusion exacte entre ces scènes.')
        for i in range(100):
            n = batch * 100 + i
            add(f'Archive {n % 10:02}/IMG_{i:04}.jpg', image(n + 100000, f'SCENE UNIQUE {n:05}'),
                date=datetime(2010, 1, 1) + timedelta(days=n),
                metadata={'rating': n % 6},
                keywords=[['Archives', f'Année {2010 + n % 17}', f'Série {n % 100:03}']],
                collections=[['Albums synthétiques', f'Année {2010 + n % 17}', f'Album {n % 100:03}']])
        print(f'Images uniques : {(batch + 1) * 100}/4000', flush=True)

    for n in range(300):
        count = [2, 3, 5, 6][n % 4]
        case(f'X{n + 1:03}', f'Doublons exacts dispersés ×{count}', 'exacts',
             f'Un groupe exact de {count} originaux ; {count - 1} copies écartables, métadonnées réunies.')
        first = None
        for i in range(count):
            state = dict(metadata={'rating': i % 6, 'pickStatus': 1 if i == count - 1 else 0},
                         keywords=[['Lieux' if i % 2 == 0 else 'Personnes', 'Paris']],
                         collections=[['Albums synthétiques', f'Lot {n % 30:02}', f'Album {i:02}']])
            if n % 3 == 0 and i == count - 1:
                state['virtuals'] = [{'name': 'Version à préserver', 'develop': {'Exposure2012': 0.35}}]
            p = add(f'Copie {i}/IMG_{n:04}' + (f'-{i + 1}' if i else '') + '.jpg',
                    image(200000 + n, f'EXACT {n:03}') if first is None else None,
                    source=first, date=datetime(2020, 1, 1) + timedelta(days=n), **state)
            first = first or p
    print('300 groupes exacts : 1200 médias.', flush=True)

    for n in range(400):
        case(f'P{n + 1:03}', 'Original, recompression et détail changé', 'proches',
             'Seul l’original est intact ; toute proposition fondée sur la ressemblance exige une vérification.')
        im = image(300000 + n, f'VARIANTE {n:03}')
        date = datetime(2021, 1, 1) + timedelta(days=n)
        add('IMG_1000.jpg', im, date=date)
        add('IMG_1000-2.jpg', im, quality=45, date=date)
        changed = im.copy()
        ImageDraw.Draw(changed).text((510, 250), str(n % 10), fill='black', font_size=24)
        add('IMG_1000-3.jpg', changed, date=date)
    print('400 groupes proches : 1200 médias.', flush=True)

    for n in range(200):
        dual = n % 2 == 1
        case(f'B{n + 1:03}', 'Rafales intercalées et protections' if dual else 'Rafale de douze cadres', 'rafales-volume',
             'Deux rafales de six cadres, une par dossier.' if dual else
             'Douze cadres ; préserver notes, libellés, retouches et copies virtuelles protégées.')
        start = datetime(2023, 1, 1, 12) + timedelta(days=n)
        for i in range(12):
            camera = i % 2 if dual else 0
            frame = i // 2 if dual else i
            im = image(400000 + n * 2 + camera, f'RAFALE {n:03} APPAREIL {camera}', frame * 3)
            if i % 4:
                im = im.filter(ImageFilter.GaussianBlur((i % 4) * 0.6))
            state = {}
            if i == 1:
                state['metadata'] = {'rating': 3}
            elif i == 3:
                state['metadata'] = {'label': 'À vérifier — libellé libre'}
            elif i == 5:
                state['develop'] = {'Exposure2012': 0.2}
            if i == 7 and n % 5 == 0:
                state['virtuals'] = [{'name': 'Recadrage protégé', 'develop': {'Exposure2012': -0.2}}]
            add(f'Appareil {camera}/IMG_{1000 + frame:04}.jpg', im, date=start + timedelta(seconds=frame // 2), **state)
    print('200 cas de rafales : 2400 médias.', flush=True)

    for n in range(200):
        case(f'W{n + 1:03}', 'Paire RAW et JPEG', 'raw-jpeg', 'Même cadre ; ne pas assimiler les octets RAW et JPEG à des doublons exacts.')
        im = image(500000 + n, f'RAW ET JPEG {n:03}')
        date = datetime(2024, 1, 1) + timedelta(days=n)
        add('IMG_1000.jpg', im, date=date)
        add('IMG_1000.dng', im, date=date)
    print('200 paires RAW+JPEG : 400 médias.', flush=True)

    video_base = (media / 'V01/CLIP_1000.mp4').read_bytes()
    for n in range(200):
        case(f'M{n + 1:03}', 'Vidéos exactes renommées', 'videos-volume', 'Un groupe exact de deux vidéos vierges.')
        marker = f'VIDEO SYNTHETIQUE GRAND {n:04}'.encode('ascii')
        payload = video_base + struct.pack('>I4s', len(marker) + 8, b'free') + marker
        add('CLIP_1000.mp4', video=payload)
        add('Archives/renommée.mp4', video=payload)
    print('200 paires vidéo : 400 médias.', flush=True)

    for n in range(58):
        case(f'T{n + 1:03}', 'Unicode, homonymes et états contradictoires', 'metadonnees-volume',
             'Un groupe exact de quatre ; préserver les mots-clés homonymes et les collections distinctes.')
        im = image(600000 + n, f'METADONNEES {n:03}')
        first = None
        for i in range(4):
            p = add(f"Été 🧪 & l'album {i}/épreuve #{n:03} ; [test].jpg", im if not first else None,
                    source=first, metadata={'rating': i, 'title': f'Titre {i} — é & <test>',
                                            'caption': '' if i % 2 else 'Légende « synthétique »'},
                    keywords=[['Lieux' if i % 2 else 'Personnes', 'Paris']],
                    collections=[['Homonymes', f'Année {2020 + i}', 'Vacances']])
            first = first or p
    print('58 cas de métadonnées : 232 médias.', flush=True)

    assert len(photos) == 10000
    for entry in photos:
        p = Path(entry['chemin'])
        entry['octets'], entry['sha256'] = p.stat().st_size, sha(p)
    spec = dict(version=1, racine=str(ROOT), medias=str(media), importLot=25, importExistants=True,
                catalogue=str(ROOT / 'Deduplicate-grand/Deduplicate-grand.lrcat'), cas=cases, photos=photos)
    spec['etatsEnLots'] = True
    spec['snapshotRapide'] = True
    spec['empreinteEtats'] = hashlib.sha256(json.dumps(photos,ensure_ascii=False,sort_keys=True).encode('utf-8')).hexdigest()
    (ROOT / 'manifest.json').write_text(json.dumps(spec, ensure_ascii=False, indent=2), encoding='utf-8')
    (ROOT / 'Manifeste.lua').write_text('return ' + compact.lua(spec) + '\n', encoding='utf-8')
    prepare(spec)
    summary = dict(statut='medias_prepares_import_lightroom_en_attente', scenarios=len(cases), medias=len(photos),
                   copies_virtuelles_prevues=sum(len(p.get('virtuals', [])) for p in photos),
                   octets=sum(p['octets'] for p in photos), familles=dict(Counter(c['famille'] for c in cases)),
                   catalogue=spec['catalogue'], catalogue_cree=False, import_effectue=False,
                   manifest_sha256=sha(ROOT / 'manifest.json'))
    (ROOT / 'preparation.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(summary, ensure_ascii=False, indent=2), flush=True)


def prepare(spec):
    helper = ROOT / 'preparation.lrplugin'
    helper.mkdir()
    text = (REPO / 'tests/catalogue-compact/Preparation.lua').read_text(encoding='utf-8-sig')
    (helper / 'Preparation.lua').write_text(text.replace('catalogue compact', 'grand catalogue').replace('Catalogue compact', 'Grand catalogue'), encoding='utf-8')
    for name in ['Init', 'Lancer']:
        (helper / f'{name}.lua').write_text("require('Preparation').demarrer()\n", encoding='utf-8')
    (helper / 'Info.lua').write_text("""return {
 LrSdkVersion=13.0, LrSdkMinimumVersion=6.0,
 LrToolkitIdentifier='io.github.mtthth.deduplicate.catalogue-grand',
 LrPluginName='Grand catalogue - préparation', LrInitPlugin='Init.lua', LrForceInitPlugin=true,
 LrLibraryMenuItems={{title='TEST : préparer le grand catalogue', file='Lancer.lua'}},
 VERSION={major=1,minor=0,revision=0},
}
""", encoding='utf-8')
    env = ROOT / 'environnement'
    plugin = env / 'lightroom-deduplicate/lightroom-deduplicate.lrplugin'
    shutil.copytree(REPO / 'lightroom-deduplicate.lrplugin', plugin, ignore=shutil.ignore_patterns('__pycache__'))
    neighbor = env / 'lightroom-google-photos/albums-google-photos.lrplugin'
    # Même disposition que le compact ; copie locale du voisin, jamais activée.
    shutil.copytree(COMPACT / 'environnement/lightroom-google-photos/albums-google-photos.lrplugin', neighbor,
                    ignore=shutil.ignore_patterns('__pycache__'))
    info = plugin / 'Info.lua'
    text = info.read_text(encoding='utf-8-sig').replace("'io.github.mtthth.deduplicate'", "'io.github.mtthth.deduplicate.grand'")
    text = text.replace("LrPluginName = 'Deduplicate'", "LrPluginName = 'Deduplicate - TEST grand'")
    info.write_text(text, encoding='utf-8')
    guard = "local c=import('LrApplication').activeCatalog()\nif not c or c:getPath():gsub('/','\\\\'):lower()~=(" + compact.lua(spec['catalogue']) + "):gsub('/','\\\\'):lower() then return end\n"
    for name in ['Initialiser', 'FusionnerDoublons', 'FusionManuelle', 'ReduireRafales', 'RestaurerCollections', 'DiagnosticCatalogue']:
        p = plugin / (name + '.lua')
        p.write_text(guard + p.read_text(encoding='utf-8-sig'), encoding='utf-8')
    history = '# type\tchemin\tfichier\tdate_prise_de_vue\n# historique-commun-deduplicate-google-v1\n'
    for p in spec['photos']:
        if p.get('excluded'):
            history += f"doublon\t{p['chemin']}\t{Path(p['chemin']).name}\t2024-01-21 12:00:00\n"
    (env / 'lightroom-google-photos/photos-traitees.txt').write_text(history, encoding='utf-8')
    (ROOT / 'commande-a-lancer.txt').write_text('initialiser', encoding='utf-8')


if __name__ == '__main__':
    generate()
