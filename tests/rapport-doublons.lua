package.path = 'lightroom-deduplicate.lrplugin/?.lua;' .. package.path
local Choix = require 'Choix'
local Doublons = require 'Doublons'
local R = require 'RapportHtml'

local function copie(id, chemin, extra)
  local c = { id = id, chemin = chemin, empreinte = 'jpeg:x', pixels = 100, octets = 2048, date = 600000000 }
  for k, v in pairs(extra or {}) do c[k] = v end
  return c
end
local fusion = Doublons.decider({ copie(1, 'D:\\A\\<a>.jpg'), copie(2, 'D:\\B\\a-2.jpg') })
fusion.effets = Doublons.effets(fusion)
local verifier = Doublons.decider({ copie(3, 'D:\\A\\b.jpg', { retouchee = true }), copie(4, 'D:\\B\\b-2.jpg', { retouchee = true }),
  copie(5, 'D:\\C\\b.jpg') })
local versions = Doublons.deciderVersions({ copie(6, 'D:\\A\\c.jpg', { empreinte = 'jpeg:c', pixels = 400 }),
  copie(7, 'D:\\A\\c-Modifier.jpg', { empreinte = 'jpeg:m' }) })
local decisions = { fusion, verifier, versions }
local identifiant = Choix.identifiant(decisions)
local page = R.page({ portee = 'les 7 photos', date = '2026-11-01 10:00', collection = 'Doublons à retirer', identifiant = identifiant,
  decisions = decisions,
  vignette = function(c) return 'vignettes/' .. c.id .. '.jpg' end })

assert(page:find('data-analyse="' .. identifiant .. '"', 1, true))
assert(page:find('&lt;a&gt;.jpg', 1, true))
-- Un groupe proposé porte « Ne pas fusionner » ; un groupe « à vérifier », « Fusionner de force » et un bouton
-- par copie, la copie qui serait gardée étant cochée.
local carte1 = page:match('<article class="carte fusion" id="g1" data%-g="1".-</article>')
assert(carte1 and carte1:find('class="non"', 1, true) and not carte1:find('class="force"', 1, true))
assert(not carte1:find('type="radio"', 1, true))
local carte2 = page:match('<article class="carte verifier" id="g2" data%-g="2".-</article>')
assert(carte2 and carte2:find('class="force"', 1, true) and not carte2:find('class="non"', 1, true))
assert(carte2:find('name="garde2" value="1" checked', 1, true))
assert(carte2:find('name="garde2" value="2">', 1, true) and carte2:find('name="garde2" value="3">', 1, true))
-- L'ordre des boutons suit celui de Choix.appliquer : la copie qui serait gardée, puis les autres.
local premier = carte2:match('<b title="([^"]+)"')
assert(premier == verifier.garde.chemin:gsub('&', '&amp;'))
-- Les versions conservées à part : tout est conservé, mais « Fusionner de force » est proposé, avec le choix
-- de la copie à garder.
assert(versions.aVerifier == Doublons.RAISON_VERSIONS and versions.garde.id == 6)
local apart = page:match('<article class="carte apart" id="g3" data%-g="3".-</article>')
assert(apart and apart:find('class="force"', 1, true) and not apart:find('class="non"', 1, true))
assert(apart:find('name="garde3" value="1" checked', 1, true) and apart:find('name="garde3" value="2">', 1, true))
assert(apart:find('Tout est conservé', 1, true) and apart:find('ne montre pas la même vue', 1, true))
local lus = assert(Choix.lireCode('DEDUP ' .. identifiant .. ' force 3:2', decisions, identifiant))
local plan = Choix.appliquer(decisions, lus)
assert(#plan.forcees == 1 and plan.forcees[1].garde.id == 7 and plan.forcees[1].retirees[1].id == 6)
assert(#plan.aFusionner == 2, 'le groupe proposé reste fusionné')
for _, id in ipairs({ 'id="code"', 'id="copier"', 'id="fusionner-affiches"', 'id="exclure-affiches"','id="retablir-affiches"', 'id="seulement-choix"', 'id="resume-choix"' }) do
  assert(page:find(id, 1, true), id)
end
-- Chaque copie porte son aperçu dans la zone image ; une vidéo a en plus la classe « video » (bandeau large).
assert(page:find('<figure class="garder"><div class="img"><img src="vignettes/1.jpg"', 1, true), 'aperçu à sa place')
assert(not page:find('class="[^"]*<', 1), 'balise dans un attribut class')
assert(carte1:find('data-ids="1 2"', 1, true), 'photos du groupe pour repérer les chevauchements')
local video = Doublons.decider({ copie(8, 'D:\\A\\v.mts', { video = true, empreinte = 'complet:v' }),
  copie(9, 'D:\\B\\v.mts', { video = true, empreinte = 'complet:v' }) })
video.effets = Doublons.effets(video)
local pageVideo = R.page({ portee = 'les 2 photos', date = '', collection = 'Doublons à retirer',
  identifiant = Choix.identifiant({ video }), decisions = { video },
  vignette = function(c) return 'vignettes/' .. c.id .. '-video5.jpg' end })
assert(pageVideo:find('<figure class="garder video"><div class="img"><img src="vignettes/8-video5.jpg"', 1, true),
  'bandeau de la vidéo gardée')
print('Rapport des doublons : OK')
