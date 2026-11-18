// Suites autonomes Deduplicate. Les diagnostics sur un vrai catalogue restent des commandes manuelles.
import { execFileSync } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, mkdtempSync, rmSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

if (process.argv.length > 2) {
  console.error('Usage : node tests/lancer.mjs');
  process.exit(2);
}
const racine = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
// Premier exécutable trouvé sur le PATH (hors alias du Microsoft Store, qui n'installent rien).
function surChemin(...noms) {
  for (const nom of noms) {
    try {
      const sortie = execFileSync(process.platform === 'win32' ? 'where' : 'which', [nom],
        { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
      const trouve = sortie.split(/\r?\n/).find((p) => p && !/WindowsApps/i.test(p));
      if (trouve) return trouve;
    } catch { /* absent */ }
  }
  return undefined;
}
// Lua 5.3 : TEXLUA ou LUA, sinon texlua de MiKTeX, sinon lua5.3, lua ou texlua sur le PATH.
const lua = process.env.TEXLUA || process.env.LUA || [
  path.join(process.env.LOCALAPPDATA ?? '', 'Programs/MiKTeX/miktex/bin/x64/texlua.exe'),
  path.join(os.homedir(), 'AppData/Local/Programs/MiKTeX/miktex/bin/x64/texlua.exe'),
].find((p) => existsSync(p)) || surChemin('lua5.3', 'lua', 'texlua');
// Python 3.12+ : PYTHON, sinon C:\Python3xx, sinon python sur le PATH.
const python = process.env.PYTHON || [
  'C:/Python314/python.exe', 'C:/Python313/python.exe', 'C:/Python312/python.exe',
].find((p) => existsSync(p)) || surChemin('python3', 'python');
if (!lua || !python) {
  console.error('Lua 5.3 (texlua de MiKTeX ou lua) et Python 3.12+ sont nécessaires. '
    + 'Utilise TEXLUA (ou LUA) et PYTHON pour leurs chemins.');
  process.exit(2);
}

const suitesLua = [
  'catalogue', 'cas-prioritaires', 'choix', 'collections-rapides', 'copies-virtuelles', 'historique-commun',
  'journal-annulable', 'libelles-restauration', 'libelles-personnalises', 'retouches-video', 'rafales-sessions', 'rapport-doublons', 'rapport-rafales',
  'revalidation-fichiers', 'migration', 'sauvegarde-collections', 'trace-lectures', 'vignettes-ping', 'recherche-cache', 'empreintes-jpeg',
];
const suitesPython = ['test_cache_analyses', 'test_collections_readonly'];
const scratch = mkdtempSync(path.join(os.tmpdir(), 'deduplicate-tests-'));
let echecs = 0;
function lancer(nom, executable, args) {
  try {
    const sortie = execFileSync(executable, args, {
      cwd: scratch, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'],
      env: { ...process.env, PYTHONDONTWRITEBYTECODE: '1' },
    });
    console.log(`ok      ${nom}${sortie.trim() ? '\n' + sortie.trim() : ''}`);
  } catch (erreur) {
    echecs++;
    console.error(`ÉCHEC   ${nom}\n${erreur.stdout ?? ''}${erreur.stderr ?? ''}${erreur.code ?? ''}`);
  }
}
try {
  // Le cache d'intégration et les fixtures Python sont créés dans cette copie temporaire.
  cpSync(path.join(racine, 'lightroom-deduplicate.lrplugin'), path.join(scratch, 'lightroom-deduplicate.lrplugin'),
    { recursive: true, filter: (p) => path.basename(p) !== '__pycache__' });
  mkdirSync(path.join(scratch, 'tests'));
  cpSync(path.join(racine, 'tests/video-vierge-lr15.lua'), path.join(scratch, 'tests/video-vierge-lr15.lua'));
  for (const fichier of [...suitesLua.map((s) => s + '.lua'), ...suitesPython.map((s) => s + '.py')]) {
    cpSync(path.join(racine, 'tests', fichier), path.join(scratch, 'tests', fichier));
  }
  for (const nom of suitesLua) {
    lancer(nom, lua, [path.join('tests', nom + '.lua'), scratch, scratch, python]);
  }
  for (const nom of suitesPython) lancer(nom, python, [path.join('tests', nom + '.py')]);
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
process.exitCode = echecs === 0 ? 0 : 1;
