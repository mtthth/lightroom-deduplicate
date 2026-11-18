-- Historique persistant des photos mises de côté par le module.
-- Le fichier est volontairement lisible et peut être conservé hors du catalogue Lightroom.

local LrFileUtils = import 'LrFileUtils'
local LrTasks = import 'LrTasks'

local M = {}

local function normaliser(chemin)
  return (chemin or ''):gsub('/', '\\'):lower()
end

-- Lit les chemins et les alias (nom/date) enregistrés. Les chemins identifient une photo tant
-- qu'elle reste au même endroit ; nom et date permettent de reconnaître une ligne Google Photos
-- si le fichier a ensuite été retiré du catalogue.
function M.lire(cheminFichier)
  local historique = { chemins = {}, entrees = {} }
  -- Le SDK lève une erreur si le fichier est absent ; ce n'est pas un historique illisible.
  if not LrFileUtils.exists(cheminFichier) then return historique end
  local contenu = LrFileUtils.readFile(cheminFichier)
  if not contenu then return historique end

  for ligne in contenu:gmatch('[^\r\n]+') do
    local type_, chemin, fichier, date = ligne:match('^([^\t]+)\t([^\t]*)\t([^\t]*)\t(.*)$')
    if chemin and ligne:sub(1, 1) ~= '#' then
      local entree = { type = type_, chemin = chemin, fichier = fichier, date = date }
      historique.chemins[normaliser(chemin)] = true
      table.insert(historique.entrees, entree)
    end
  end
  return historique
end

function M.contient(historique, chemin)
  return chemin ~= nil and historique.chemins[normaliser(chemin)] == true
end

local function ouvrirAjout(cheminFichier)
  local vide = not LrFileUtils.exists(cheminFichier)
    or (LrFileUtils.fileAttributes(cheminFichier) or {}).fileSize == 0
  local f = io.open(cheminFichier, 'ab')
  if not f then error('Impossible d’écrire l’historique des photos : ' .. cheminFichier, 0) end
  if vide then
    local ok, erreur = f:write('# type\tchemin\tfichier\tdate_prise_de_vue\r\n')
    if not ok then f:close(); error('Impossible d’écrire l’historique des photos : ' .. tostring(erreur), 0) end
  end
  return f
end

local function fermerAjout(f)
  local ok, erreur = f:close()
  if not ok then error('Impossible de terminer l’écriture de l’historique des photos : ' .. tostring(erreur), 0) end
end

-- Vérifie l'accès en écriture avant de modifier le catalogue, en créant l'en-tête si nécessaire.
function M.preparer(cheminFichier)
  M.lire(cheminFichier)
  fermerAjout(ouvrirAjout(cheminFichier))
end

-- Une copie autrefois écartée peut devenir la gardée d'une fusion manuelle. Retire uniquement ses
-- chemins de l'exclusion, sans perdre les autres lignes ni les commentaires. L'ancien fichier est
-- conservé en sauvegarde ; un échec de remplacement tente de le remettre en place.
local function filtrer(contenu, chemins)
  local voulus = {}
  for _, chemin in ipairs(chemins) do voulus[normaliser(chemin)] = true end
  local morceaux, nb, debut = {}, 0, 1
  while debut <= #contenu do
    local fin = contenu:find('[\r\n]', debut)
    local apres = fin and fin + 1 or #contenu + 1
    if fin and contenu:sub(fin, fin + 1) == '\r\n' then apres = apres + 1 end
    local ligne = contenu:sub(debut, (fin or #contenu + 1) - 1)
    local chemin = ligne:sub(1, 1) ~= '#' and ligne:match('^[^\t]+\t([^\t]*)\t') or nil
    if chemin and voulus[normaliser(chemin)] then
      nb = nb + 1
    else
      morceaux[#morceaux + 1] = contenu:sub(debut, apres - 1)
    end
    debut = apres
  end
  return table.concat(morceaux), nb
end

function M.contenu(cheminFichier)
  if not LrFileUtils.exists(cheminFichier) then return '' end
  return assert(LrFileUtils.readFile(cheminFichier), 'Impossible de lire l’historique des photos : ' .. cheminFichier)
end

-- Prépare le nouvel état en mémoire, pour l'enregistrer dans la même action annulable que le catalogue.
function M.modifier(contenu, options)
  contenu = filtrer(contenu, options.retablir or {})
  local connus, ajouts = {}, {}
  for ligne in contenu:gmatch('[^\r\n]+') do
    local chemin = ligne:sub(1, 1) ~= '#' and ligne:match('^[^\t]+\t([^\t]*)\t') or nil
    if chemin then connus[normaliser(chemin)] = true end
  end
  for _, photo in ipairs(options.photos or {}) do
    local cle = normaliser(photo.chemin)
    if photo.chemin and photo.chemin ~= '' and not connus[cle] then
      connus[cle] = true
      ajouts[#ajouts + 1] = table.concat({ options.type or 'doublon', photo.chemin, photo.fichier or '', photo.date or '' }, '\t') .. '\r\n'
    end
  end
  if #ajouts > 0 then
    if contenu == '' then contenu = '# type\tchemin\tfichier\tdate_prise_de_vue\r\n'
    elseif not contenu:match('[\r\n]$') then contenu = contenu .. '\r\n' end
    contenu = contenu .. table.concat(ajouts)
  end
  return contenu
end

local function indexer(contenu)
  local lignes = {}
  for ligne in (contenu or ''):gmatch('[^\r\n]+') do
    if ligne:sub(1, 1) ~= '#' then
      local chemin = ligne:match('^[^\t]+\t([^\t]+)\t[^\t]*\t.*$')
      assert(chemin, 'Ligne invalide dans l’historique : synchronisation interrompue')
      lignes[normaliser(chemin)] = ligne
    end
  end
  return lignes
end

-- Applique uniquement le delta avant/après. Les autres chemins et les éditions
-- externes d'une ligne concernée restent intacts, ainsi que les commentaires.
function M.transition(avant, apres, courant)
  local a, b, c = indexer(avant), indexer(apres), indexer(courant)
  local cles, retraits, ajouts = {}, {}, {}
  for cle in pairs(a) do cles[cle] = true end
  for cle in pairs(b) do cles[cle] = true end
  local ordre = {}
  for cle in pairs(cles) do ordre[#ordre + 1] = cle end
  table.sort(ordre)
  for _, cle in ipairs(ordre) do
    if a[cle] ~= b[cle] and c[cle] == a[cle] then
      if a[cle] then retraits[#retraits + 1] = cle end
      if b[cle] then ajouts[#ajouts + 1] = b[cle] .. '\r\n' end
    end
  end
  courant = filtrer(courant, retraits)
  if #ajouts > 0 then
    if courant ~= '' and not courant:match('[\r\n]$') then courant = courant .. '\r\n' end
    courant = courant .. table.concat(ajouts)
  end
  return courant
end

local function hex(s) return (s:gsub('.', function(c) return string.format('%02x', c:byte()) end)) end
local function dehex(s)
  assert(#s % 2 == 0 and not s:find('[^%da-f]'), 'Journal d’historique invalide')
  return (s:gsub('..', function(x) return string.char(tonumber(x, 16)) end))
end

-- Les témoins de photos sélectionnent ce journal de deltas après Undo/Redo, jamais une copie complète du
-- fichier partagé. Importer une édition externe dans un snapshot annulable la
-- ferait disparaître lors d'un Ctrl+Z plus ancien, même après synchronisation.
function M.journaliser(journal, avant, apres)
  local a, b, cles, ordre = indexer(avant), indexer(apres), {}, {}
  for cle in pairs(a) do cles[cle] = true end
  for cle in pairs(b) do cles[cle] = true end
  for cle in pairs(cles) do ordre[#ordre + 1] = cle end
  table.sort(ordre)
  local lignes = { journal or '' }
  for _, cle in ipairs(ordre) do
    if a[cle] ~= b[cle] then
      lignes[#lignes + 1] = hex(a[cle] or '') .. '\t' .. hex(b[cle] or '') .. '\n'
    end
  end
  return table.concat(lignes)
end

function M.rejouer(avant, apres, courant)
  local function lire(journal)
    local r = {}
    assert(journal == '' or journal:sub(-1) == '\n', 'Journal d’historique tronqué')
    for ligne in journal:gmatch('[^\n]+') do
      local a, b = ligne:match('^([%da-f]*)\t([%da-f]*)$')
      assert(a and b, 'Journal d’historique invalide')
      r[#r + 1] = { ligne = ligne, avant = dehex(a), apres = dehex(b) }
    end
    return r
  end
  local a, b = lire(avant or ''), lire(apres or '')
  local commun = 0
  while a[commun + 1] and b[commun + 1] and a[commun + 1].ligne == b[commun + 1].ligne do commun = commun + 1 end
  local changements = {}
  local function changer(source, cible)
    local ligne = source ~= '' and source or cible
    local chemin = assert(ligne:match('^[^\t]+\t([^\t]+)\t[^\t]*\t.*$'), 'Delta d’historique invalide')
    local cle = normaliser(chemin)
    if not changements[cle] then changements[cle] = { avant = source } end
    changements[cle].apres = cible
  end
  for i = #a, commun + 1, -1 do changer(a[i].apres, a[i].avant) end
  for i = commun + 1, #b do changer(b[i].avant, b[i].apres) end
  local sources, cibles = {}, {}
  for _, changement in pairs(changements) do
    if changement.avant ~= '' then sources[#sources + 1] = changement.avant end
    if changement.apres ~= '' then cibles[#cibles + 1] = changement.apres end
  end
  return M.transition(table.concat(sources, '\n'), table.concat(cibles, '\n'), courant)
end

-- Remplacement avec sauvegarde, partagé par la restauration et le suivi de Ctrl+Z / Rétablir.
function M.ecrire(cheminFichier, contenu)
  if LrFileUtils.exists(cheminFichier) and M.contenu(cheminFichier) == contenu then return end

  local temporaire = LrFileUtils.chooseUniqueFileName(cheminFichier .. '.tmp')
  local f = io.open(temporaire, 'wb')
  if not f then error('Impossible de préparer le rétablissement de l’historique : ' .. temporaire, 0) end
  local ok, erreur = f:write(contenu)
  if not ok then f:close(); error('Impossible de rétablir l’historique : ' .. tostring(erreur), 0) end
  fermerAjout(f)

  local sauvegarde
  if LrFileUtils.exists(cheminFichier) then
    sauvegarde = LrFileUtils.chooseUniqueFileName(cheminFichier .. '.bak')
    local deplace, resultat, detail = LrTasks.pcall(LrFileUtils.move, cheminFichier, sauvegarde)
    if not deplace or not resultat then
      error('Impossible de sauvegarder l’historique avant rétablissement : ' .. tostring(detail or resultat), 0)
    end
  end
  local deplace, resultat, detail = LrTasks.pcall(LrFileUtils.move, temporaire, cheminFichier)
  if not deplace or not resultat then
    local restaure, retour
    if sauvegarde then restaure, retour = LrTasks.pcall(LrFileUtils.move, sauvegarde, cheminFichier) end
    error('Impossible de remplacer l’historique : ' .. tostring(detail or resultat)
      .. ((restaure and retour) and ' (ancien fichier restauré).' or (' (fichier préparé conservé : ' .. temporaire .. ').')), 0)
  end
end

function M.retablir(cheminFichier, chemins)
  local contenu, nb = filtrer(M.contenu(cheminFichier), chemins)
  if nb > 0 then M.ecrire(cheminFichier, contenu) end
  return nb
end

-- Ajoute seulement les chemins nouveaux. Chaque ligne contient type, chemin, nom et date,
-- séparés par des tabulations (caractères interdits dans un nom de fichier Windows).
function M.ajouter(cheminFichier, type_, photos)
  local historique = M.lire(cheminFichier)
  local nouvelles = {}
  for _, photo in ipairs(photos) do
    local chemin = photo.chemin
    local cle = normaliser(chemin)
    if chemin and chemin ~= '' and not historique.chemins[cle] then
      historique.chemins[cle] = true
      local entree = {
        type = type_, chemin = chemin, fichier = photo.fichier or '', date = photo.date or '',
      }
      table.insert(nouvelles, entree)
      table.insert(historique.entrees, entree)
    end
  end
  if #nouvelles == 0 then return historique end

  local f = ouvrirAjout(cheminFichier)
  for _, entree in ipairs(nouvelles) do
    local ok, erreur = f:write(entree.type, '\t', entree.chemin, '\t', entree.fichier, '\t', entree.date, '\r\n')
    if not ok then f:close(); error('Impossible d’écrire l’historique des photos : ' .. tostring(erreur), 0) end
  end
  fermerAjout(f)
  return historique
end

return M
