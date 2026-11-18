"""Fabrique des médias synthétiques et le manifeste du catalogue de torture.

Ne lit aucune photo personnelle. Ne crée/modifie jamais de base Lightroom.
La création du .lrcat et son remplissage passent par Lightroom et son SDK.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from datetime import datetime, timedelta
from pathlib import Path
import random
import shutil
import struct
import subprocess

import numpy as np
from PIL import Image, ImageDraw, ImageEnhance, ImageFilter, ImageOps

REPO = Path(__file__).resolve().parents[2]
DEFAULT = REPO / 'sortie' / 'catalogue-compact'


def lua(value):
    if value is None:
        return 'nil'
    if value is True:
        return 'true'
    if value is False:
        return 'false'
    if isinstance(value, str):
        return '"' + value.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n').replace('\r', '\\r') + '"'
    if isinstance(value, (float, int)):
        return str(value)
    if isinstance(value, list):
        return '{' + ','.join(lua(v) for v in value) + '}'
    return '{' + ','.join('[' + lua(k) + ']=' + lua(v) for k, v in value.items()) + '}'


def pattern(seed, label, frame=0):
    rng = np.random.default_rng(seed)
    w, h = 960, 640
    y, x = np.mgrid[:h, :w]
    a = np.zeros((h, w, 3), dtype=np.uint8)
    for c in range(3):
        a[:, :, c] = np.clip(70 + 90 * x / w + 30 * np.sin(y / (27 + c * 9) + seed + c)
                             + rng.normal(0, 3, (h, w)) + c * 12, 0, 255)
    im = Image.fromarray(a)
    d = ImageDraw.Draw(im)
    rr = random.Random(seed)
    for k in range(14):
        xx, yy = rr.randrange(40, 800), rr.randrange(90, 530)
        d.rectangle((xx, yy, xx + rr.randrange(15, 100), yy + rr.randrange(15, 70)),
                    fill=tuple(rr.randrange(30, 230) for _ in range(3)))
    d.rectangle((20, 20, 500, 70), fill='white')
    d.text((35, 35), label, fill='black', font_size=24)
    d.ellipse((670 + frame * 3, 80, 790 + frame * 3, 200), fill=(230, 80, 45))
    for xx in range(40, 420, 8):
        d.line((xx, 450, xx, 610), fill=(25, 25, 25), width=2)
    return im


def dng(path, im, date=None):
    """DNG linéaire RGB 16 bits, TIFF little endian, sans compression."""
    w, h = im.size
    pixels = (np.asarray(im, dtype=np.uint16) * 257).astype('<u2').tobytes()
    tags = []

    def tag(n, typ, values):
        if typ == 2:
            data = values.encode('ascii') + b'\0'; count = len(data)
        elif typ in (5, 10):
            count = len(values); data = b''.join(struct.pack('<' + ('II' if typ == 5 else 'ii'), *v) for v in values)
        else:
            values = values if isinstance(values, (list, tuple)) else [values]
            count = len(values); data = struct.pack('<' + {1: 'B', 3: 'H', 4: 'I'}[typ] * count, *values)
        tags.append((n, typ, count, data))

    for n, typ, v in [(254,4,0),(256,4,w),(257,4,h),(258,3,[16,16,16]),(259,3,1),
                      (262,3,34892),(271,2,'Deduplicate'),(272,2,'Synthetic Linear DNG'),
                      (273,4,0),(274,3,1),(277,3,3),(278,4,h),(279,4,len(pixels)),(284,3,1),
                      (50706,1,[1,4,0,0]),(50707,1,[1,3,0,0]),(50708,2,'Deduplicate Synthetic Linear DNG'),
                      (50717,4,[65535,65535,65535]),(50719,4,[0,0]),(50720,4,[w,h]),
                      (50721,10,[(1,1),(0,1),(0,1),(0,1),(1,1),(0,1),(0,1),(0,1),(1,1)]),
                      (50728,5,[(1,1),(1,1),(1,1)]),(50778,3,21)]:
        tag(n,typ,v)
    if date:
        tag(306,2,date.strftime('%Y:%m:%d %H:%M:%S'))
        tag(34665,4,0)
    tags.sort()
    offset = 8 + 2 + len(tags) * 12 + 4
    extra = bytearray(); entries = []
    for n, typ, count, data in tags:
        if len(data) > 4:
            pos = offset + len(extra); extra.extend(data)
            if len(extra) % 2: extra.append(0)
            value = struct.pack('<I', pos)
        else:
            value = data.ljust(4, b'\0')
        entries.append((n, struct.pack('<HHI', n, typ, count) + value))
    exif_start=offset+len(extra)
    if date:
        stamp=date.strftime('%Y:%m:%d %H:%M:%S').encode('ascii')+b'\0'
        extra.extend(struct.pack('<H',2)+struct.pack('<HHII',36867,2,len(stamp),exif_start+30)
                     +struct.pack('<HHII',36868,2,len(stamp),exif_start+30+len(stamp))+b'\0'*4+stamp*2)
    pixel_start = offset + len(extra)
    entries = [struct.pack('<HHII',273,4,1,pixel_start) if n == 273 else
               struct.pack('<HHII',34665,4,1,exif_start) if n==34665 else e for n,e in entries]
    path.write_bytes(b'II*\0' + struct.pack('<I',8) + struct.pack('<H',len(tags)) + b''.join(entries)
                     + b'\0'*4 + extra + pixels)


def generate(root):
    root.mkdir(parents=True, exist_ok=True)
    manifest_path = root / 'manifest.json'
    if manifest_path.exists():
        raise SystemExit('Manifeste déjà présent : génération refusée pour préserver le catalogue préparé.')
    media = root / 'medias'; media.mkdir(exist_ok=True)
    cases, photos = [], []
    current = None

    def case(ident, title, expected, family='doublons', workflow=None):
        nonlocal current
        current = dict(id=ident, titre=title, famille=family, attendu=expected, fichiers=[], sequence=workflow or [])
        cases.append(current)
        return pattern(len(cases) * 317, ident + ' - ' + title[:35])

    def add(name, im=None, source=None, quality=94, dt=None, orientation=1, **state):
        path = media / current['id'] / name
        path.parent.mkdir(parents=True, exist_ok=True)
        date = datetime(2024, 1, 1, 12) + timedelta(days=len(cases)) if dt is None else dt
        if source:
            shutil.copyfile(source, path)
        elif path.suffix.lower() == '.dng':
            dng(path, im, date)
        else:
            exif = Image.Exif()
            if date:
                stamp = date.strftime('%Y:%m:%d %H:%M:%S')
                exif[306] = stamp
                exif[34665] = {36867: stamp, 36868: stamp, 37521: '000'}
            exif[274] = orientation
            exif[271] = state.pop('make', 'Deduplicate - synthétique')
            opts = {'exif': exif}
            if path.suffix.lower() in ('.jpg', '.jpeg'): opts.update(quality=quality, subsampling=0)
            im.save(path, **opts)
        entry = dict(id=f"{current['id']}-{len(current['fichiers'])+1:02}", cas=current['id'],
                     relatif=path.relative_to(root).as_posix(), chemin=str(path), **state)
        current['fichiers'].append(entry['id']); photos.append(entry)
        return path

    def pair(im, **states):
        a = add('IMG_1000.jpg', im, **states.get('a', {}))
        add('IMG_1000-2.jpg', source=a, **states.get('b', {}))

    im=case('D01','Deux copies exactes renommées','Un groupe exact ; une seule gardée.')
    a=add('Bien rangé/original.jpg',im); add('Désordre/tout-autre-nom.JPG',source=a)
    im=case('D02','Trois copies dispersées','Un groupe de trois ; priorité au dossier nommé.')
    a=add('Voyage/IMG_1000.jpg',im); add('2024/IMG_1000-2.jpg',source=a); add('Désordre/IMG_1000 (2).jpg',source=a)
    im=case('D03','Dix copies et suffixes','Un seul groupe exact de dix ; neuf copies écartables.')
    a=add('IMG_1000.jpg',im)
    for i in range(2,11): add(f'IMG_1000-{i}.jpg',source=a)
    im=case('D04','Suffixes de retouche mais octets identiques','Les six fichiers restent des doublons exacts malgré les noms de retouche.')
    a=add('IMG_1000.jpg',im)
    for s in [' (2)','-2-3','-Modifier','_filtered','-20260821-DxO_DeepPRIME XD3']: add(f'IMG_1000{s}.jpg',source=a)
    im=case('D05','Copie réduite','Même vue ; la version 960 × 640 doit être proposée comme gardée.')
    add('IMG_1000.jpg',im); add('IMG_1000-2.jpg',im.resize((480,320)))
    im=case('D06','Copie recompressée','Même vue recompressée ; comparer la décision et sa justification.')
    add('IMG_1000.jpg',im); add('IMG_1000-2.jpg',im,quality=50)
    im=case('D07','Versions externes distinctes','Conserver les versions recadrée, monochrome, exposée et filtrée.')
    add('IMG_1000.jpg',im)
    for s, v in [('-Modifier',im.crop((100,50,850,550))),('-Edit',ImageOps.grayscale(im).convert('RGB')),
                 ('_filtered',ImageEnhance.Color(im).enhance(1.7)),('-DxO_DeepPRIME 3',ImageEnhance.Brightness(im).enhance(1.2))]: add(f'IMG_1000{s}.jpg',v)
    im=case('D08','Même nom et même date, autre image','Les deux scènes différentes restent séparées.')
    add('A/IMG_1000.jpg',im); add('B/IMG_1000.jpg',pattern(9999,'AUTRE SCENE'))
    im=case('D09','Petit détail significatif','Ne pas fusionner automatiquement si le détail change ; cas exploratoire de faux positif.')
    add('IMG_1000.jpg',im); v=im.copy(); ImageDraw.Draw(v).text((550,350),'7',fill='black',font_size=24); add('IMG_1000-2.jpg',v)
    im=case('D10','Chaîne de ressemblances A B C','A et C ne doivent pas fusionner sur la seule ressemblance avec B ; mesurer les signatures.')
    for i, delta in enumerate([0,2,4]): add('IMG_1000'+('' if i==0 else f'-{i+1}')+'.jpg',Image.fromarray(np.clip(np.asarray(im).astype('int16')+delta,0,255).astype('uint8')))
    im=case('D11','JPEG commentaires et EXIF','COM seul : même empreinte ; EXIF différent : empreinte différente, comparaison visuelle possible.')
    a=add('IMG_1000.jpg',im); b=add('IMG_1000-2.jpg',source=a)
    raw=b.read_bytes(); comment=b'Commentaire de torture sans effet visuel'; b.write_bytes(raw[:2]+b'\xff\xfe'+struct.pack('>H',len(comment)+2)+comment+raw[2:])
    add('IMG_1000-3.jpg',im,make='Autre marque EXIF')
    im=case('D12','Orientation EXIF différente','Même matrice JPEG, orientation 1 contre 6 : vérifier la prudence de la comparaison et les aperçus.')
    add('IMG_1000.jpg',im); add('IMG_1000-2.jpg',im,orientation=6)
    im=case('D13','Métadonnées contradictoires','Note maximale 5 ; retenue prioritaire ; titre de la gardée conservé ; légende vide complétée ; GPS zéro valide.')
    a=add('IMG_1000.jpg',im,metadata={'rating':2,'pickStatus':-1,'title':'Titre gardée','gps':{'latitude':0,'longitude':0}})
    add('IMG_1000-2.jpg',source=a,metadata={'rating':5,'pickStatus':1,'title':'Titre contradictoire','caption':'Légende é & <test> "guillemets"','gps':{'latitude':48.5,'longitude':2.5}})
    add('IMG_1000-3.jpg',source=a,metadata={'rating':3,'label':'rouge','creator':'Auteur synthétique'})
    im=case('D14','Mots-clés homonymes et hiérarchiques','Conserver les deux mots-clés Paris sous des parents différents et le mot-clé non exporté.')
    a=add('IMG_1000.jpg',im,keywords=[['Lieux','Paris']]); add('IMG_1000-2.jpg',source=a,keywords=[['Personnes','Paris'],['Technique','Interne']],nonexport=['Interne'])
    im=case('D15','Collections homonymes et caractères HTML','Réunir les appartenances par identifiant ; préserver les parents ; échapper le HTML.')
    a=add('IMG_1000.jpg',im,collections=[['Albums','2024','Vacances']]); add('IMG_1000-2.jpg',source=a,collections=[['Albums','2025','Vacances'],['Été 🧪','A & B <essai> "été"']])
    im=case('D16','Une copie retouchée','À dimensions égales, privilégier la copie développée dans Lightroom.')
    pair(im,b={'develop':{'Exposure2012':0.7,'Contrast2012':12}})
    im=case('D17','Deux copies retouchées','Groupe à vérifier : plusieurs copies retouchées.')
    pair(im,a={'develop':{'Exposure2012':0.5}},b={'develop':{'Exposure2012':-0.5}})
    im=case('D18','Petite version avec du travail','Groupe à vérifier : la petite copie porte des retouches Lightroom.')
    add('IMG_1000.jpg',im); add('IMG_1000-2.jpg',im.resize((480,320)),develop={'Exposure2012':0.8})
    im=case('D19','Copies virtuelles multiples','Automatique prudent ; fusion forcée : recréer les virtuelles avec noms identiques, réglages et collections.')
    a=add('IMG_1000.jpg',im,virtuals=[{'name':'Même nom','develop':{'Exposure2012':0.5}}])
    add('IMG_1000-2.jpg',source=a,virtuals=[{'name':'Même nom','develop':{'Exposure2012':-0.5,'WhiteBalance':'Auto'},'collections':[['Versions','A']]},
        {'name':'Même nom','develop':{'CropTop':0.1,'CropBottom':0.9,'CropLeft':0.1,'CropRight':0.9,'WhiteBalance':'Custom','IncrementalTemperature':10,'IncrementalTint':8},'metadata':{'rating':4},'collections':[['Versions','B']]}])
    im=case('D20','Gardée déjà mise à retirer','Fusion forcée : rétablir la gardée et retirer son exclusion ; annuler/rétablir doit rester cohérent.')
    a=add('IMG_1000.jpg',im,collections=[['Doublons à retirer'],['Rafales à retirer']],excluded=True); add('IMG_1000-2.jpg',source=a)
    im=case('D21','Chemins Unicode et ponctuation','Lecture, rapports et sauvegardes doivent fonctionner avec accents, emoji, apostrophe et esperluette.')
    a=add("Été 🧪 & l'album/épreuve #1 ; [test].jpg",im); add('Réserve/renommée 🧪.JPG',source=a)
    im=case('D22','Chemin long','Importation et lectures du fichier au chemin long ; échec éventuel explicitement signalé.')
    a=add(('dossier-long-'*5)+'/niveau-intermediaire-de-verification/IMG_1000.jpg',im); add('court/IMG_1000-2.jpg',source=a)

    # Vidéos valides ; les gros fichiers ont une boîte MP4 free, sans charge vidéo lourde.
    ffmpeg=shutil.which('ffmpeg')
    if not ffmpeg: raise RuntimeError('ffmpeg requis')
    def video(ident,title,expected,sizes,change=False):
        case(ident,title,expected,'videos')
        p=media/ident/'CLIP_1000.mp4'; p.parent.mkdir(parents=True,exist_ok=True)
        subprocess.run([ffmpeg,'-v','error','-y','-f','lavfi','-i',f'testsrc2=size=320x240:rate=12:duration=1','-c:v','libx264','-pix_fmt','yuv420p','-metadata',f'comment={ident}',str(p)],check=True)
        base=p.read_bytes()
        for i,size in enumerate(sizes):
            target=p if i==0 else p.with_name(f'CLIP_1000-{i+1}.mp4')
            if size:
                padding=size-len(base)
                with target.open('wb') as f:
                    f.write(base); f.write(struct.pack('>I4s',padding,b'free')); f.truncate(size)
                    if change and i==1: f.seek(size//2); f.write(b'DIFFERENCE AU MILIEU')
            elif i: target.write_bytes(base)
            entry=dict(id=f'{ident}-{i+1:02}',cas=ident,relatif=target.relative_to(root).as_posix(),chemin=str(target))
            current['fichiers'].append(entry['id']); photos.append(entry)
    video('V01','Deux vidéos exactes','Un groupe exact de vidéos renommées.',[None,None])
    video('V02','Vidéos juste sous 64 Mio','Doublons exacts de taille 64 Mio moins un octet.',[64*1024**2-1]*2)
    video('V03','Vidéos au-dessus de 64 Mio','Doublons exacts ; le contrôle intégral doit confirmer le préfiltre.',[64*1024**2+1]*2)
    video('V04','Gros MP4 différents au centre','Début et fin identiques, même taille ; différence dans la boîte free centrale : aucune fusion exacte.',[64*1024**2+4096]*2,True)

    def burst(ident,title,n,expected,seconds=None,numbers=None,protect=None,extra=False,two=False):
        im=case(ident,title,expected,'rafales')
        start=datetime(2025,6,1,12)+timedelta(minutes=int(ident[1:])*5)
        for i in range(n):
            v=pattern(len(cases)*317,ident,frame=i)
            if i%4!=0: v=v.filter(ImageFilter.GaussianBlur((i%4)*0.9))
            dt=start+timedelta(seconds=seconds[i] if seconds else i//2)
            st=(protect or {}).get(i,{})
            a=add(f'IMG_{(numbers[i] if numbers else 1000+i):04}.jpg',v,dt=dt,**st)
            if extra: add(f'IMG_{1000+i:04}-2.jpg',source=a)
            if two: add(f'Autre appareil/IMG_{1000+i:04}.jpg',pattern(68000+i,ident+' appareil B'),dt=dt,make='Appareil B')
    burst('R01','Deux cadres seulement',2,'Aucune rafale : minimum trois cadres.')
    burst('R02','Trois cadres',3,'Une rafale ; garder le plus net du bloc, écarter les deux autres.')
    burst('R03','Quatre cadres avec copies',4,'Quatre cadres, huit fichiers ; chaque copie suit le sort de son cadre.',extra=True)
    burst('R04','Cinq cadres',5,'Deux blocs équilibrés ; une gardée non protégée par bloc.')
    burst('R05','Neuf cadres',9,'Trois blocs ; une gardée non protégée par bloc.')
    burst('R06','Frontières de temps',8,'Les sauts de deux secondes coupent les rafales.',seconds=[0,1,2,4,5,6,8,9])
    burst('R07','Trous et remise à zéro',8,'Tester écart de numéro 3 contre 4 et passage 9999 → 0001.',numbers=[9990,9991,9994,9998,9999,1,2,3])
    burst('R08','Toutes les protections',12,'Garder tous les cadres protégés et le meilleur cadre libre de chaque bloc.',protect={
        0:{'metadata':{'rating':1}},1:{'metadata':{'pickStatus':-1}},2:{'metadata':{'pickStatus':1}},
        3:{'metadata':{'label':'rouge'}},4:{'develop':{'Exposure2012':0.4}},
        5:{'virtuals':[{'name':'Protégée','develop':{'Exposure2012':0.3}}]},
        6:{'collections':[['Protection','Album']]},7:{'collections':[['Google Photos - albums','2025','Album synthétique']]}})
    burst('R09','Exception SESSIONS et époques',12,'Sessions et époques ne protègent pas ; un album ordinaire protège même en présence de Sessions.',protect={
        0:{'collections':[['Mes SESSIONS 2025','Enfant']]},1:{'collections':[['Google Photos - époques','2025']]},
        2:{'collections':[['Mes SESSIONS 2025','Enfant'],['Protection','Album']]},3:{'metadata':{'rating':2},'collections':[['Sessions','Enfant']]}})
    burst('R10','Deux appareils simultanés',8,'Vérifier les frontières entre dossiers/appareils ; aucun mélange ni perte de cadres.',two=True)

    im=case('E01','Fichier manquant après import','Déplacer la copie via la commande de test ; analyse prudente et fusion interrompue si le fichier manque.','erreurs',workflow=['Préparer E01 : rendre une copie manquante','Analyser puis restaurer les fichiers'])
    pair(im)
    im=case('E02','Remplacement entre analyse et fusion','Après analyse, remplacer la copie à taille identique ; la revalidation doit bloquer avant modification.','erreurs',workflow=['Analyser E02','Commande test : remplacer E02','Confirmer la fusion ; vérifier arrêt','Restaurer les fichiers'])
    pair(im)
    im=case('E03','Sans date et RAW plus JPEG','Tester absence de date, puis deux cadres DNG+JPEG ; les RAW sont de vrais DNG linéaires synthétiques.','erreurs')
    for i in range(3):
        v=pattern(77000+i,'DNG + JPEG '+str(i)); stamp=datetime(2025,7,1,12,0,i)
        add(f'IMG_{1000+i}.jpg',v,dt=stamp); add(f'IMG_{1000+i}.dng',v,dt=stamp)
    add('sans-date.jpg',im,dt=False)
    im=case('E04','Annulation restauration et portée','Trois copies ; tester portée partielle, refus persistant, fusion forcée, restauration, Ctrl+Z et rétablissement.','erreurs',workflow=['Analyser seulement deux copies puis les trois','Refuser le groupe et relancer','Fusionner de force','Annuler et rétablir','Restaurer les collections depuis la sauvegarde'])
    a=add('IMG_1000.jpg',im,collections=[['Restauration','A']]); add('IMG_1000-2.jpg',source=a,collections=[['Restauration','B']]); add('IMG_1000-3.jpg',source=a,collections=[['Restauration','C']])

    for entry in photos:
        p=Path(entry['chemin']); entry['octets']=p.stat().st_size
        entry['sha256']=hashlib.file_digest(p.open('rb'),'sha256').hexdigest()
    manifest=dict(version=1,racine=str(root),medias=str(media),catalogue=str(root/'Deduplicate-compact'/'Deduplicate-compact.lrcat'),cas=cases,photos=photos)
    manifest_path.write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf-8')
    (root/'Manifeste.lua').write_text('return '+lua(manifest)+'\n',encoding='utf-8')
    lines=['# Catalogue compact Deduplicate','',f'{len(cases)} scénarios, {len(photos)} fichiers synthétiques.','',
           'Les attentes décrivent les critères à vérifier, pas des tests déjà exécutés. Aucune fusion n’est appliquée pendant la création.',
           'Chaque scénario possède sa collection. Les collections sous « Scénarios » ne protègent pas les rafales : leur parent contient « sessions ».','',
           'Les gros MP4 sont valides et contiennent une boîte free de remplissage ; V04 diffère au centre de cette boîte. Aucun fichier vidéo personnel n’est utilisé.',
           'Les trois DNG sont des RAW linéaires RGB synthétiques. E03 peut aussi être sélectionné pour tester leur association aux JPEG.',
           'Les publications et masques IA ne sont pas préconfigurés : ils demandent un scénario complémentaire dans Lightroom.','',
           '## Scénarios','']
    for c in cases:
        lines += [f"### {c['id']} — {c['titre']}",'',c['attendu'],'',f"Fichiers : {', '.join(c['fichiers'])}.",'']
        if c['sequence']: lines += [' → '.join(c['sequence']),'']
    (root/'LIRE-MOI.md').write_text('\n'.join(lines),encoding='utf-8')
    print(json.dumps({'scenarios':len(cases),'fichiers':len(photos),'octets':sum(p['octets'] for p in photos),'racine':str(root)},ensure_ascii=False))


if __name__=='__main__':
    parser=argparse.ArgumentParser(); parser.add_argument('--sortie',type=Path,default=DEFAULT)
    generate(parser.parse_args().sortie.resolve())
