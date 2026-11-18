-- Rapport HTML de « Fusionner les doublons » : montre, avant toute modification, ce que la commande ferait,
-- groupe par groupe (miniatures, copie gardée et pourquoi, ce qui change dans les collections et les
-- métadonnées). Pur Lua, sans appel à Lightroom, pour pouvoir être testé à part.
--
-- Le rapport est construit à partir des mêmes décisions et du même plan (Doublons.decider et
-- Doublons.effets) que ceux que la commande applique : il ne peut pas annoncer autre chose que ce qui sera fait.
-- Chaque groupe porte une case : « Ne pas fusionner » pour un groupe proposé, « Fusionner de force » (avec le
-- choix de la copie gardée) pour un groupe « à vérifier ». Ces choix forment un code à coller dans Lightroom
-- (voir Choix.lua) ; le navigateur les garde pour l'analyse affichée.
--
-- Modèle (table passée à page) :
--   portee      texte : « les 312 photos sélectionnées »…
--   date        texte : date du rapport
--   identifiant identifiant de l'analyse (Choix.identifiant), repris dans le code des choix
--   collection  nom de la collection où vont les copies retirées
--   decisions   liste de décisions (Doublons.decider) ; celles sans aVerifier portent un champ effets ; celles
--               marquées versions (Doublons.deciderVersions) sont les versions conservées à part, à forcer au besoin
--   vignette    fonction(copie) → chemin relatif de l'aperçu, ou nil
--   notes       phrases à ajouter en bas (fichiers illisibles, ImageMagick absent…)

local Doublons = require 'Doublons'
local Epoques = require 'Epoques'
local Similitude = require 'Similitude'

local M = {}

local function h(texte)
  return (tostring(texte):gsub('[&<>"\']', {
    ['&'] = '&amp;', ['<'] = '&lt;', ['>'] = '&gt;', ['"'] = '&quot;', ["'"] = '&#39;',
  }))
end

local Langue = require 'Langue'
local T = Langue.t

local function pluriel(n, singulier, plur)
  return n .. ' ' .. (n > 1 and (plur or (singulier .. 's')) or singulier)
end

local function nomFichier(chemin)
  return chemin:match('[^/\\]+$') or chemin
end

local function taille(octets)
  octets = octets or 0
  if Langue.anglais() then
    if octets >= 1024 ^ 3 then return string.format('%.2f GB', octets / 1024 ^ 3) end
    if octets >= 1024 ^ 2 then return string.format('%.1f MB', octets / 1024 ^ 2) end
    return string.format('%d KB', math.floor(octets / 1024 + 0.5))
  end
  if octets >= 1024 ^ 3 then return (string.format('%.2f Go', octets / 1024 ^ 3):gsub('%.', ',')) end
  if octets >= 1024 ^ 2 then return (string.format('%.1f Mo', octets / 1024 ^ 2):gsub('%.', ',')) end
  return string.format('%d Ko', math.floor(octets / 1024 + 0.5))
end

local function dateTexte(date)
  return date and Epoques.texte(Epoques.depuisLightroom(date, 0)) or T('date inconnue', 'unknown date')
end

-- Les trois derniers dossiers du chemin : « … / 2018 / 2018-08-12 ».
local function dossierCourt(chemin)
  local parties = {}
  for partie in (chemin:gsub('\\', '/')):gmatch('[^/]+') do parties[#parties + 1] = partie end
  table.remove(parties)   -- le nom du fichier
  local debut = math.max(1, #parties - 2)
  local texte = table.concat(parties, ' / ', debut)
  return (debut > 1 and '… / ' or '') .. texte
end

local function dossierComplet(chemin)
  return ((chemin:gsub('\\', '/')):gsub('/[^/]*$', ''))
end

-- Adresse file:/// d'un fichier, pour l'ouvrir dans le navigateur (espaces et accents encodés).
function M.urlFichier(chemin)
  local c = chemin:gsub('\\', '/')
  c = c:gsub('[^%w%-%._~/:]', function(x) return string.format('%%%02X', x:byte()) end)
  return 'file:///' .. c
end

local function badge(classe, texte)
  return string.format('<span class="badge %s">%s</span>', classe, h(texte))
end

-- Ce qui distingue une copie, en pastilles (retouches, copies virtuelles, notes, mots-clés…).
local function badges(c)
  local b = {}
  if Similitude.nomRetouche(nomFichier(c.chemin)) then b[#b + 1] = badge('b-nom', T('nom de retouche', 'edit name')) end
  if c.retouchee then b[#b + 1] = badge('b-lr', T('retouchée dans Lightroom', 'edited in Lightroom')) end
  if (c.virtuelles or 0) > 0 then b[#b + 1] = badge('b-lr', pluriel(c.virtuelles, T('copie virtuelle', 'virtual copy'), T('copies virtuelles', 'virtual copies'))) end
  if c.publiee then b[#b + 1] = badge('b-lr', T('publiée', 'published')) end
  if c.dejaEcartee then b[#b + 1] = badge('b-nom', T('déjà écartée', 'already set aside')) end
  if (c.note or 0) > 0 then b[#b + 1] = badge('', string.rep('★', c.note)) end
  if c.drapeau == 1 then b[#b + 1] = badge('', T('retenue', 'picked')) elseif c.drapeau == -1 then b[#b + 1] = badge('', T('rejetée', 'rejected')) end
  if c.motsCles and #c.motsCles > 0 then b[#b + 1] = badge('', pluriel(#c.motsCles, T('mot-clé', 'keyword'), T('mots-clés', 'keywords'))) end
  local nbCollections = 0
  for _, col in ipairs(c.collections or {}) do
    if not col.dynamique and not col.exclue then nbCollections = nbCollections + 1 end
  end
  if nbCollections > 0 then b[#b + 1] = badge('', pluriel(nbCollections, 'collection')) end
  return table.concat(b)
end

local function libelles()
  return { garder = T('Gardée', 'Kept'), retirer = T('Retirée', 'Removed'), verifier = T('À vérifier', 'To check'),
    serait = T('Serait gardée', 'Would be kept'), apart = T('Conservée', 'Kept apart') }
end

-- numero, rang : pour une copie d'un groupe « à vérifier », le bouton qui la garde si le groupe est forcé
-- (rang 1 : la copie qui serait gardée, puis les autres dans l'ordre du groupe).
local function figure(c, role, vignette, numero, rang)
  local chemin = vignette and vignette(c)
  local image = chemin and string.format('<img src="%s" alt="" loading="lazy" decoding="async">', h(chemin))
    or '<div class="vide">' .. T('pas d’aperçu', 'no preview') .. '</div>'
  local infos = {}
  if c.dimensions then infos[#infos + 1] = c.dimensions end
  infos[#infos + 1] = taille(c.octets or c.taille)
  infos[#infos + 1] = dateTexte(c.date)
  local garde = numero and string.format(
    '<label class="garde"><input type="radio" name="garde%d" value="%d"%s> ' .. T('garder celle-ci', 'keep this one') .. '</label>',
    numero, rang, rang == 1 and ' checked' or '') or ''
  return string.format(
    '<figure class="%s%s"><div class="img">%s<em data-libelle="%s">%s</em></div><figcaption><b title="%s">%s</b>'
    .. '<small title="%s">%s</small><small>%s</small><div class="badges">%s</div>%s</figcaption></figure>',
    role == 'serait' and 'garder' or role, c.video and ' video' or '', image, h(libelles()[role]), h(libelles()[role]), h(c.chemin),
    h(nomFichier(c.chemin)), h(dossierComplet(c.chemin)), h(dossierCourt(c.chemin)), h(table.concat(infos, ' · ')),
    badges(c), garde)
end

local function liste(elements)
  local items = {}
  for _, e in ipairs(elements) do items[#items + 1] = '<li>' .. e .. '</li>' end
  return '<ul>' .. table.concat(items) .. '</ul>'
end

local function guillemets(noms)
  local r = {}
  for i, n in ipairs(noms) do r[i] = T('« ' .. h(n) .. ' »', '“' .. h(n) .. '”') end
  return table.concat(r, ', ')
end

-- Les changements d'un groupe fusionné, en phrases (voir Doublons.effets).
local function lignesEffets(e, collectionARetirer)
  local l = {}
  if #(e.corbeillesGardee or {}) > 0 then
    local noms = {}
    for _, col in ipairs(e.corbeillesGardee) do noms[#noms + 1] = col.nom end
    l[#l + 1] = T('La copie gardée quitte les collections de retrait : ', 'The kept copy leaves the removal collections: ') .. guillemets(noms)
  end
  if #e.collections > 0 then
    local noms = {}
    for i, col in ipairs(e.collections) do noms[i] = col.nom end
    l[#l + 1] = T('La copie gardée rejoint ', 'The kept copy joins ') .. pluriel(#noms, 'collection') .. T(' : ', ': ') .. guillemets(noms)
  end
  local quittees, vues = {}, {}
  for _, q in ipairs(e.quittees) do
    if not vues[q.collection.id] then
      vues[q.collection.id] = true
      quittees[#quittees + 1] = q.collection.nom
    end
  end
  if #quittees > 0 then l[#l + 1] = T('Les copies retirées sortent de : ', 'The removed copies leave: ') .. guillemets(quittees) end
  if #e.motsCles > 0 then
    local noms = {}
    for i, mot in ipairs(e.motsCles) do noms[i] = mot.nom end
    l[#l + 1] = T('Mots-clés ajoutés : ', 'Keywords added: ') .. guillemets(noms)
  end
  if e.note then l[#l + 1] = T('Note relevée à ', 'Rating raised to ') .. string.rep('★', e.note) end
  if e.drapeau then
    local choix = e.drapeau == 1 and T('retenue', 'picked') or T('rejetée', 'rejected')
    l[#l + 1] = T('Drapeau « ' .. choix .. ' » recopié', '“' .. choix .. '” flag copied')
  end
  for _, t in ipairs(e.textes) do
    l[#l + 1] = h(Doublons.nomChamp(t.cle)) .. T(' recopié(e) : ', ' copied: ') .. h(t.valeur)
  end
  if e.gps then l[#l + 1] = T('Position GPS recopiée', 'GPS position copied') end
  l[#l + 1] = T('Les copies retirées vont dans la collection « ' .. h(collectionARetirer) .. ' » : rien n’est supprimé.', 'The removed copies go to the “' .. h(collectionARetirer) .. '” collection: nothing is deleted.')
  return l
end

local function texteRecherche(copies)
  local t = {}
  for _, c in ipairs(copies) do t[#t + 1] = (nomFichier(c.chemin) .. ' ' .. dossierComplet(c.chemin)):lower() end
  return table.concat(t, ' ')
end

-- Identifiants des photos d'un groupe, pour repérer dans la page les groupes qui en partagent.
local function idsTexte(copies)
  local t = {}
  for _, c in ipairs(copies) do t[#t + 1] = h(c.id) end
  return table.concat(t, ' ')
end

-- Carte d'un groupe fusionné (classe « fusion ») ou laissé tel quel (classe « verifier »).
local function carteDecision(numero, d, m)
  local verifier = d.aVerifier ~= nil
  local copies = { d.garde }
  for _, c in ipairs(d.retirees) do copies[#copies + 1] = c end
  local choixGarde = verifier and numero or nil
  local reunion = d.reunis and string.format('<p class="pourquoi">' .. T('Ce groupe réunit %d groupes qui avaient des photos '
    .. 'en commun (mêmes copies et autres versions de la même photo) : forcé, il ne garde qu’une seule copie.', 'This group '
    .. 'combines %d groups that shared photos (same copies and other versions of the same photo): forced, it keeps only one copy.') .. '</p>',
    d.reunis) or ''
  local figures = { figure(d.garde, d.versions and 'apart' or verifier and 'serait' or 'garder', m.vignette, choixGarde, 1) }
  for i, c in ipairs(d.retirees) do
    figures[#figures + 1] = figure(c, d.versions and 'apart' or verifier and 'verifier' or 'retirer', m.vignette,
      choixGarde, i + 1)
  end

  local choix, corps
  if d.versions then
    local retouche = false
    for _, c in ipairs(copies) do
      if Similitude.nomRetouche(nomFichier(c.chemin)) then retouche = true end
    end
    choix = '<label class="choix"><input type="checkbox" class="force"> ' .. T('Fusionner de force', 'Force merge') .. '</label>'
    corps = '<p class="pourquoi">' .. (retouche
        and T('La version dont le nom annonce une retouche ne montre pas la même vue que les autres copies.',
          'The version whose name announces an edit does not show the same view as the other copies.')
        or T('Les images diffèrent (version retouchée, recadrée ou recompressée).', 'The images differ (edited or recompressed version).'))
      .. (d.aVerifier ~= Doublons.raisonVersions() and (' ' .. h(d.aVerifier) .. '.') or '')
      .. T(' <b>Tout est conservé</b>, sauf si vous cochez « Fusionner de force » : choisissez alors la copie à garder '
      .. '(proposée : ', ' <b>Everything is kept</b>, unless you tick “Force merge”: then choose the copy to keep '
      .. '(proposed: ') .. h(nomFichier(d.garde.chemin)) .. ', ' .. h(d.pourquoi or '') .. T('). Les retouches Lightroom '
      .. 'et publications des copies écartées ne sont pas transférées.', '). Lightroom edits and publications of the '
      .. 'discarded copies are not transferred.') .. '</p>' .. reunion
    return string.format(
      '<article class="carte apart" id="g%d" data-g="%d" data-type="apart" data-ids="%s" data-q="%s"><h3>' .. T('Groupe', 'Group')
      .. ' %d <small>%s · %s · ' .. T('versions différentes', 'different versions') .. '</small></h3>%s<div class="copies">%s</div>%s</article>',
      numero, numero, idsTexte(copies), h(texteRecherche(copies)), numero, h(nomFichier(d.garde.chemin)), h(dateTexte(d.garde.date)),
      choix, table.concat(figures), corps)
  elseif verifier then
    choix = '<label class="choix"><input type="checkbox" class="force"> ' .. T('Fusionner de force', 'Force merge') .. '</label>'
    corps = '<p class="pourquoi">' .. T('À vérifier : ', 'To check: ') .. h(d.aVerifier) .. T('. <b>Rien ne sera fait pour ce groupe</b>, sauf si '
      .. 'vous cochez « Fusionner de force » : choisissez alors la copie à garder. Les retouches Lightroom et publications '
      .. 'des copies écartées ne sont pas transférées ; leurs copies virtuelles (hors vidéos) sont recréées sur la copie '
      .. 'gardée.', '. <b>Nothing will be done for this group</b>, unless you tick “Force merge”: then choose the copy '
      .. 'to keep. Lightroom edits and publications of the discarded copies are not transferred; their virtual copies '
      .. '(except videos) are recreated on the kept copy.') .. '</p>' .. reunion
  else
    choix = '<label class="choix"><input type="checkbox" class="non"> ' .. T('Ne pas fusionner ', 'Do not merge ')
      .. '<small>' .. T('(mémorisé : le groupe restera « à vérifier » aux prochaines analyses)',
        '(saved: the group will stay “to check” in later analyses)') .. '</small></label>'
    corps = '<p class="pourquoi">' .. T('Copie gardée : ', 'Kept copy: ') .. h(d.pourquoi or '') .. '.</p>'
      .. liste(lignesEffets(d.effets, m.collection))
  end
  local genre = d.memeImage and T('même image', 'same image') or T('copie réduite ou recompressée', 'downsized or recompressed copy')
  return string.format(
    '<article class="carte %s" id="g%d" data-g="%d" data-type="%s" data-ids="%s" data-q="%s"><h3>' .. T('Groupe', 'Group') .. ' %d <small>%s · %s · %s</small></h3>'
    .. '%s<div class="copies">%s</div>%s</article>',
    verifier and 'verifier' or 'fusion', numero, numero, d.memeImage and 'identique' or 'reduite', idsTexte(copies),
    h(texteRecherche(copies)),
    numero, h(nomFichier(d.garde.chemin)), h(dateTexte(d.garde.date)), h(genre), choix, table.concat(figures), corps)
end

local function triParDate(elements, date)
  local indices = {}
  for i = 1, #elements do indices[i] = i end
  table.sort(indices, function(a, b)
    local da, db = date(elements[a]) or math.huge, date(elements[b]) or math.huge
    if da ~= db then return da < db end
    return a < b
  end)
  return indices
end

local CSS = [==[
:root { --fond:#fafaf8; --texte:#222; --doux:#666; --garder:#2e8b57; --retirer:#c0392b; --apart:#2f6fd6; --verifier:#c27c0e; --carte:#fff; --bord:#ddd; }
@media (prefers-color-scheme: dark) { :root { --fond:#16181a; --texte:#e8e8e8; --doux:#9a9a9a; --carte:#202326; --bord:#363a3e; } }
* { box-sizing: border-box; }
body { font: 15px/1.45 system-ui, sans-serif; margin: 0; padding: 24px 16px 60px; background: var(--fond); color: var(--texte); }
main { max-width: 1280px; margin: 0 auto; }
h1 { margin: 0 0 4px; font-size: 1.5rem; } h2 { margin: 34px 0 6px; font-size: 1.2rem; } h2 small { color: var(--doux); font-weight: normal; }
h3 { margin: 0 0 8px; font-size: .98rem; } h3 small { color: var(--doux); font-weight: normal; }
.resume { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 10px; margin: 16px 0; }
.resume div { background: var(--carte); border: 1px solid var(--bord); border-radius: 8px; padding: 10px 12px; }
.resume b { display: block; font-size: 1.45rem; } .resume span { color: var(--doux); font-size: .85rem; }
.legende span { display: inline-block; margin-right: 14px; } .legende i { display: inline-block; width: 12px; height: 12px; border-radius: 3px; vertical-align: -1px; margin-right: 4px; }
.barre { position: sticky; top: 0; z-index: 5; background: var(--fond); padding: 10px 0; border-bottom: 1px solid var(--bord); display: flex; flex-wrap: wrap; gap: 14px; align-items: center; }
.barre input[type=search] { padding: 6px 10px; border: 1px solid var(--bord); border-radius: 6px; background: var(--carte); color: var(--texte); min-width: 240px; }
.carte { background: var(--carte); border: 1px solid var(--bord); border-left: 5px solid var(--bord); border-radius: 8px; padding: 12px 14px; margin: 12px 0; content-visibility: auto; contain-intrinsic-size: 360px; }
.carte.fusion { border-left-color: var(--garder); } .carte.verifier { border-left-color: var(--verifier); } .carte.apart { border-left-color: var(--apart); }
.copies { display: flex; flex-wrap: wrap; gap: 12px; }
figure { margin: 0; width: 220px; border: 3px solid var(--bord); border-radius: 6px; overflow: hidden; background: var(--carte); }
figure.garder { border-color: var(--garder); } figure.retirer { border-color: var(--retirer); } figure.verifier { border-color: var(--verifier); } figure.apart { border-color: var(--apart); }
figure.retirer img { opacity: .72; }
.img { position: relative; height: 165px; overflow: hidden; background: rgba(128,128,128,.12); display: grid; place-items: center; }
.img img { width: 100%; height: 165px; min-width: 0; object-fit: contain; display: block; }
.img em { position: absolute; top: 6px; left: 6px; font-style: normal; font-size: .72rem; font-weight: 600; color: #fff; padding: 2px 7px; border-radius: 10px; background: var(--garder); }
figure.retirer em { background: var(--retirer); } figure.verifier em { background: var(--verifier); } figure.apart em { background: var(--apart); }
.vide { color: var(--doux); font-size: .78rem; }
/* Vidéo : bandeau de plusieurs images (ApercuVideo.lua), une copie par ligne pour comparer image par image. */
figure.video { width: min(100%, 900px); flex-basis: 100%; }
figure.video .img, figure.video .img img { height: auto; min-height: 90px; }
figcaption { padding: 6px 8px 8px; font-size: .78rem; line-height: 1.3; }
figcaption b { display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
figcaption small { display: block; color: var(--doux); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.badges { margin-top: 4px; } .badge { display: inline-block; margin: 0 3px 3px 0; padding: 0 6px; border-radius: 9px; font-size: .68rem; border: 1px solid var(--bord); color: var(--doux); }
.badge.b-lr { border-color: var(--verifier); color: var(--verifier); } .badge.b-nom { border-color: var(--apart); color: var(--apart); }
.pourquoi { margin: 10px 0 4px; } .carte ul { margin: 4px 0 0; padding-left: 20px; color: var(--texte); } .carte li { margin: 1px 0; }
.notes { color: var(--doux); } code { background: rgba(128,128,128,.15); padding: 1px 5px; border-radius: 4px; }
.mes-choix { flex-basis: 100%; display: flex; flex-wrap: wrap; gap: 8px 12px; align-items: center; }
.mes-choix #code { flex: 1 1 260px; min-width: 0; padding: 6px 10px; border: 1px solid var(--bord); border-radius: 6px; background: var(--carte); color: var(--texte); font: .82rem ui-monospace, Consolas, monospace; }
button { padding: 6px 10px; border: 1px solid var(--bord); border-radius: 6px; background: var(--carte); color: var(--texte); font: inherit; font-size: .85rem; cursor: pointer; }
button:disabled { opacity: .5; cursor: default; } button.principal { border-color: var(--garder); color: var(--garder); font-weight: 600; }
.choix { display: inline-flex; gap: 6px; align-items: baseline; margin: 0 0 8px; font-size: .88rem; cursor: pointer; } .choix small { color: var(--doux); }
.carte.exclu { border-left-color: var(--bord); } .carte.exclu .copies, .carte.exclu ul { opacity: .45; }
.carte.forcee { border-left-color: var(--retirer); }
.carte.forcee figure { border-color: var(--retirer); } .carte.forcee figure em { background: var(--retirer); }
.carte.forcee figure.choisie { border-color: var(--garder); } .carte.forcee figure.choisie em { background: var(--garder); }
.garde { display: none; margin-top: 6px; font-weight: 600; cursor: pointer; } .carte.forcee .garde { display: block; }
@media (max-width: 700px) { .barre { position: static; } }
]==]

local SCRIPT = [==[
const ANALYSE = document.querySelector('main').dataset.analyse;
const CLE = 'deduplicate-choix-' + ANALYSE;
const recherche = document.getElementById('recherche');
const seulementReduites = document.getElementById('seulement-reduites');
const seulementChoix = document.getElementById('seulement-choix');
const seulementVideos = document.getElementById('seulement-videos');
const compte = document.getElementById('compte');
const champCode = document.getElementById('code');
const resumeChoix = document.getElementById('resume-choix');
const copier = document.getElementById('copier');
const cartes = Array.from(document.querySelectorAll('.carte'));
const choisies = (c) => c.classList.contains('exclu') || c.classList.contains('forcee');
function filtrer() {
  const t = recherche.value.trim().toLowerCase();
  let visibles = 0;
  cartes.forEach((c) => {
    const ok = (!t || c.dataset.q.includes(t)) && (!seulementReduites.checked || c.dataset.type === 'reduite')
      && (!seulementVideos.checked || !!c.querySelector('figure.video'))
      && (!seulementChoix.checked || choisies(c));
    c.hidden = !ok;
    if (ok) visibles++;
  });
  compte.textContent = visibles + (visibles > 1 ? TXT.groupesAffiches : TXT.groupeAffiche);
}
// Aspect d'un groupe selon ses cases : exclu, ou forcé avec la copie choisie en vert et les autres en rouge.
function majCarte(c) {
  const non = c.querySelector('input.non'), force = c.querySelector('input.force');
  c.classList.toggle('exclu', !!(non && non.checked));
  if (!force) return;
  c.classList.toggle('forcee', force.checked);
  const k = c.querySelector('.garde input:checked').value;
  c.querySelectorAll('figure').forEach((f) => {
    const choisie = force.checked && f.querySelector('.garde input').value === k;
    f.classList.toggle('choisie', choisie);
    const em = f.querySelector('em');
    em.textContent = force.checked ? (choisie ? TXT.gardeeForce : TXT.retiree) : em.dataset.libelle;
  });
}
function majCode() {
  const non = [], force = {};
  cartes.forEach((c) => {
    if (c.classList.contains('exclu')) non.push(Number(c.dataset.g));
    if (c.classList.contains('forcee')) force[c.dataset.g] = Number(c.querySelector('.garde input:checked').value);
  });
  non.sort((a, b) => a - b);
  const forces = Object.keys(force).map(Number).sort((a, b) => a - b);
  const textesForces = forces.map((g) => (force[g] === 1 ? String(g) : g + ':' + force[g]));
  champCode.value = non.length || forces.length ? 'DEDUP ' + ANALYSE + (non.length ? ' · non ' + non.join(' ') : '')
    + (forces.length ? ' · force ' + textesForces.join(' ') : '') : '';
  copier.disabled = !champCode.value;
  const pluriel = (n, mot) => n + ' ' + mot + (n > 1 ? 's' : '');
  resumeChoix.textContent = champCode.value
    ? pluriel(non.length, TXT.groupe) + TXT.aNePasFusionner + pluriel(forces.length, TXT.groupe) + TXT.aFusionnerDeForce
      + TXT.copiezLeCode
    : TXT.aucunChoix;
  try { localStorage.setItem(CLE, JSON.stringify({ non, force })); } catch (e) { /* choix gardés pour cette page seulement */ }
}
document.addEventListener('change', (e) => {
  const c = e.target.closest('.carte');
  if (!c || !e.target.matches('input.non, input.force, .garde input')) return;
  majCarte(c);
  majCode();
  if (seulementChoix.checked) filtrer();
});
function pourAffichees(action) {
  cartes.filter((c) => !c.hidden).forEach((c) => { action(c); majCarte(c); });
  majCode();
  filtrer();
}
document.getElementById('exclure-affiches').addEventListener('click', () => {
  const n = cartes.filter((c) => !c.hidden && c.querySelector('input.non')).length;
  if (n && confirm(TXT.confirmerExclure.replace('%n', n))) {
    pourAffichees((c) => { const non = c.querySelector('input.non'); if (non) non.checked = true; });
  }
});
// Fusionne tout ce qui est affiché : les groupes proposés perdent leur exclusion, les autres sont fusionnés de
// force avec la copie déjà choisie (la copie proposée par défaut). Choix.lua refuse deux groupes forcés qui
// partagent une photo, ou un groupe forcé qui ne contient qu'une partie d'un groupe proposé : un groupe qui serait
// dans ce cas n'est pas forcé (le plus petit numéro l'emporte), et la liste de ces groupes est annoncée.
const idsCarte = (c) => (c.dataset.ids || '').split(' ').filter(Boolean);
// Groupe déjà fusionné avec lequel c partage des photos (sa carte et le nombre de photos communes), ou null.
function chevauchement(c) {
  const ids = new Set(idsCarte(c));
  for (const autre of cartes) {
    if (autre === c) continue;
    const force = autre.querySelector('input.force'), non = autre.querySelector('input.non');
    if (force ? !force.checked : (non && non.checked)) continue;
    const siens = idsCarte(autre), communes = siens.filter((id) => ids.has(id)).length;
    if (communes > 0 && (!!force || communes < siens.length)) return { carte: autre, communes };
  }
  return null;
}
document.getElementById('fusionner-affiches').addEventListener('click', () => {
  const affichees = cartes.filter((c) => !c.hidden);
  const n = affichees.length;
  const forcees = affichees.filter((c) => c.querySelector('input.force')).length;
  if (n && confirm(TXT.confirmerFusion.replace('%n', n)
    + (forcees ? '\n' + TXT.confirmerForcees.replace('%n', forcees) : ''))) {
    affichees.forEach((c) => { const non = c.querySelector('input.non'); if (non) non.checked = false; });
    const ecartes = [];
    affichees.filter((c) => c.querySelector('input.force'))
      .sort((a, b) => Number(a.dataset.g) - Number(b.dataset.g))
      .forEach((c) => {
        const force = c.querySelector('input.force');
        if (force.checked) return;
        const conflit = chevauchement(c);
        if (!conflit) { force.checked = true; return; }
        ecartes.push(TXT.conflit.replace('%g', c.dataset.g)
          .replace('%p', conflit.communes > 1 ? TXT.photos.replace('%n', conflit.communes) : TXT.unePhoto)
          .replace('%a', conflit.carte.dataset.g));
      });
    pourAffichees(() => {});
    if (ecartes.length) {
      alert((ecartes.length > 1 ? TXT.nonForces : TXT.nonForce)
        + '\n• ' + ecartes.join('\n• ') + '\n\n' + TXT.pourForcer);
    }
  }
});
document.getElementById('retablir-affiches').addEventListener('click', () => {
  pourAffichees((c) => c.querySelectorAll('input.non, input.force').forEach((i) => { i.checked = false; }));
});
copier.addEventListener('click', async () => {
  let ok = false;
  try { await navigator.clipboard.writeText(champCode.value); ok = true; } catch (e) { /* page locale : copie classique */ }
  if (!ok) { champCode.select(); try { ok = document.execCommand('copy'); } catch (e) { ok = false; } }
  copier.textContent = ok ? TXT.codeCopie : TXT.codeSelectionne;
  setTimeout(() => { copier.textContent = TXT.copierLeCode; }, 2500);
});
recherche.addEventListener('input', filtrer);
seulementReduites.addEventListener('change', filtrer);
seulementChoix.addEventListener('change', filtrer);
seulementVideos.addEventListener('change', filtrer);
try {
  const enregistres = JSON.parse(localStorage.getItem(CLE) || 'null');
  if (enregistres) {
    cartes.forEach((c) => {
      const non = c.querySelector('input.non'), force = c.querySelector('input.force');
      if (non) non.checked = enregistres.non.includes(Number(c.dataset.g));
      const k = enregistres.force[c.dataset.g];
      if (force && k) {
        force.checked = true;
        const radio = c.querySelector('.garde input[value="' + k + '"]');
        if (radio) radio.checked = true;
      }
      majCarte(c);
    });
  }
} catch (e) { /* aucun choix enregistré lisible : on repart de zéro */ }
majCode();
filtrer();
]==]

-- Construit la page HTML (texte) du rapport.
-- Textes du script de la page, dans la langue choisie, en littéral JavaScript.
local function textesScript()
  local textes = {
    groupe = T('groupe', 'group'), groupeAffiche = T(' groupe affiché', ' group shown'), groupesAffiches = T(' groupes affichés', ' groups shown'),
    gardeeForce = T('Gardée (forcé)', 'Kept (forced)'), retiree = T('Retirée', 'Removed'),
    aNePasFusionner = T(' à ne pas fusionner, ', ' not to merge, '), aFusionnerDeForce = T(' à fusionner de force. ', ' to force-merge. '),
    copiezLeCode = T('Copiez le code et collez-le dans Lightroom avant de cliquer sur « Fusionner ».',
      'Copy the code and paste it into Lightroom before clicking “Merge”.'),
    aucunChoix = T('Aucun choix : les groupes « à fusionner » le seront tous, les groupes « à vérifier » resteront tels quels.',
      'No choice: all groups “to merge” will be merged, groups “to check” will stay as they are.'),
    confirmerExclure = T('Ne pas fusionner les %n groupes « à fusionner » affichés ?', 'Do not merge the %n groups “to merge” shown?'),
    confirmerFusion = T('Fusionner les %n groupes affichés ?', 'Merge the %n groups shown?'),
    confirmerForcees = T('%n groupes « à vérifier » ou de versions conservées à part seront fusionnés de force, avec la copie '
      .. 'proposée sauf choix contraire. Leurs retouches Lightroom ne sont pas transférées.', '%n groups “to check” or of '
      .. 'versions kept apart will be force-merged, with the proposed copy unless you chose otherwise. Their Lightroom edits '
      .. 'are not transferred.'),
    conflit = T('groupe %g : partage %p avec le groupe %a', 'group %g: shares %p with group %a'),
    photos = T('%n photos', '%n photos'), unePhoto = T('une photo', 'one photo'),
    nonForces = T('Ces groupes n’ont pas été forcés :', 'These groups were not forced:'),
    nonForce = T('Ce groupe n’a pas été forcé :', 'This group was not forced:'),
    pourForcer = T('Pour en forcer un, sortez d’abord l’autre groupe de la fusion : décochez son « Fusionner de force », ou '
      .. 'cochez son « Ne pas fusionner ».', 'To force one, first take the other group out of the merge: untick its “Force '
      .. 'merge”, or tick its “Do not merge”.'),
    codeCopie = T('Code copié ✓', 'Code copied ✓'), codeSelectionne = T('Code sélectionné : Ctrl+C', 'Code selected: Ctrl+C'),
    copierLeCode = T('Copier le code', 'Copy the code'),
  }
  local cles = {}
  for cle in pairs(textes) do cles[#cles + 1] = cle end
  table.sort(cles)
  local morceaux = {}
  for _, cle in ipairs(cles) do
    local valeur = textes[cle]:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('</', '<\\/')
    morceaux[#morceaux + 1] = cle .. ': "' .. valeur .. '"'
  end
  return '{ ' .. table.concat(morceaux, ', ') .. ' }'
end

function M.page(m)
  local fusions, verifier, versions = {}, {}, {}
  for i, d in ipairs(m.decisions) do
    local entree = { numero = i, decision = d }
    if d.versions then versions[#versions + 1] = entree
    elseif d.aVerifier then verifier[#verifier + 1] = entree
    else fusions[#fusions + 1] = entree end
  end

  -- Chiffres du résumé.
  local retirees, reduites, octets, collections = 0, 0, 0, {}
  for _, f in ipairs(fusions) do
    local d = f.decision
    retirees = retirees + #d.retirees
    for _, c in ipairs(d.retirees) do
      octets = octets + (c.octets or c.taille or 0)
      if c.empreinte ~= d.garde.empreinte then reduites = reduites + 1 end
    end
    for _, col in ipairs(d.effets.collections) do collections[col.id] = true end
    for _, q in ipairs(d.effets.quittees) do collections[q.collection.id] = true end
  end
  local nbCollections = 0
  for _ in pairs(collections) do nbCollections = nbCollections + 1 end

  local p = {}
  local function ajouter(texte) p[#p + 1] = texte end
  ajouter('<!doctype html>\n<html lang="' .. Langue.code() .. '"><head><meta charset="utf-8">'
    .. '<meta name="viewport" content="width=device-width, initial-scale=1"><title>' .. T('Doublons — rapport avant fusion', 'Duplicates — report before merging') .. '</title>'
    .. '<style>' .. CSS .. '</style></head><body><main data-analyse="' .. h(m.identifiant) .. '">')
  ajouter('<h1>' .. T('Doublons — rapport avant fusion', 'Duplicates — report before merging') .. '</h1>')
  ajouter('<p>' .. T('<b>Rien n’a été modifié dans Lightroom.</b> Recherche faite sur ', '<b>Nothing has been changed in Lightroom.</b> Search run on ')
    .. h(m.portee) .. ' · ' .. h(m.date) .. T(' · analyse ', ' · analysis ') .. h(m.identifiant)
    .. T('. Pour appliquer ce qui est décrit ici, revenez dans Lightroom et cliquez sur '
    .. '« Fusionner ». Pour écarter un groupe ou forcer un groupe « à vérifier », cochez sa case, copiez le code de '
    .. 'vos choix (barre ci-dessous) et collez-le dans Lightroom avant de cliquer sur « Fusionner ».', '. To apply what is '
    .. 'described here, go back to Lightroom and click “Merge”. To leave a group out or force a group “to check”, tick its '
    .. 'box, copy the code of your choices (bar below) and paste it into Lightroom before clicking “Merge”.') .. '</p>')

  ajouter('<div class="resume">')
  -- texte : « singulier|pluriel » (le nombre s'accorde ; une valeur déjà formatée, comme une taille, prend le pluriel).
  local function carteChiffre(valeur, texte, couleur)
    local singulier, plur = texte:match('^(.-)|(.*)$')
    local accorde = (type(valeur) == 'number' and valeur == 1) and singulier or plur
    ajouter(string.format('<div><b%s>%s</b><span>%s</span></div>', couleur and (' style="color:var(--' .. couleur .. ')"') or '',
      h(valeur), h(accorde or texte)))
  end
  carteChiffre(#fusions, T('groupe à fusionner|groupes à fusionner', 'group to merge|groups to merge'), 'garder')
  carteChiffre(retirees, T('copie retirée (mise de côté)|copies retirées (mises de côté)', 'copy removed (set aside)|copies removed (set aside)'), 'retirer')
  carteChiffre(reduites, T('dont copie réduite ou recompressée|dont copies réduites ou recompressées', 'of which downsized or recompressed copy|of which downsized or recompressed copies'))
  carteChiffre(taille(octets), T('libérés si vous les supprimez du disque|libérés si vous les supprimez du disque', 'freed if you delete them from disk|freed if you delete them from disk'))
  carteChiffre(nbCollections, T('collection modifiée|collections modifiées', 'collection changed|collections changed'))
  carteChiffre(#verifier, T('groupe à vérifier (rien de fait)|groupes à vérifier (rien de fait)', 'group to check (nothing done)|groups to check (nothing done)'), 'verifier')
  carteChiffre(#versions, T('groupe de versions conservées|groupes de versions conservées', 'group of versions kept|groups of versions kept'), 'apart')
  ajouter('</div>')

  ajouter('<p class="legende"><span><i style="background:var(--garder)"></i>' .. T('copie gardée', 'kept copy') .. '</span>'
    .. '<span><i style="background:var(--retirer)"></i>' .. T('copie retirée', 'removed copy') .. '</span>'
    .. '<span><i style="background:var(--verifier)"></i>' .. T('à vérifier : rien n’est fait', 'to check: nothing is done') .. '</span>'
    .. '<span><i style="background:var(--apart)"></i>' .. T('version conservée à part', 'version kept apart') .. '</span></p>')
  ajouter('<p>' .. T('Dans chaque groupe fusionné : la copie gardée est la plus grande image (puis, à image identique, la copie '
    .. 'retouchée dans Lightroom, la mieux rangée…). Elle prend la place des copies retirées dans leurs collections '
    .. '(albums Google Photos compris) et récupère leurs mots-clés, leur note, leur drapeau, leur position GPS et leurs '
    .. 'textes quand elle n’en a pas. Les copies retirées sont mises dans la collection « ' .. h(m.collection)
    .. ' » ; vous les retirez ensuite vous-même du catalogue. Si une copie à retirer est retouchée ou a des copies '
    .. 'virtuelles, le groupe reste « à vérifier ». Fusionné de force, ses retouches ne sont pas recopiées, mais ses copies '
    .. 'virtuelles sont recréées sur la copie gardée (nom, réglages, métadonnées et collections).',
    'In each merged group, the kept copy is the largest image (then, for identical images, the copy edited in Lightroom, '
    .. 'the best filed…). It takes the place of the removed copies in their collections (Google Photos albums included) '
    .. 'and receives their keywords, rating, flag, GPS position and texts when it has none. The removed copies are put in '
    .. 'the “' .. h(m.collection) .. '” collection; you then remove them from the catalog yourself. If a copy to remove is '
    .. 'edited or has virtual copies, the group stays “to check”. When force-merged, its edits are not copied, but its '
    .. 'virtual copies are recreated on the kept copy (name, settings, metadata and collections).') .. '</p>')

  ajouter('<div class="barre"><input type="search" id="recherche" placeholder="' .. T('Filtrer par nom ou dossier…', 'Filter by name or folder…') .. '">'
    .. '<label><input type="checkbox" id="seulement-reduites"> ' .. T('copies réduites seulement', 'downsized copies only') .. '</label>'
    .. '<label><input type="checkbox" id="seulement-videos"> ' .. T('vidéos seulement', 'videos only') .. '</label>'
    .. '<label><input type="checkbox" id="seulement-choix"> ' .. T('mes choix seulement', 'my choices only') .. '</label>'
    .. '<span id="compte" class="notes"></span>'
    .. '<span class="notes">' .. T('Aller à : <a href="#fusions">à fusionner</a> · <a href="#verifier">à vérifier</a> · '
    .. '<a href="#apart">conservées à part</a>', 'Go to: <a href="#fusions">to merge</a> · <a href="#verifier">to check</a> · '
    .. '<a href="#apart">kept apart</a>') .. '</span>'
    .. '<div class="mes-choix"><button type="button" id="fusionner-affiches">' .. T('Fusionner tous les groupes affichés', 'Merge all groups shown') .. '</button>'
    .. '<button type="button" id="exclure-affiches">' .. T('Ne pas fusionner les groupes affichés', 'Do not merge the groups shown') .. '</button>'
    .. '<button type="button" id="retablir-affiches">' .. T('Annuler mes choix sur les groupes affichés', 'Clear my choices on the groups shown') .. '</button>'
    .. '<input id="code" readonly placeholder="' .. T('Code de vos choix', 'Code of your choices') .. '" aria-label="' .. T('Code de vos choix', 'Code of your choices') .. '">'
    .. '<button type="button" id="copier" class="principal" disabled>' .. T('Copier le code', 'Copy the code') .. '</button>'
    .. '<span id="resume-choix" class="notes"></span></div></div>')

  -- Groupes à fusionner, du plus ancien au plus récent.
  ajouter('<h2 id="fusions">' .. T('À fusionner', 'To merge') .. ' <small>' .. pluriel(#fusions, T('groupe', 'group')) .. '</small></h2>')
  for _, i in ipairs(triParDate(fusions, function(f) return f.decision.garde.date end)) do
    ajouter(carteDecision(fusions[i].numero, fusions[i].decision, m))
  end
  if #fusions == 0 then ajouter('<p class="notes">' .. T('Aucun groupe à fusionner.', 'No group to merge.') .. '</p>') end

  if #verifier > 0 then
    ajouter('<h2 id="verifier">' .. T('À vérifier', 'To check') .. ' <small>' .. pluriel(#verifier, T('groupe', 'group')) .. T(' · rien n’est fait', ' · nothing is done') .. '</small></h2>')
    for _, i in ipairs(triParDate(verifier, function(f) return f.decision.garde.date end)) do
      ajouter(carteDecision(verifier[i].numero, verifier[i].decision, m))
    end
  end

  if #versions > 0 then
    ajouter('<h2 id="apart">' .. T('Versions conservées à part', 'Versions kept apart') .. ' <small>' .. pluriel(#versions, T('groupe', 'group'))
      .. T(' · tout est conservé, sauf fusion forcée', ' · everything is kept, unless force-merged') .. '</small></h2>')
    for _, i in ipairs(triParDate(versions, function(f) return f.decision.garde.date end)) do
      ajouter(carteDecision(versions[i].numero, versions[i].decision, m))
    end
  end

  if m.notes and #m.notes > 0 then
    local notes = {}
    for i, n in ipairs(m.notes) do notes[i] = h(n) end
    ajouter('<h2>' .. T('À savoir', 'Good to know') .. '</h2><div class="notes">' .. liste(notes) .. '</div>')
  end
  ajouter('</main><script>const TXT = ' .. textesScript() .. ';\n' .. SCRIPT .. '</script></body></html>')
  return table.concat(p, '\n')
end

return M
