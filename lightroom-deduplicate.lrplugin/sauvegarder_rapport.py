"""Capture l'état courant des collections des seules photos à fusionner d'un rapport existant."""
import datetime
from html.parser import HTMLParser
import pathlib
import re
import sys
from collections_readonly import snapshot


class Rapport(HTMLParser):
    def __init__(self):
        super().__init__(); self.fusion = False; self.role = None; self.id = None; self.photos = {}; self.groupes = 0

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == 'article':
            self.fusion = 'fusion' in a.get('class', '').split()
            if self.fusion: self.groupes += 1
        elif self.fusion and tag == 'figure':
            self.role = {'garder': 'gardee', 'retirer': 'ecartee'}.get(a.get('class')); self.id = None
        elif self.fusion and self.role and tag == 'img':
            match = re.fullmatch(r'vignettes/(\d+)-\d+\.jpg', a.get('src', ''))
            if match: self.id = int(match[1])
        elif self.fusion and self.role and tag == 'b' and a.get('title'):
            if self.id is None:
                raise ValueError('Ce rapport doit comporter les miniatures avec identifiants de photo')
            self.photos[self.id] = (self.role, a['title'])

    def handle_endtag(self, tag):
        if tag == 'article': self.fusion = False
        elif tag == 'figure': self.role = None; self.id = None


def esc(s):
    return str(s).replace('\\', '\\\\').replace('\t', '\\t').replace('\r', '\\r').replace('\n', '\\n')


def main(catalog, report, folder):
    parsed = Rapport(); parsed.feed(pathlib.Path(report).read_text(encoding='utf-8'))
    if not parsed.photos or sum(role == 'gardee' for role, _ in parsed.photos.values()) != parsed.groupes:
        raise ValueError('Rapport incomplet ou sans groupes à fusionner')
    data = snapshot(catalog, parsed.photos)
    nodes, links = {}, []
    for line in data.splitlines():
        f = line.split('\t')
        if f[0] == 'C': nodes[int(f[1])] = (int(f[2]), bytes.fromhex(f[3]).decode('utf-8'))
        elif f[0] == 'L': links.append((int(f[1]), int(f[2])))
    collections = {cid for _, cid in links}
    now = datetime.datetime.now()
    lines = ['SAUVEGARDE_COLLECTIONS_V1',
             '# État des appartenances au moment de cette capture, pour le rapport existant. Métadonnées/retouches non sauvegardées.',
             '# Les prochaines fusions créent automatiquement une sauvegarde juste avant application.',
             'CATALOGUE\t' + esc(catalog), 'DATE\t' + str(now), 'TYPE\trapport_courant']
    for pid, (role, path) in parsed.photos.items():
        lines.append(f'PHOTO\t{pid}\t{role}\t0\t{esc(path)}')
    for cid, (parent, name) in nodes.items():
        lines.append(f'NOEUD\t{cid}\t{parent}\t' + ('collection' if cid in collections else 'ensemble') + '\t' + esc(name))
    for pid, cid in links:
        names, n = [], cid
        while n:
            parent, name = nodes[n]; names.insert(0, name); n = parent
        lines.append(f'MEMBRE\t{pid}\t{cid}\t' + esc(' / '.join(names)))
    lines.append(f'FIN\t{len(parsed.photos)}\t{len(links)}')
    folder = pathlib.Path(folder); folder.mkdir(parents=True, exist_ok=True)
    path = folder / ('collections-rapport-' + now.strftime('%Y%m%d-%H%M%S-%f') + '.txt')
    with path.open('x', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(lines) + '\n')
    print(str(path)); print(f'{parsed.groupes} groupes, {len(parsed.photos)} photos, {len(links)} appartenances')


if __name__ == '__main__':
    main(*sys.argv[1:])
