"""Copie isolée du plugin et module de préparation borné au catalogue de test."""
from pathlib import Path
import json
import shutil

repo=Path(__file__).resolve().parents[2]
root=repo/'sortie'/'catalogue-compact'
assert not (root/'etat-initial/inventaire.json').exists() and not (root/'execution').exists(), 'Campagne déjà préparée : ne pas écraser les modules et historiques isolés.'
spec=json.loads((root/'manifest.json').read_text(encoding='utf-8'))
helper=root/'preparation.lrplugin'
helper.mkdir(exist_ok=True)
shutil.copyfile(Path(__file__).with_name('Preparation.lua'),helper/'Preparation.lua')
(helper/'Init.lua').write_text("require('Preparation').demarrer()\n",encoding='utf-8')
(helper/'Lancer.lua').write_text("require('Preparation').demarrer()\n",encoding='utf-8')
(helper/'Info.lua').write_text("""return {
 LrSdkVersion=13.0, LrSdkMinimumVersion=6.0,
 LrToolkitIdentifier='io.github.mtthth.deduplicate.catalogue-compact',
 LrPluginName='Catalogue compact - préparation', LrInitPlugin='Init.lua', LrForceInitPlugin=true,
 LrLibraryMenuItems={{title='TEST : préparer le catalogue compact', file='Lancer.lua'}},
 VERSION={major=1,minor=0,revision=0},
}
""",encoding='utf-8')
env=root/'environnement'
dest=env/'lightroom-deduplicate'/'lightroom-deduplicate.lrplugin'
shutil.copytree(repo/'lightroom-deduplicate.lrplugin',dest,dirs_exist_ok=True,ignore=shutil.ignore_patterns('__pycache__'))
neighbor=env/'lightroom-google-photos'/'albums-google-photos.lrplugin'
shutil.copytree(repo.parent/'lightroom-google-photos'/'albums-google-photos.lrplugin',neighbor,dirs_exist_ok=True,ignore=shutil.ignore_patterns('__pycache__'))
info=(dest/'Info.lua').read_text(encoding='utf-8').replace("'io.github.mtthth.deduplicate'","'io.github.mtthth.deduplicate.compact'").replace("LrPluginName = 'Deduplicate'","LrPluginName = 'Deduplicate - TEST compact'")
menu="""    { title = 'TEST : rendre E01 manquant', file = 'TestManquant.lua' },
    { title = 'TEST : modifier E02 après analyse', file = 'TestModifier.lua' },
    { title = 'TEST : restaurer les fichiers E01 E02', file = 'TestRestaurer.lua' },
"""
info=info.replace('LrLibraryMenuItems = {','LrLibraryMenuItems = {\n'+menu)
(dest/'Info.lua').write_text(info,encoding='utf-8')
catalog=json.dumps(spec['catalogue'],ensure_ascii=False)
guard=f"""local c = import('LrApplication').activeCatalog()
if not c or c:getPath():gsub('/', '\\\\'):lower() ~= ({catalog}):gsub('/', '\\\\'):lower() then return end
"""
for name in ['Initialiser','FusionnerDoublons','FusionManuelle','ReduireRafales','RestaurerCollections','DiagnosticCatalogue']:
    p=dest/f'{name}.lua'; p.write_text(guard+p.read_text(encoding='utf-8'),encoding='utf-8')
for name,command in [('TestManquant','manquant'),('TestModifier','modifier'),('TestRestaurer','restaurer')]:
    (dest/f'{name}.lua').write_text(guard+f"""
import('LrTasks').startAsyncTask(function()
  local p={json.dumps(str(root/'commande.txt'),ensure_ascii=False)}
  local f=assert(io.open(p,'wb')); f:write('{command}'); f:close()
end)
""",encoding='utf-8')
history='# type\tchemin\tfichier\tdate_prise_de_vue\n# historique-commun-deduplicate-google-v1\n'
for e in spec['photos']:
    if e.get('excluded'): history+=f"doublon\t{e['chemin']}\t{Path(e['chemin']).name}\t2024-01-21 12:00:00\n"
(env/'lightroom-google-photos'/'photos-traitees.txt').write_text(history,encoding='utf-8')
(root/'commande.txt').write_text('initialiser',encoding='utf-8')
print(helper)
print(dest)
