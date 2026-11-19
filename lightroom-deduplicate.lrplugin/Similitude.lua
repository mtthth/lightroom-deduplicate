-- Reconnaît deux versions d'une même prise de vue : une copie réduite ou recompressée (à fusionner
-- en gardant la plus grande) contre une version retouchée (à garder avec l'original).
-- Pur Lua, sans appel à Lightroom, pour pouvoir être testé à part.
--
-- Chaque version est décrite par une miniature de 16 × 16 pixels (768 octets, rouge-vert-bleu,
-- voir Vignettes.lua) et par ses dimensions après rotation EXIF. Mesures faites sur le catalogue
-- (copies de même nom d'origine et de même date, images différentes) :
--   - copie réduite ou recompressée : écart moyen de 0,3 à 1,5 sur 255 (au plus 10 sur un bloc) ;
--   - retouche (exposition, teinte, effacement, recadrage) : écart moyen de 4 et plus.
-- Les seuils sont placés entre les deux, du côté prudent : dans le doute, les deux versions sont
-- gardées. Un nom qui annonce une retouche (« -Modifier ») interdit cette comparaison approximative;
-- une empreinte exacte identique est traitée séparément comme un doublon.
-- Cette ressemblance ne prouve pas l'absence d'un détail modifié : Doublons.decider
-- laisse toutes les images d'empreintes différentes à vérifier explicitement.

local M = {}

M.ECART_MOYEN_MAX = 2.0   -- écart moyen sur l'ensemble des valeurs (0 à 255)
M.ECART_BLOC_MAX = 16     -- écart maximal sur une seule valeur
M.ECART_CANAL_MAX = 2.0   -- écart de la moyenne d'un canal (exposition, teinte)
M.TOLERANCE_FORME = 0.02  -- écart relatif toléré entre les rapports largeur / hauteur

-- Écarts entre deux miniatures de même taille : { moyen, max, canal } ou nil.
function M.ecarts(a, b)
  if type(a) ~= 'string' or type(b) ~= 'string' or #a ~= #b or #a == 0 or #a % 3 ~= 0 then return nil end
  local somme, max = 0, 0
  local canaux = { 0, 0, 0 }
  for i = 1, #a do
    local x, y = a:byte(i), b:byte(i)
    local d = math.abs(x - y)
    somme = somme + d
    if d > max then max = d end
    local c = (i - 1) % 3 + 1
    canaux[c] = canaux[c] + (x - y)
  end
  local nbPixels = #a / 3
  local canal = 0
  for c = 1, 3 do canal = math.max(canal, math.abs(canaux[c]) / nbPixels) end
  return { moyen = somme / #a, max = max, canal = canal }
end

-- Marqueurs de retouche dans un nom de fichier (motifs Lua, en minuscules) :
--   « -Modifier » et « -Modifié » (éditeurs externes en français, y compris « -Modifié-2026-08-02T22-37-43 »),
--   « -Edit », « -Edited », « -Retouche », « _filtered »,
--   « -20260821-DxO_DeepPRIME XD3 » et « -DxO_DeepPRIME 3 » (DxO PureRAW, avec ou sans date).
-- Pour en ajouter un, il suffit de l'inscrire ici : la comparaison visuelle approximative comme la
-- recherche des copies d'un même fichier (Doublons.nomDeBase) s'en servent. Le marqueur le plus
-- long (date + DxO) doit précéder le plus court, car nomDeBase les retire dans cet ordre.
M.MARQUEURS_RETOUCHE = { '%-modifi', '%-edit', '%-retouch', '[_%-]filtered',
  '%-%d%d%d%d%d%d%d%d%-dxo_', '[ _%-]dxo_' }

-- Vrai si le nom annonce une version retouchée.
function M.nomRetouche(nom)
  local bas = (nom:match('[^/\\]+$') or nom):lower()
  for _, marqueur in ipairs(M.MARQUEURS_RETOUCHE) do
    if bas:find(marqueur) then return true end
  end
  return false
end

-- Miniature carrée (côté × côté pixels RVB) tournée d'un quart de tour dans le sens horaire, ou nil.
-- La miniature est toujours réduite à un carré : tourner l'image puis la réduire revient à réduire
-- puis tourner la miniature.
function M.tourner(signature)
  local cote = math.floor(math.sqrt(#signature / 3) + 0.5)
  if cote * cote * 3 ~= #signature then return nil end
  local sortie = {}
  for y = 0, cote - 1 do
    for x = 0, cote - 1 do
      -- Le pixel (x, y) de l'image tournée vient du pixel (y, cote - 1 - x) de l'originale.
      local i = ((cote - 1 - x) * cote + y) * 3
      sortie[#sortie + 1] = signature:sub(i + 1, i + 3)
    end
  end
  return table.concat(sortie)
end

local function rotations(v)
  if not v.rotations or v.rotations[0] ~= v.signature then
    local r = { [0] = v.signature }
    for quart = 1, 3 do r[quart] = r[quart - 1] and M.tourner(r[quart - 1]) or nil end
    v.rotations = r
  end
  return v.rotations
end

-- Rotation (0, 90, 180 ou 270 degrés dans le sens horaire) qui fait de b la même vue que a, ou nil.
-- a, b : { signature, largeur, hauteur, retouchee } ; retouchee = tous les fichiers de cette
-- image portent un nom de retouche. Une copie tournée (Picasa, visionneuse…) reste la même photo.
function M.rotation(a, b)
  if not a.signature or not b.signature or a.retouchee or b.retouchee then return nil end
  if not (a.largeur and a.hauteur and b.largeur and b.hauteur) or a.hauteur == 0 or b.hauteur == 0 then return nil end
  local formeA, formeB = a.largeur / a.hauteur, b.largeur / b.hauteur
  local memeForme = math.abs(formeA / formeB - 1) <= M.TOLERANCE_FORME
  local formeTournee = math.abs(formeA * formeB - 1) <= M.TOLERANCE_FORME
  if not memeForme and not formeTournee then return nil end
  local tournees = rotations(b)
  for quart = 0, 3 do
    if (quart % 2 == 0 and memeForme or quart % 2 == 1 and formeTournee) and tournees[quart] then
      local e = M.ecarts(a.signature, tournees[quart])
      if e and e.moyen <= M.ECART_MOYEN_MAX and e.max <= M.ECART_BLOC_MAX and e.canal <= M.ECART_CANAL_MAX then
        -- b doit être tournée de quart × 90° pour ressembler à a : a est b tournée d'autant.
        return quart * 90
      end
    end
  end
  return nil
end

function M.memeVue(a, b)
  return M.rotation(a, b) ~= nil
end

-- Versions conservées à part : le rapport ne montre que celles qui gardent le cadrage de la plus grande
-- (exposition, teinte, recompression, rotation). Mesuré sur le catalogue, en corrélation des luminances
-- des miniatures : 0,98 à 1 pour ces versions, 0,42 au plus pour un fort recadrage, un redressement ou une
-- autre image au même nom et à la même date. Le seuil est placé entre les deux.
M.CORRELATION_CADRAGE_MIN = 0.8

local function luminances(signature)
  local l = {}
  for i = 1, #signature, 3 do
    l[#l + 1] = (signature:byte(i) + signature:byte(i + 1) + signature:byte(i + 2)) / 3
  end
  return l
end

local function correlation(a, b)
  local n = #a
  local ma, mb = 0, 0
  for i = 1, n do ma, mb = ma + a[i], mb + b[i] end
  ma, mb = ma / n, mb / n
  local cov, va, vb = 0, 0, 0
  for i = 1, n do
    local x, y = a[i] - ma, b[i] - mb
    cov, va, vb = cov + x * y, va + x * x, vb + y * y
  end
  if va == 0 or vb == 0 then return nil end
  return cov / math.sqrt(va * vb)
end

-- Vrai si b garde le cadrage de a, à un quart de tour près. Sans miniature exploitable (absente, unie),
-- rien ne permet d'écarter b : il est gardé.
function M.memeCadrage(a, b)
  if type(a.signature) ~= 'string' or type(b.signature) ~= 'string' or #a.signature ~= #b.signature
    or #a.signature == 0 or #a.signature % 3 ~= 0 then return true end
  local la = luminances(a.signature)
  local tournees = rotations(b)
  local mesuree = false
  for quart = 0, 3 do
    if tournees[quart] then
      local r = correlation(la, luminances(tournees[quart]))
      if r == nil then return true end
      mesuree = true
      if r >= M.CORRELATION_CADRAGE_MIN then return true end
    end
  end
  return not mesuree
end

-- classes : images différentes d'une même prise de vue possible, chacune
--   { pixels, octets, signature, largeur, hauteur, retouchee, … }.
-- Renvoie des groupes de classes qui montrent la même vue ; la première de chaque groupe est la
-- plus grande (pixels, puis taille du fichier), les autres sont des versions plus petites ou
-- recompressées d'elle. Les classes sans miniature, retouchées ou différentes restent seules.
-- Chaque classe est comparée à la plus grande seulement : pas d'enchaînement de ressemblances.
-- compatibles(a, b), facultatif : faux si deux classes ne peuvent pas être la même image quelle que
-- soit leur ressemblance (cadres voisins d'une rafale) ; une classe n'entre alors dans un groupe que
-- si elle est compatible avec chacune de ses classes.
--
-- Les images de mêmes dimensions peuvent se compter par milliers : comparer chacune à toutes les
-- autres serait trop long. memeVue exige un écart de moyenne d'au plus ECART_CANAL_MAX sur chaque
-- canal, donc aussi sur la moyenne générale de la miniature : seules les images dont la moyenne
-- est dans cette fenêtre sont comparées. Le résultat est le même qu'en comparant tout.
local function moyenne(signature)
  local somme = 0
  for i = 1, #signature do somme = somme + signature:byte(i) end
  return somme / #signature
end

function M.regrouper(classes, compatibles)
  local ordre = {}
  for i, c in ipairs(classes) do ordre[i] = c end
  table.sort(ordre, function(a, b)
    if (a.pixels or 0) ~= (b.pixels or 0) then return (a.pixels or 0) > (b.pixels or 0) end
    return (a.octets or 0) > (b.octets or 0)
  end)
  -- Index des images comparables, triées par moyenne de miniature.
  local rang, parMoyenne = {}, {}
  for i, c in ipairs(ordre) do
    rang[c] = i
    if type(c.signature) == 'string' and #c.signature > 0 then
      parMoyenne[#parMoyenne + 1] = { classe = c, moyenne = moyenne(c.signature) }
    end
  end
  table.sort(parMoyenne, function(a, b) return a.moyenne < b.moyenne end)
  local position = {}
  for i, e in ipairs(parMoyenne) do position[e.classe] = i end

  local placee, groupes = {}, {}
  for _, maitresse in ipairs(ordre) do
    if not placee[maitresse] then
      placee[maitresse] = true
      local groupe = { maitresse }
      local p = position[maitresse]
      if p then
        local centre = parMoyenne[p].moyenne
        local debut = p
        while debut > 1 and centre - parMoyenne[debut - 1].moyenne <= M.ECART_CANAL_MAX + 1e-9 do debut = debut - 1 end
        local candidates = {}
        local j = debut
        while j <= #parMoyenne and parMoyenne[j].moyenne - centre <= M.ECART_CANAL_MAX + 1e-9 do
          local c = parMoyenne[j].classe
          if not placee[c] and M.memeVue(maitresse, c) then candidates[#candidates + 1] = c end
          j = j + 1
        end
        -- Même ordre qu'une comparaison complète : de la plus grande à la plus petite.
        table.sort(candidates, function(a, b) return rang[a] < rang[b] end)
        for _, c in ipairs(candidates) do
          local accepte = true
          if compatibles then
            for _, membre in ipairs(groupe) do
              if not compatibles(membre, c) then accepte = false; break end
            end
          end
          if accepte then
            placee[c] = true
            groupe[#groupe + 1] = c
          end
        end
      end
      groupes[#groupes + 1] = groupe
    end
  end
  return groupes
end

return M
