package.path = 'lightroom-deduplicate.lrplugin/?.lua;' .. package.path
-- Comparer les octets remis au digesteur évite de tester une collision de hash.
function import(nom)
  if nom == 'LrMD5' then return { digest = function(s) return s end } end
  return {}
end
local E = require 'Empreintes'
local function dehex(s) return (s:gsub('..', function(x) return string.char(tonumber(x, 16)) end)) end
-- JPEG valide de 8x8, produit une fois par ImageMagick (aucune dépendance au décodeur pour les tests).
local jpeg = dehex('ffd8ffe000104a46494600010100000100010000ffdb0043000503040404030504040405050506070c08070707070f0b0b090c110f1212110f111113161c1713141a1511111821181a1d1d1f1f1f13172224221e241c1e1f1effc0000b080008000801011100ffc40014000100000000000000000000000000000001ffc400171000030100000000000000000000000000001865a2ffda0008010100003f001a7a3b3fffd9')
local function octet(s, i, valeur) return s:sub(1, i - 1) .. string.char(valeur) .. s:sub(i + 1) end
local function segment(marqueur, contenu)
  local taille = #contenu + 2
  return string.char(255, marqueur, math.floor(taille / 256), taille % 256) .. contenu
end
local function inserer(s, contenu) return s:sub(1, 2) .. contenu .. s:sub(3) end
local empreinte = E.empreinteContenu(jpeg)
assert(empreinte:sub(1, 5) == 'jpeg:')
-- Régression : même SOS et même scan, mais pixels décodés différents avec une autre DQT.
local dqt = assert(jpeg:find(string.char(255, 219), 1, true))
local autre = octet(jpeg, dqt + 5, jpeg:byte(dqt + 5) * 2)
local sos = assert(jpeg:find(string.char(255, 218), 1, true))
assert(jpeg:sub(sos) == autre:sub(sos) and E.empreinteContenu(autre) ~= empreinte)
for _, marqueur in ipairs({ 192, 196 }) do -- SOF (dimensions) et DHT (décodage).
  local i = assert(jpeg:find(string.char(255, marqueur), 1, true)) + 6
  assert(E.empreinteContenu(octet(jpeg, i, (jpeg:byte(i) + 1) % 256)) ~= empreinte)
end
-- ICC et Adobe changent les couleurs : les conserver.
for _, app in ipairs({ {226, 'ICC_PROFILE\0couleur'}, {238, 'Adobe\0couleur'} }) do
  assert(E.empreinteContenu(inserer(jpeg, segment(app[1], app[2]))) ~= empreinte)
end
-- EXIF minimal (IFD0 d'une entrée) : orientation en SHORT, petit ou grand boutiste.
local function exif(orientation, autre, grand)
  local function u16(v) return grand and string.char(math.floor(v / 256), v % 256) or string.char(v % 256, math.floor(v / 256)) end
  local function u32(v) return grand and ('\0\0' .. u16(v)) or (u16(v) .. '\0\0') end
  local tag = orientation and 0x0112 or 0x0131
  local valeur = orientation and (u16(orientation) .. '\0\0') or u32(0)
  return segment(225, 'Exif\0\0' .. (grand and 'MM' or 'II') .. u16(42) .. u32(8) .. u16(1)
    .. u16(tag) .. u16(3) .. u32(1) .. valeur .. u32(0) .. (autre or ''))
end
local function xmp(orientation, autre)
  return segment(225, 'http://ns.adobe.com/xap/1.0/\0<x:xmpmeta>' .. (autre or '')
    .. (orientation and ('<rdf:Description tiff:Orientation="' .. orientation .. '"/>') or '') .. '</x:xmpmeta>')
end
-- Les métadonnées sans effet sur l'image (dates, logiciel, IPTC, JFIF) sont ignorées.
assert(E.empreinteContenu(inserer(jpeg, exif(nil, 'date 2004'))) == empreinte, 'EXIF sans orientation : ignoré')
assert(E.empreinteContenu(inserer(jpeg, exif(1, 'date 2005'))) == empreinte, 'orientation 1 = sans orientation')
assert(E.empreinteContenu(inserer(jpeg, exif(0))) == empreinte, 'orientation 0 (inconnue) = 1')
assert(E.empreinteContenu(inserer(jpeg, exif(1, nil, true) .. xmp(1, 'motcle'))) == empreinte, 'XMP réécrit : ignoré')
assert(E.empreinteContenu(inserer(jpeg, segment(237, 'Photoshop 3.0\0iptc'))) == empreinte, 'IPTC ignoré')
-- Une orientation différente change l'image affichée, qu'elle vienne de l'EXIF ou du XMP.
local tourne = E.empreinteContenu(inserer(jpeg, exif(6)))
assert(tourne ~= empreinte and E.empreinteContenu(inserer(jpeg, exif(6, 'autre', true))) == tourne)
assert(E.empreinteContenu(inserer(jpeg, xmp(6))) ~= empreinte, 'orientation XMP')
assert(E.empreinteContenu(inserer(jpeg, exif(1) .. xmp(6))) ~= E.empreinteContenu(inserer(jpeg, exif(6) .. xmp(1))),
  'désaccord EXIF/XMP : chaque lecture compte')
-- Orientation illisible : le segment entier reste dans l'empreinte.
assert(E.empreinteContenu(inserer(jpeg, exif(9))) ~= empreinte, 'valeur hors bornes')
assert(E.empreinteContenu(inserer(jpeg, segment(225, 'Exif\0\0XX'))) ~= empreinte, 'TIFF illisible')
assert(E.empreinteContenu(inserer(jpeg, xmp(nil, '<tiff:Orientation rdf:resource="6"/>'))) ~= empreinte, 'XMP inconnu')
-- Les commentaires sans effet sur le rendu restent ignorés.
assert(E.empreinteContenu(inserer(jpeg, segment(254, 'commentaire A'))) == empreinte)
assert(E.empreinteContenu(inserer(jpeg, segment(254, 'commentaire B plus long'))) == empreinte)
-- Un en-tête tronqué/invalide utilise tous les octets, jamais un scan isolé.
for _, invalide in ipairs({ jpeg:sub(1, dqt + 3), inserer(jpeg, '\255\225\0\1'), 'pas un jpeg' }) do
  assert(E.empreinteContenu(invalide) == 'brut:' .. invalide)
end
print('OK : DQT/DHT/SOF, ICC/Adobe et orientation conservés, autres métadonnées et commentaires ignorés et fichiers invalides traités intégralement.')
