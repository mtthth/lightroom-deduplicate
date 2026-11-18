"""Vérifie le catalogue créé par Lightroom, en lecture seule, contre le manifeste."""
import argparse
import hashlib
import json
import re
from pathlib import Path
import sqlite3
import subprocess
import zlib
import xml.etree.ElementTree as ET

ROOT=Path(__file__).resolve().parents[2]/'sortie'/'catalogue-compact'

def main():
    global ROOT
    parser=argparse.ArgumentParser(); parser.add_argument('--schema',action='store_true')
    parser.add_argument('--racine',type=Path,default=ROOT)
    args=parser.parse_args()
    ROOT=args.racine.resolve()
    spec=json.loads((ROOT/'manifest.json').read_text(encoding='utf-8'))
    db=sqlite3.connect(Path(spec['catalogue']).as_uri()+'?mode=ro',uri=True)
    db.execute('pragma query_only=ON'); db.execute('BEGIN')
    if args.schema:
        tables=[r[0] for r in db.execute("select name from sqlite_master where type='table'")]
        print('\n'.join(tables))
        for name in ['AgLibraryFile','AgLibraryFolder','AgLibraryRootFolder','AgLibraryIPTC','Adobe_AdditionalMetadata','AgLibraryKeyword','AgLibraryKeywordImage','Adobe_imageDevelopSettings']:
            print(name,db.execute(f'pragma table_info({name})').fetchall())
        example=db.execute('select xmp from Adobe_AdditionalMetadata a join Adobe_images i on i.id_local=a.image where i.rating>0 limit 1').fetchone()
        print('XMP EXEMPLE',zlib.decompress(example[0][4:]).decode('utf-8') if example else None)
        develop=db.execute('select text from Adobe_imageDevelopSettings where hasDevelopAdjustmentsEx>0 limit 1').fetchone()
        print('DEVELOP EXEMPLE',[line for line in develop[0].splitlines() if any(k in line for k in ['Temperature','Tint','WhiteBalance','Exposure','Contrast2012'])] if develop else None)
        print('MOTS CLES',db.execute('select id_local,name,parent,includeOnExport from AgLibraryKeyword').fetchall())
        print('LEGENDES',db.execute('select image,caption from AgLibraryIPTC where caption is not null').fetchall())
        return
    checks=[]
    def check(label,condition,detail=None):
        checks.append(dict(controle=label,ok=bool(condition),detail=detail))
    rows=db.execute('''select i.id_local,i.masterImage,i.rating,i.pick,i.captureTime,i.fileFormat,i.colorLabels,
                      r.absolutePath,d.pathFromRoot,f.baseName,f.extension,i.copyName
                      from Adobe_images i join AgLibraryFile f on f.id_local=i.rootFile
                      join AgLibraryFolder d on d.id_local=f.folder
                      join AgLibraryRootFolder r on r.id_local=d.rootFolder''').fetchall()
    records=[]
    for row in rows:
        ident,master,rating,pick,capture,fmt,label,absolute,relative,name,ext,copy=row
        # Lightroom stocke l'absence d'étoiles comme NULL ; elle correspond à la note attendue 0.
        records.append(dict(id=ident,master=master,rating=rating or 0,pick=pick,date=capture,format=fmt,
                            path=str(Path(absolute)/relative/(name+'.'+ext)),copy=copy,label=label))
    normalize=lambda p:str(Path(p)).replace('/','\\').casefold()
    masters={normalize(r['path']):r for r in records if not r['master']}
    virtuals=[r for r in records if r['master']]
    check(str(len(spec['photos']))+' originaux importés',len(masters)==len(spec['photos']),len(masters))
    expected_virtuals=sum(len(e.get('virtuals',[])) for e in spec['photos'])
    check('Copies virtuelles attendues',len(virtuals)==expected_virtuals,dict(attendues=expected_virtuals,presentes=len(virtuals)))
    collections={r[0]:dict(name=r[1],parent=r[2],kind=r[3]) for r in db.execute('select id_local,name,parent,creationId from AgLibraryCollection')}
    def collection_path(cid):
        parts=[]
        while cid:
            cc=collections[cid]; parts.insert(0,cc['name']); cid=cc['parent']
        return parts
    memberships={}
    for image,cid in db.execute('select image,collection from AgLibraryCollectionImage'):
        memberships.setdefault(image,[]).append(collection_path(cid))
    keywords={r[0]:dict(name=r[1],parent=r[2],export=r[3]) for r in db.execute('select id_local,name,parent,includeOnExport from AgLibraryKeyword')}
    def keyword_path(kid):
        parts=[]
        while kid:
            kw=keywords[kid]
            if kw['name'] is not None: parts.insert(0,kw['name'])
            kid=kw['parent']
        return parts
    tags={}
    for image,tag in db.execute('select image,tag from AgLibraryKeywordImage'):
        tags.setdefault(image,[]).append(tag)
    develops={r[0]:(r[1] or r[2],r[3] or '') for r in db.execute('select image,hasDevelopAdjustments,hasDevelopAdjustmentsEx,text from Adobe_imageDevelopSettings')}
    def check_develop(ident,settings,label):
        flag,text=develops.get(ident,(False,''))
        check(label+' développement actif',bool(flag))
        for key,expected in settings.items():
            hit=re.search(r'(?:^|[\s,{])'+re.escape(key)+r'\s*=\s*("[^"]*"|[-+\d.eE]+|true|false)',text)
            value=hit.group(1).strip('"') if hit else None
            if isinstance(expected,(int,float)):
                valid=value is not None and abs(float(value)-expected)<1e-6
            else: valid=value==str(expected)
            check(label+' '+key,valid,value)
    xmps={}
    captions=dict(db.execute('select image,caption from AgLibraryIPTC'))
    for ident,blob in db.execute('select image,xmp from Adobe_AdditionalMetadata'):
        if isinstance(blob,bytes): xmps[ident]=ET.fromstring(zlib.decompress(blob[4:]))
        elif blob: xmps[ident]=ET.fromstring(blob)
    namespaces={'dc':'http://purl.org/dc/elements/1.1/','xmp':'http://ns.adobe.com/xap/1.0/',
                'exif':'http://ns.adobe.com/exif/1.0/'}
    def xmp_value(ident,prefix,key):
        x=xmps.get(ident)
        if x is None: return None
        full='{'+namespaces[prefix]+'}'+key
        for elem in x.iter():
            if full in elem.attrib: return elem.attrib[full]
            if elem.tag==full: return ''.join(elem.itertext()).strip()
        return None
    def coordinate(text):
        if not text: return None
        sign=-1 if text[-1] in 'SW' else 1
        values=[float(n) for n in text[:-1].split(',')]
        return sign*sum(n/(60**i) for i,n in enumerate(values))
    by_case={}
    for case in spec['cas']:
        matches=[cid for cid,c in collections.items() if c['name']==case['id']+' - '+case['titre']]
        check('Collection '+case['id'],len(matches)==1)
        by_case[case['id']]=matches[0] if len(matches)==1 else None
    sdk={}
    for line in (ROOT/'etat-sdk.tsv').read_text(encoding='utf-8').splitlines():
        fields=line.split('\t')
        if fields[0]=='photo': sdk[int(fields[1])]=fields
    for e in spec['photos']:
        p=Path(e['chemin']); r=masters.get(normalize(p))
        check(e['id']+' présent',r is not None)
        check(e['id']+' fichier intact',p.is_file() and hashlib.file_digest(p.open('rb'),'sha256').hexdigest()==e['sha256'])
        if not r: continue
        paths=memberships.get(r['id'],[])
        case=next(c for c in spec['cas'] if c['id']==e['cas'])
        check(e['id']+' dans sa collection',['Sessions - catalogue de test',e['cas']+' - '+case['titre']] in paths)
        for path in e.get('collections',[]): check(e['id']+' collection '+str(path),path in paths)
        for path in e.get('keywords',[]):
            matches=[kid for kid in tags.get(r['id'],[]) if keyword_path(kid)==path]
            check(e['id']+' mot-clé '+str(path),len(matches)==1)
            if path[-1] in e.get('nonexport',[]): check(e['id']+' mot-clé non exporté',bool(matches) and keywords[matches[0]]['export']==0)
        if e.get('develop'): check_develop(r['id'],e['develop'],e['id'])
        for key,col in [('rating','rating'),('pickStatus','pick')]:
            if key in e.get('metadata',{}): check(e['id']+' '+key,r[col]==e['metadata'][key],r[col])
        if 'label' in e.get('metadata',{}):
            check(e['id']+' libellé',r['label']==e['metadata']['label'],r['label'])
        for key,field in [('title','title'),('caption','description'),('creator','creator')]:
            if key in e.get('metadata',{}):
                value=captions.get(r['id']) if key=='caption' else xmp_value(r['id'],'dc',field)
                check(e['id']+' '+key,value==e['metadata'][key],value)
        if 'gps' in e.get('metadata',{}):
            for key,field in [('latitude','GPSLatitude'),('longitude','GPSLongitude')]:
                value=coordinate(xmp_value(r['id'],'exif',field))
                check(e['id']+' GPS '+key,value is not None and abs(value-e['metadata']['gps'][key])<1e-6,value)
        if e['cas'].startswith(('R','B')) or (e['cas']=='E03' and p.name!='sans-date.jpg'):
            check(e['id']+' date de prise de vue',bool(r['date']),r['date'])
        if e['cas']=='E03' and p.name=='sans-date.jpg':
            original=xmp_value(r['id'],'exif','DateTimeOriginal')
            check('Absence de date EXIF E03',not original,original)
            check('Absence de date SDK E03',sdk.get(r['id'],[])[6:7]==['nil'])
        if (e['cas']=='E03' or e['cas'].startswith('W')) and p.suffix=='.dng':
            jpeg=masters.get(normalize(p.with_suffix('.jpg')))
            check(e['id']+' date RAW+JPEG identique',jpeg is not None and sdk.get(r['id'],[])[6:7]==sdk.get(jpeg['id'],[])[6:7] and sdk.get(r['id'],[])[6:7]!=['nil'])
        for v in e.get('virtuals',[]):
            check(e['id']+' virtuelle '+v['name'],any(x['master']==r['id'] and x['copy']==v['name'] for x in virtuals))
        expected_copies=e.get('virtuals',[])
        actual_copies=sorted((x for x in virtuals if x['master']==r['id']),key=lambda x:x['id'])
        check(e['id']+' nombre de virtuelles',len(expected_copies)==len(actual_copies))
        for i,(v,actual) in enumerate(zip(expected_copies,actual_copies)):
            label=e['id']+' virtuelle '+str(i+1)
            check(label+' nom',v['name']==actual['copy'])
            if v.get('develop'): check_develop(actual['id'],v['develop'],label)
            for path in v.get('collections',[]): check(label+' collection '+str(path),path in memberships.get(actual['id'],[]))
            for key,col in [('rating','rating'),('pickStatus','pick')]:
                if key in v.get('metadata',{}): check(label+' '+key,actual[col]==v['metadata'][key])
    # Vérifier que tous les MP4 sont décodables ; aucune publication réseau.
    for e in spec['photos']:
        if e['chemin'].endswith('.mp4'):
            result=subprocess.run(['ffprobe','-v','error','-select_streams','v:0','-show_entries','stream=codec_name,width,height','-of','json',e['chemin']],capture_output=True,text=True)
            check(e['id']+' MP4 valide',result.returncode==0 and bool(json.loads(result.stdout).get('streams')),result.stderr or None)
    summary=dict(catalogue=spec['catalogue'],scenarios=len(spec['cas']),originaux=len(masters),virtuelles=len(virtuals),
                 controles=len(checks),echecs=[c for c in checks if not c['ok']],verifications=checks)
    (ROOT/'verification.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps({k:v for k,v in summary.items() if k!='verifications'},ensure_ascii=False,indent=2))
    raise SystemExit(bool(summary['echecs']))

if __name__=='__main__': main()
