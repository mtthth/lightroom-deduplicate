"""Contrôle statique des traductions : chaque appel T(français, anglais) du module garde les mêmes
spécificateurs de format (%d, %s…) dans le même ordre, et le texte anglais n'emprunte pas la typographie
française (guillemets « », espace avant les deux-points). Seuls les morceaux littéraux sont comparés."""
import pathlib
import re
import unittest

PLUGIN = pathlib.Path(__file__).resolve().parents[1] / 'lightroom-deduplicate.lrplugin'
APPEL = re.compile(r"(?<![\w.])(?:T|require\('Langue'\)\.t|require\(\"Langue\"\)\.t|Langue\.t)\(")
FORMAT = re.compile(r'%[-+ #0-9.]*[dsfqxXgi%]')


def arguments(source, debut):
    """Arguments d'un appel, à partir de la parenthèse ouvrante : liste de listes de littéraux."""
    args, courant, profondeur, i = [], [], 1, debut
    while i < len(source):
        c = source[i]
        if c in '\'"':
            fin, morceau = i + 1, []
            while source[fin] != c:
                if source[fin] == '\\':
                    morceau.append(source[fin:fin + 2]); fin += 2
                else:
                    morceau.append(source[fin]); fin += 1
            if profondeur == 1:
                courant.append(''.join(morceau))
            i = fin + 1
            continue
        if c == '-' and source.startswith('--', i):
            i = source.index('\n', i)
            continue
        if c in '({[':
            profondeur += 1
        elif c in ')}]':
            profondeur -= 1
            if profondeur == 0:
                args.append(courant)
                return args
        elif c == ',' and profondeur == 1:
            args.append(courant); courant = []
        i += 1
    raise ValueError('appel non fermé')


def paires():
    for fichier in sorted(PLUGIN.glob('*.lua')):
        source = fichier.read_text(encoding='utf-8')
        for m in APPEL.finditer(source):
            ligne = source.count('\n', 0, m.start()) + 1
            args = arguments(source, m.end())
            if len(args) >= 2:
                yield fichier.name, ligne, ''.join(args[0]), ''.join(args[1])


class Traductions(unittest.TestCase):
    def test_paires(self):
        vues = list(paires())
        self.assertGreater(len(vues), 300, 'trop peu de traductions trouvées : le contrôle ne lit plus le code')
        erreurs = []
        for nom, ligne, fr, en in vues:
            if FORMAT.findall(fr) != FORMAT.findall(en):
                erreurs.append(f'{nom}:{ligne} formats différents : {FORMAT.findall(fr)} / {FORMAT.findall(en)}')
            if '«' in en or '»' in en:
                erreurs.append(f'{nom}:{ligne} guillemets français dans le texte anglais')
            if re.search(r'\w :', en):
                erreurs.append(f'{nom}:{ligne} espace avant les deux-points dans le texte anglais')
            if not en.strip() and fr.strip():
                erreurs.append(f'{nom}:{ligne} traduction anglaise vide')
        self.assertEqual(erreurs, [], '\n'.join(erreurs))


if __name__ == '__main__':
    unittest.main()
