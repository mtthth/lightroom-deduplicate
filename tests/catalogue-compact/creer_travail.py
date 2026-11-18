"""Crée un catalogue de travail à partir de la sauvegarde Lightroom fermée."""
import json
from pathlib import Path
import shutil
from generer import lua

repo=Path(__file__).resolve().parents[2]
root=repo/'sortie'/'catalogue-compact'
spec=json.loads((root/'manifest.json').read_text(encoding='utf-8'))
old=spec['catalogue']
assert not Path(old+'.lock').exists(), 'Fermer Lightroom avant de créer la copie de travail.'
execution=root/'execution'
execution.mkdir(exist_ok=False)
backup=root/'etat-initial'
cat=execution/'Deduplicate-execution.lrcat'
shutil.copyfile(backup/'Deduplicate-compact.lrcat',cat)
shutil.copytree(backup/'Deduplicate-compact.lrcat-data',execution/'Deduplicate-execution.lrcat-data')
spec['catalogue']=str(cat)
(root/'manifest.json').write_text(json.dumps(spec,ensure_ascii=False,indent=2),encoding='utf-8')
(root/'Manifeste.lua').write_text('return '+lua(spec),encoding='utf-8')
plugin=root/'environnement'/'lightroom-deduplicate'/'lightroom-deduplicate.lrplugin'
info=plugin/'Info.lua'
text=info.read_text(encoding='utf-8')
if 'LrForceInitPlugin' not in text:
    info.write_text(text.replace("LrInitPlugin = 'Initialiser.lua',", "LrInitPlugin = 'Initialiser.lua',\n  LrForceInitPlugin = true,"),encoding='utf-8')
for name in ['Initialiser','FusionnerDoublons','FusionManuelle','ReduireRafales','RestaurerCollections','DiagnosticCatalogue','TestManquant','TestModifier','TestRestaurer']:
    p=plugin/(name+'.lua'); t=p.read_text(encoding='utf-8'); assert json.dumps(old,ensure_ascii=False) in t
    p.write_text(t.replace(json.dumps(old,ensure_ascii=False),json.dumps(str(cat),ensure_ascii=False)),encoding='utf-8')
shutil.copyfile(Path(__file__).with_name('Campagne.lua'),plugin/'Campagne.lua')
shutil.copyfile(repo.parent/'lightroom-album-of-the-year'/'AlbumAnnuel.lrdevplugin'/'Json.lua',plugin/'TestJson.lua')
p=plugin/'Initialiser.lua'
p.write_text(p.read_text(encoding='utf-8')+"\ndofile(import('LrPathUtils').child(_PLUGIN.path,'Campagne.lua'))\n",encoding='utf-8')
archive=root/'campagne'/'analyse-native-initiale'
archive.mkdir(parents=True)
for name in ['doublons.csv','diagnostic-lectures-doublons.txt']:
    shutil.copyfile(plugin.parent/name,archive/name)
shutil.copytree(plugin.parent/'rapport-doublons',archive/'rapport-doublons')
print(cat)
