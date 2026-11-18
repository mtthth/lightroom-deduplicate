"""Équivalences vérifiées des états internes matérialisés par Lightroom."""
from campagne import *
import difflib

def equivalents():
    texts={}
    for path in [ROOT/'etat-initial/Deduplicate-grand.lrcat',Path(SPEC['catalogue'])]:
        with sqlite3.connect(path.resolve().as_uri()+'?mode=ro',uri=True) as db:
            db.execute('pragma query_only=ON')
            for (text,) in db.execute('select distinct text from Adobe_imageDevelopSettings'):
                text=text or ''
                texts[hashlib.sha256(text.encode()).hexdigest()]=text
    mapping={}; groups={}
    for digest,text in texts.items():
        # Le nom CameraProfile demeure comparé. Seule son empreinte de résolution
        # interne est écartée. Un FilterList explicitement vide équivaut à son absence.
        normalized=re.sub(r'(?m)^CameraProfileDigest\s*=.*\r?\n','',text)
        normalized=re.sub(r'(?m)^FilterList\s*=\s*\{\s*\},\r?\n','',normalized)
        key=hashlib.sha256(normalized.encode()).hexdigest()
        mapping[digest]=key; groups.setdefault(key,[]).append(digest)
    proof=[]
    for hashes in groups.values():
        if len(hashes)>1:
            first=hashes[0]
            for second in hashes[1:]:
                proof.append(dict(avant=first,apres=second,difference=''.join(difflib.unified_diff(texts[first].splitlines(True),texts[second].splitlines(True)))))
    (OUT/'equivalences-developpement.json').write_text(json.dumps(dict(regles=['CameraProfileDigest : identifiant interne ; CameraProfile comparé', 'FilterList vide explicite ou absent'],equivalences=proof,hashes_canoniques=mapping),ensure_ascii=False,indent=2),encoding='utf-8')
    return mapping

def equivalent_state(a,b,mapping):
    def normalize(state):
        result=dict(state); result['photos']={}
        for i,p in state['photos'].items():
            row=dict(p)
            if 'develop_sha256' in row: row['develop_sha256']=mapping.get(row['develop_sha256'],row['develop_sha256'])
            result['photos'][i]=row
        return result
    return normalize(a)==normalize(b)

def sdk_state(state):
    result=json.loads(json.dumps(state))
    for p in result.get('photos',[]):
        develop=p.get('develop',{})
        if develop.get('FilterList') in ({},[]): develop.pop('FilterList',None)
        if develop.get('WhiteBalance')=='Auto' and 'AutoWhiteVersion' not in develop:
            # Version matérialisée par la lecture SDK sur la copie Auto de D19.
            # Une autre version explicite reste une différence détectable.
            develop['AutoWhiteVersion']=134348800
        if develop.get('WhiteBalance')=='As Shot' and p.get('path','').lower().endswith('.dng'):
            # Même valeur obtenue sur W050 par sélection/lecture seules, sans commande
            # du module : contrôle enregistré dans controle-lecture-w050*.json.
            if 'Temperature' not in develop and 'Tint' not in develop:
                develop['Temperature']=5450; develop['Tint']=-13
    return result
