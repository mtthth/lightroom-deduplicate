-- Aperçu d'une vidéo pour le rapport HTML des doublons : IMAGES images prises aux mêmes positions relatives
-- de la durée (10 %, 30 %, 50 %…), côte à côte dans un bandeau JPEG. Les bandeaux des copies d'un groupe,
-- l'un sous l'autre, se comparent image par image. Nécessite ffmpeg et ffprobe, puis ImageMagick pour
-- assembler le bandeau.
--
-- Module à part de Vignettes.lua : le source de Vignettes.lua sert de version au cache des signatures
-- (cache_analyses.py), le modifier ferait tout recalculer.
--
-- Chemins : comme dans Vignettes.lua, un fichier dont le chemin n'est pas en ASCII simple est copié sous un
-- nom simple dans le dossier temporaire (cmd.exe lit mal les accents), puis supprimé.

local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local LrTasks = import 'LrTasks'

local M = {}

M.IMAGES = 5
local LARGEUR, HAUTEUR = 176, 132

local function cheminSimple(chemin)
  return chemin:find('^[%w %.%_%-#,;@%(%)\\/:~%+=]+$') ~= nil
end

-- recherche : nil (pas commencée), 'en cours' ou 'faite'. Les aperçus sont générés par plusieurs tâches en
-- parallèle et la recherche cède la main (lecture des dossiers) : une tâche qui arrive pendant la recherche
-- l'attend, au lieu de conclure qu'ffmpeg est absent et de laisser sa vidéo sans aperçu.
local ffmpeg, recherche = nil, nil

local function chercher()
  local function essayer(bin)
    if not ffmpeg and cheminSimple(bin) and LrFileUtils.exists(LrPathUtils.child(bin, 'ffmpeg.exe')) == 'file'
      and LrFileUtils.exists(LrPathUtils.child(bin, 'ffprobe.exe')) == 'file' then
      ffmpeg = bin
    end
  end
  local function parcourir(dossier, profondeur)
    if ffmpeg or LrFileUtils.exists(dossier) ~= 'directory' then return end
    essayer(LrPathUtils.child(dossier, 'bin'))
    if profondeur == 0 then return end
    LrTasks.pcall(function()
      for entree in LrFileUtils.directoryEntries(dossier) do
        if LrFileUtils.exists(entree) == 'directory' then parcourir(entree, profondeur - 1) end
      end
    end)
  end
  local ok, home = LrTasks.pcall(LrPathUtils.getStandardFilePath, 'home')
  if ok and home then
    local paquets = LrPathUtils.child(home, 'AppData\\Local\\Microsoft\\WinGet\\Packages')
    if LrFileUtils.exists(paquets) == 'directory' then
      LrTasks.pcall(function()
        for entree in LrFileUtils.directoryEntries(paquets) do
          if not ffmpeg and LrPathUtils.leafName(entree):lower():find('ffmpeg', 1, true) then parcourir(entree, 1) end
        end
      end)
    end
  end
  for _, dossier in ipairs({ 'C:\\ffmpeg', 'C:\\Program Files\\ffmpeg', 'C:\\Program Files (x86)\\ffmpeg' }) do
    parcourir(dossier, 1)
  end
end

-- Dossier bin d'ffmpeg (ffmpeg.exe et ffprobe.exe) : installation winget, C:\ffmpeg ou Program Files. Ou nil.
function M.ffmpeg()
  while recherche == 'en cours' do LrTasks.sleep(0.05) end
  if recherche == 'faite' then return ffmpeg end
  recherche = 'en cours'
  LrTasks.pcall(chercher)
  recherche = 'faite'
  return ffmpeg
end

local compteur = 0
local session = (import 'LrMD5').digest(tostring({}) .. os.time())

local function executer(commande) return LrTasks.execute('"' .. commande .. '"') end

-- Écrit le bandeau de la vidéo `chemin` dans `destination`. magick : chemin de magick.exe. Renvoie true si
-- le bandeau est écrit, nil sinon (ffmpeg absent, vidéo illisible).
function M.ecrire(chemin, destination, magick)
  local bin = M.ffmpeg()
  if not bin or not magick then return nil end
  -- Numéro lu avant tout appel au SDK : getStandardFilePath peut rendre la main, et une autre tâche
  -- incrémenterait alors le compteur entre-temps (deux tâches dans les mêmes fichiers temporaires).
  compteur = compteur + 1
  local numero = compteur
  local base = LrPathUtils.child(LrPathUtils.getStandardFilePath('temp'), 'lrdedup-video-' .. session .. '-' .. numero)
  local temporaires = {}
  local ok, resultat = LrTasks.pcall(function()
    local source = chemin
    if not cheminSimple(chemin) then
      local extension = (chemin:match('%.(%w+)$') or ''):lower()
      source = base .. '-source' .. (extension ~= '' and ('.' .. extension) or '')
      temporaires[#temporaires + 1] = source
      if not LrFileUtils.copy(chemin, source) then return nil end
    end
    local duree = base .. '-duree.txt'
    temporaires[#temporaires + 1] = duree
    executer(string.format('"%s" -v error -show_entries format=duration -of csv=p=0 "%s" > "%s" 2>nul',
      LrPathUtils.child(bin, 'ffprobe.exe'), source, duree))
    local texte = LrFileUtils.readFile(duree)
    local secondes = texte and tonumber(texte:match('[%d%.]+')) or 0
    local images, lues = {}, 0
    for i = 1, M.IMAGES do
      local image = string.format('%s-%d.jpg', base, i)
      temporaires[#temporaires + 1] = image
      executer(string.format(
        '"%s" -v error -ss %.3f -i "%s" -frames:v 1 -vf "scale=%d:%d:force_original_aspect_ratio=decrease,'
        .. 'pad=%d:%d:(ow-iw)/2:(oh-ih)/2:color=0x202020" -y "%s" 2>nul',
        LrPathUtils.child(bin, 'ffmpeg.exe'), secondes * (2 * i - 1) / (2 * M.IMAGES), source,
        LARGEUR, HAUTEUR, LARGEUR, HAUTEUR, image))
      -- Une image illisible laisse une case vide : les bandeaux d'un groupe restent alignés.
      if LrFileUtils.exists(image) == 'file' then
        images[i] = '"' .. image .. '"'; lues = lues + 1
      else
        images[i] = string.format('-size %dx%d xc:#202020', LARGEUR, HAUTEUR)
      end
    end
    if lues == 0 then return nil end
    local sortie = base .. '-bandeau.jpg'
    temporaires[#temporaires + 1] = sortie
    executer(string.format('"%s" %s +append -strip -quality 72 "%s" 2>nul', magick, table.concat(images, ' '), sortie))
    if LrFileUtils.exists(sortie) ~= 'file' then return nil end
    if LrFileUtils.exists(destination) then LrFileUtils.delete(destination) end
    return LrFileUtils.move(sortie, destination) and true or nil
  end)
  for _, fichier in ipairs(temporaires) do
    if LrFileUtils.exists(fichier) then LrTasks.pcall(LrFileUtils.delete, fichier) end
  end
  return ok and resultat or nil
end

return M
