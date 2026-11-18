-- Empreinte (MD5) du contenu, en conservant les données nécessaires au rendu.
-- Une différence de métadonnées pouvant affecter l'image doit rester distincte.
--   JPEG : les segments de décodage (DQT, DHT, SOF, DRI…, le scan et tout ce qui le suit), le profil
--     couleur ICC, le segment Adobe (transformation des couleurs) et l'orientation lue dans l'EXIF et
--     le XMP. Les autres métadonnées (dates, logiciel, mots-clés, vignette EXIF, IPTC, JFIF,
--     commentaires) ne changent pas l'image : un fichier dont seules elles ont été réécrites
--     garde la même empreinte. Un EXIF ou un XMP dont l'orientation est illisible est conservé entier ;
--   HEIC, MP4… (format ISO à boîtes « ftyp ») : contenu des boîtes « mdat » ;
--   autres formats : tout le fichier.
-- Lecture par LrFileUtils.readFile, la seule qui gère les chemins accentués (« Désordre »…).
-- Au-delà de 64 Mo, le début et la fin ne constituent qu'un préfiltre ; empreinteComplete lit
-- ensuite tout le fichier par blocs pour vérifier les candidats sans charger la vidéo en mémoire.
-- Les vidéos sont comparées intégralement, métadonnées et structure du conteneur comprises.

local LrFileUtils = import 'LrFileUtils'
local LrMD5 = import 'LrMD5'
local LrTasks = import 'LrTasks'

local M = {}

local GROS = 64 * 1024 * 1024
local MORCEAU = 8 * 1024 * 1024
local VIDEOS = { mp4 = true, mov = true, avi = true, mts = true, m2ts = true, mkv = true,
  wmv = true, ['3gp'] = true, ['3g2'] = true, m4v = true, mpg = true, mpeg = true,
  webm = true, flv = true, m2v = true, vob = true, ts = true }
local compteur = 0

function M.estVideo(chemin)
  local extension = (chemin or ''):match('%.([^%./\\]*)$')
  return extension ~= nil and VIDEOS[extension:lower()] == true
end

-- Ne pas confondre le flux compressé avec l'image : les tables DQT/DHT, le SOF,
-- l'orientation et les profils couleur changent les pixels sans changer le premier scan.

-- Orientation (1 à 8) du bloc TIFF d'un EXIF, false si absente, nil si le bloc est illisible.
local function orientationExif(tiff)
  local ordre = tiff:sub(1, 2)
  if ordre ~= 'II' and ordre ~= 'MM' then return nil end
  local function u16(i)
    local a, b = tiff:byte(i, i + 1)
    if not b then return nil end
    return ordre == 'II' and (b * 256 + a) or (a * 256 + b)
  end
  local function u32(i)
    local a, b = u16(i), u16(i + 2)
    if not a or not b then return nil end
    return ordre == 'II' and (b * 65536 + a) or (a * 65536 + b)
  end
  if u16(3) ~= 42 then return nil end
  local ifd = u32(5)
  if not ifd then return nil end
  local nombre = u16(ifd + 1)
  if not nombre then return nil end
  for k = 0, nombre - 1 do
    local entree = ifd + 3 + 12 * k
    local tag, genre = u16(entree), u16(entree + 2)
    if not tag or not genre then return nil end
    if tag == 0x0112 then
      local valeur = genre == 3 and u16(entree + 8) or nil
      -- 0 (« inconnue », écrit par certains logiciels) s'affiche comme 1, sans rotation.
      if valeur == 0 then return 1 end
      if not valeur or valeur > 8 then return nil end
      return valeur
    end
  end
  return false
end

-- Orientation d'un paquet XMP, false si absente, nil si sa valeur est illisible.
local function orientationXmp(xmp)
  local valeur = xmp:match('tiff:Orientation%s*=%s*["\'](%d+)["\']') or xmp:match('<tiff:Orientation>%s*(%d+)%s*<')
  if valeur then
    valeur = tonumber(valeur)
    return valeur >= 1 and valeur <= 8 and valeur or nil
  end
  if xmp:find('Orientation', 1, true) then return nil end
  return false
end

local EXIF, XMP = 'Exif\0\0', 'http://ns.adobe.com/xap/1.0/\0'

local function donneesJpeg(octets)
  if octets:byte(1) ~= 0xFF or octets:byte(2) ~= 0xD8 then return nil end
  local morceaux, i = { octets:sub(1, 2) }, 3
  local exif, xmp = false, false
  local function retenirOrientation(segment, contenu)
    local prefixe, lire = nil, nil
    if contenu:sub(1, #EXIF) == EXIF then prefixe, lire = EXIF, orientationExif
    elseif contenu:sub(1, #XMP) == XMP then prefixe, lire = XMP, orientationXmp
    else return end
    local valeur = lire(contenu:sub(#prefixe + 1))
    -- Orientation illisible : le segment entier reste dans l'empreinte, par prudence.
    if valeur == nil then morceaux[#morceaux + 1] = segment; return end
    if valeur and prefixe == EXIF then exif = valeur elseif valeur then xmp = valeur end
  end
  while i + 3 <= #octets do
    local ff, marqueur = octets:byte(i, i + 1)
    if ff ~= 0xFF then return nil end
    if marqueur == 0xFF then
      morceaux[#morceaux + 1] = octets:sub(i, i)
      i = i + 1
    else
      local fort, faible = octets:byte(i + 2, i + 3)
      local taille = fort * 256 + faible
      if taille < 2 or i + 1 + taille > #octets then return nil end
      if marqueur == 0xDA then
        -- Les scans suivants et leurs tables sont conservés sans les réinterpréter.
        morceaux[#morceaux + 1] = octets:sub(i)
        -- Orientation effective, que le lecteur privilégie l'EXIF ou le XMP.
        local parExif = exif or 1
        table.insert(morceaux, 2, string.format('orientation:%d,%d;', parExif, xmp or parExif))
        return table.concat(morceaux)
      end
      local segment = octets:sub(i, i + 1 + taille)
      local contenu = segment:sub(5)
      if marqueur == 0xE1 then
        retenirOrientation(segment, contenu)
      elseif marqueur == 0xE2 then
        if contenu:sub(1, 12) == 'ICC_PROFILE\0' then morceaux[#morceaux + 1] = segment end
      elseif marqueur == 0xEE then
        morceaux[#morceaux + 1] = segment
      elseif not (marqueur >= 0xE0 and marqueur <= 0xEF) and marqueur ~= 0xFE then
        morceaux[#morceaux + 1] = segment
      end
      i = i + 2 + taille
    end
  end
  return nil
end

local function entier32(octets, i)
  local a, b, c, d = octets:byte(i, i + 3)
  return ((a * 256 + b) * 256 + c) * 256 + d
end

-- Contenu des boîtes « mdat » d'un fichier au format ISO (HEIC, MP4…), ou nil.
local function donneesMdat(octets)
  if octets:sub(5, 8) ~= 'ftyp' then return nil end
  local morceaux, i = {}, 1
  while i + 7 <= #octets do
    local taille, entete = entier32(octets, i), 8
    local genre = octets:sub(i + 4, i + 7)
    if taille == 1 and i + 15 <= #octets then
      taille, entete = entier32(octets, i + 8) * 4294967296 + entier32(octets, i + 12), 16
    elseif taille == 0 then
      taille = #octets - i + 1
    end
    if taille < entete then break end
    if genre == 'mdat' then morceaux[#morceaux + 1] = octets:sub(i + entete, i + taille - 1) end
    i = i + taille
  end
  return #morceaux > 0 and table.concat(morceaux) or nil
end

-- Empreinte d'un contenu de fichier déjà lu.
function M.empreinteContenu(octets)
  local jpeg = donneesJpeg(octets)
  if jpeg then return 'jpeg:' .. LrMD5.digest(jpeg) end
  local mdat = donneesMdat(octets)
  if mdat then return 'mdat:' .. LrMD5.digest(mdat) end
  return 'brut:' .. LrMD5.digest(octets)
end

-- io.open ne gère pas tous les chemins Unicode dans Lightroom sous Windows : dans ce seul
-- cas, le SDK copie la source dans le dossier temporaire. Le fichier ouvert et cette copie
-- sont nettoyés aussi sur erreur ou annulation.
local function avecSource(chemin, estAnnule, travail)
  local fichier, temporaire
  local ok, resultat = LrTasks.pcall(function()
    if estAnnule and estAnnule() then return nil end
    fichier = io.open(chemin, 'rb')
    if not fichier then
      local LrPathUtils = import 'LrPathUtils'
      compteur = compteur + 1
      temporaire = LrFileUtils.chooseUniqueFileName(LrPathUtils.child(
        LrPathUtils.getStandardFilePath('temp'), 'lrgp-empreinte-' .. compteur .. '.tmp'))
      if estAnnule and estAnnule() then return nil end
      if not LrFileUtils.copy(chemin, temporaire) then return nil end
      fichier = io.open(temporaire, 'rb')
      if not fichier then return nil end
    end
    return travail(fichier)
  end)
  if fichier then
    local ferme, retour = LrTasks.pcall(function() return fichier:close() end)
    if not ferme or not retour then ok = false end
  end
  if temporaire then LrTasks.pcall(LrFileUtils.delete, temporaire) end
  return ok and resultat or nil
end

-- Gros fichier : début et fin seulement. Une égalité ne prouve pas l'identité des fichiers.
local function empreinteGros(chemin, taille)
  return avecSource(chemin, nil, function(fichier)
    local debut = fichier:read(MORCEAU)
    if not debut or #debut ~= MORCEAU then return nil end
    if not fichier:seek('set', taille - MORCEAU) then return nil end
    local fin = fichier:read(MORCEAU)
    if not fin or #fin ~= MORCEAU then return nil end
    return 'gros:' .. taille .. ':' .. LrMD5.digest(debut) .. LrMD5.digest(fin)
  end)
end

-- Renvoie l'empreinte du fichier, ou nil s'il est illisible (absent, hors ligne…).
function M.empreinte(chemin, video)
  local attributs = LrFileUtils.fileAttributes(chemin)
  if not attributs or not attributs.fileSize then return nil end
  if attributs.fileSize > GROS then return empreinteGros(chemin, attributs.fileSize) end
  local octets = LrFileUtils.readFile(chemin)
  if not octets then return nil end
  if video == nil then video = M.estVideo(chemin) end
  if video then return 'brut:' .. LrMD5.digest(octets) end
  return M.empreinteContenu(octets)
end

-- SHA256 de tous les octets, à mémoire bornée. Chaque bloc laisse Lightroom répondre et permet
-- d'annuler avant de lire le suivant. Un fichier partiellement lu ne produit aucune empreinte.
function M.empreinteComplete(chemin, estAnnule)
  local ok, attributs = LrTasks.pcall(LrFileUtils.fileAttributes, chemin)
  if not ok or not attributs or not attributs.fileSize then return nil end
  return avecSource(chemin, estAnnule, function(fichier)
    if estAnnule and estAnnule() then return nil end
    local digesteur = (import 'LrDigest').SHA256.init()
    local lus = 0
    while true do
      if estAnnule and estAnnule() then return nil end
      local bloc, erreur = fichier:read(MORCEAU)
      if not bloc then
        if erreur then return nil end
        break
      end
      if #bloc == 0 then break end
      lus = lus + #bloc
      if lus > attributs.fileSize then return nil end
      digesteur:update(bloc)
      LrTasks.yield()
    end
    if lus ~= attributs.fileSize then return nil end
    return 'complet:' .. digesteur:digest()
  end)
end

return M
