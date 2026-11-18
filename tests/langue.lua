-- Interface en anglais : décisions, rapport des doublons (page et textes du script), rapport des rafales et
-- réglages ; les données (collections, code des choix) ne changent pas, et le français revient ensuite.
package.path = 'lightroom-deduplicate.lrplugin/?.lua;' .. package.path
local Langue = require 'Langue'
local Choix = require 'Choix'
local Doublons = require 'Doublons'
local RapportHtml = require 'RapportHtml'
local RapportRafales = require 'RapportRafales'

-- Sans réglage ni Lightroom : le français.
assert(Langue.code() == 'fr' and Langue.t('oui', 'yes') == 'oui')
assert(Langue.t('seul') == 'seul', 'sans traduction, le français sert')

local function copie(id, chemin, extra)
  local c = { id = id, chemin = chemin, empreinte = 'jpeg:x', pixels = 100, octets = 2048, date = 600000000 }
  for k, v in pairs(extra or {}) do c[k] = v end
  return c
end
local function analyse()
  local fusion = Doublons.decider({ copie(1, 'D:\\A\\a.jpg'), copie(2, 'D:\\B\\a-2.jpg') })
  fusion.effets = Doublons.effets(fusion)
  local verifier = Doublons.decider({ copie(3, 'D:\\A\\b.jpg', { retouchee = true }), copie(4, 'D:\\B\\b-2.jpg', { retouchee = true }) })
  local versions = Doublons.deciderVersions({ copie(6, 'D:\\A\\c.jpg', { empreinte = 'jpeg:c', pixels = 400 }),
    copie(7, 'D:\\A\\c-Modifier.jpg', { empreinte = 'jpeg:m' }) })
  local decisions = { fusion, verifier, versions }
  local identifiant = Choix.identifiant(decisions)
  local page = RapportHtml.page({ portee = 'x', date = '2026-11-01 10:00', collection = Doublons.COLLECTION,
    identifiant = identifiant, decisions = decisions, notes = { 'note' },
    vignette = function(c) return 'vignettes/' .. c.id .. '.jpg' end })
  return { fusion = fusion, verifier = verifier, versions = versions, decisions = decisions, identifiant = identifiant, page = page }
end

Langue.forcer('en')
assert(Langue.anglais() and Langue.t('oui', 'yes') == 'yes')
local en = analyse()
assert(en.verifier.aVerifier == 'several edited copies', en.verifier.aVerifier)
assert(en.fusion.pourquoi and not en.fusion.pourquoi:find('[éèà]'), en.fusion.pourquoi)
assert(en.versions.aVerifier == Doublons.raisonVersions() and en.versions.aVerifier:find('different images', 1, true))
local p = en.page
for _, texte in ipairs({ '<html lang="en">', 'Duplicates — report before merging', 'Nothing has been changed in Lightroom',
  'Force merge', 'Do not merge', 'keep this one', 'Copy the code', 'Good to know', 'videos only', 'To check' }) do
  assert(p:find(texte, 1, true), texte)
end
for _, texte in ipairs({ 'Rien n’a été modifié', 'Fusionner de force', 'garder celle-ci', '« ' }) do
  assert(not p:find(texte, 1, true), 'reste du français : ' .. texte)
end
-- Le nom de la collection et le code des choix ne dépendent pas de la langue.
assert(p:find('“Doublons à retirer”', 1, true))
assert(Choix.lireCode('DEDUP ' .. en.identifiant .. ' · non 1', en.decisions, en.identifiant))
-- Les textes du script sont un littéral JavaScript bien formé, en anglais.
local txt = assert(p:match('<script>const TXT = (%b{});'), 'textes du script')
assert(txt:find('copierLeCode: "Copy the code"', 1, true) and txt:find('confirmerFusion: "Merge the %n groups shown?"', 1, true))
local _, cles = txt:gsub('%w+: "', '')
local _, guillemets = txt:gsub('\\"', ''):gsub('"', '')
assert(not txt:find('\n', 1, true) and guillemets == 2 * cles, 'chaque valeur est une chaîne fermée, guillemets internes échappés')
local refus = select(2, Choix.lireCode('DEDUP autre', en.decisions, en.identifiant))
assert(refus and refus:find('This code comes from another report', 1, true), refus)

local rafales = RapportRafales.page('Folder', { { blocs = { {
  { nom = 'a', decision = 'garder', fichiers = { { chemin = 'a.jpg' } } },
  { nom = 'b', decision = 'retirer', pourquoi = 'x', fichiers = { { chemin = 'b.jpg' } } } } } } },
  { rafales = 1, cadres = 2, retires = 1, proteges = 0 })
for _, texte in ipairs({ 'Burst report', 'Burst 1', 'Block 1', 'to remove', 'kept', 'No preview' }) do
  assert(rafales:find(texte, 1, true), texte)
end

-- Réglages : sections et choix de la langue.
local prefs = { langue = 'en' }
function import(nom)
  if nom == 'LrPrefs' then return { prefsForPlugin = function() return prefs end } end
  if nom == 'LrView' then return { bind = function(cle) return cle end } end
  error(nom)
end
local reglages = dofile('lightroom-deduplicate.lrplugin/Reglages.lua')
local props = { addObserver = function() end }
local vue = setmetatable({}, { __index = function() return function(_, v) return v end end })
local sections = reglages.sectionsForTopOfDialog(vue, props)
assert(sections[1].title == 'Language' and sections[2].title == 'Merging duplicates' and props.langue == 'en')
local menu = sections[1][1][2]
assert(menu.items[1].value == 'fr' and menu.items[2].value == 'en', 'choix Français / English')

-- Le réglage lu dans Lightroom décide, et le français revient sans lui.
Langue.forcer(nil)
assert(Langue.code() == 'en', 'réglage langue = en')
prefs.langue = nil
assert(Langue.code() == 'fr')
local fr = analyse()
assert(fr.page:find('<html lang="fr">', 1, true) and fr.page:find('Doublons — rapport avant fusion', 1, true))
assert(fr.verifier.aVerifier == 'plusieurs copies retouchées')
print('OK : interface en anglais (décisions, rapports, script, réglages), données inchangées, retour au français.')
