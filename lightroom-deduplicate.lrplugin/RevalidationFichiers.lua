-- Le cache accélère l'analyse, mais ne constitue jamais la preuve utilisée pour appliquer une fusion.
local Doublons = require 'Doublons'
local M = {}
local T = require('Langue').t
function M.verifier(decisions, progression, empreintes, vignettes, cache, diagnostic, parallele)
  local copies, vus, preuves = {}, {}, {}
  for _, d in ipairs(decisions) do
    assert(d.forcee or Doublons.comparaisonsValides(d),
      T('Les images ne ressemblent pas toutes à la copie gardée : relancez la recherche ou confirmez une fusion de force.', 'Not all images look like the kept copy: run the search again or confirm a forced merge.'))
    local liste = { d.garde }
    for _, c in ipairs(d.retirees) do liste[#liste + 1] = c end
    local approximative = false
    for _, c in ipairs(liste) do if c.empreinte ~= d.garde.empreinte then approximative = true end end
    for _, c in ipairs(liste) do
      if not vus[c.chemin] then vus[c.chemin] = true; copies[#copies + 1] = c end
      if approximative and c.preuveComparaison then preuves[c.preuveComparaison.chemin] = c.preuveComparaison end
    end
    if approximative then
      local parImage = {}
      for _, c in ipairs(liste) do if c.preuveComparaison then parImage[c.empreinte] = true end end
      for _, c in ipairs(liste) do
        assert(parImage[c.empreinte], T('Preuve de comparaison absente : relancez la recherche avant de fusionner.', 'Comparison proof missing: run the search again before merging.'))
      end
    end
  end
  if diagnostic then diagnostic:compteurs('revalidation', { photos = #copies, cache_utilise = false }) end
  for i, c in ipairs(copies) do
    if progression:isCanceled() then return false end
    progression:setCaption(string.format(T('Vérification des fichiers avant fusion : %d / %d', 'Checking files before merging: %d / %d'), i, #copies))
    progression:setPortionComplete(i, #copies)
    local complete = c.empreinte and c.empreinte:match('^complet:')
    local valeur
    if complete then valeur = empreintes.empreinteComplete(c.chemin, function() return progression:isCanceled() end)
    else valeur = empreintes.empreinte(c.chemin, c.video) end
    if progression:isCanceled() then return false end
    if cache and valeur then cache:retenir(complete and 'G' or 'F', c.chemin, valeur) end
    if not valeur or valeur ~= c.empreinte then
      error(T('Le fichier a changé ou n’est plus lisible :\n', 'The file has changed or is no longer readable:\n') .. c.chemin
        .. T('\nFusion interrompue avant toute modification. Relancez la recherche pour actualiser le rapport.',
          '\nMerge stopped before any change. Run the search again to update the report.'), 0)
    end
  end
  -- Miniatures recalculées par ImageMagick, sans le cache. parallele(elements, tache, legende), s'il est
  -- fourni, les calcule plusieurs à la fois (Parallele.pourChaque) et renvoie false si l'utilisateur annule.
  -- Une image n'est validée que si sa tâche est allée jusqu'au bout : une erreur dans une tâche parallèle
  -- (ignorée par pourChaque) ou un arrêt anticipé laisse l'image non validée, et la fusion est refusée.
  local liste = {}
  for path, attendu in pairs(preuves) do liste[#liste + 1] = { chemin = path, attendu = attendu } end
  table.sort(liste, function(x, y) return x.chemin < y.chemin end)
  -- Une image qui échoue est relue une seconde fois, seule : un appel à ImageMagick peut échouer de
  -- façon passagère quand plusieurs tournent à la fois. La cause de chaque échec va au diagnostic.
  local validees, causes = {}, {}
  local function verifierPreuve(p)
    local actuel = vignettes.signature(p.chemin)
    if cache and actuel then cache:retenir('S', p.chemin, actuel) end
    if not actuel then
      causes[p] = T('n’a pas pu être relue', 'could not be re-read')
    elseif actuel.largeur ~= p.attendu.largeur or actuel.hauteur ~= p.attendu.hauteur then
      causes[p] = string.format(T('dimensions %dx%d au lieu de %dx%d', 'dimensions %dx%d instead of %dx%d'), actuel.largeur, actuel.hauteur,
        p.attendu.largeur, p.attendu.hauteur)
    elseif actuel.signature ~= p.attendu.signature then
      causes[p] = T('miniature différente', 'different thumbnail')
    else
      validees[p], causes[p] = true, nil
    end
  end
  local legende = T('Vérification des comparaisons avant fusion : %d / %d', 'Checking comparisons before merging: %d / %d')
  if #liste > 0 then progression:setPortionComplete(0, #liste) end
  if parallele then
    if not parallele(liste, verifierPreuve, legende) then return false end
  else
    for i, p in ipairs(liste) do
      if progression:isCanceled() then return false end
      progression:setCaption(string.format(legende, i, #liste))
      progression:setPortionComplete(i, #liste)
      verifierPreuve(p)
    end
  end
  if progression:isCanceled() then return false end
  local echec
  for _, p in ipairs(liste) do
    if not validees[p] then
      local premiere = causes[p] or 'non traitée'
      progression:setCaption(T('Nouvelle lecture : ', 'Reading again: ') .. p.chemin)
      verifierPreuve(p)   -- une erreur ici interrompt la fusion
      if progression:isCanceled() then return false end
      if diagnostic then
        diagnostic:compteurs('revalidation_echec', { chemin = p.chemin, premiere = premiere,
          seconde = validees[p] and 'ok' or (causes[p] or 'erreur') })
      end
      if not validees[p] and not echec then echec = p end
    end
  end
  if echec then
    error(T('L’image ou son orientation a changé depuis la comparaison (', 'The image or its orientation has changed since the comparison (')
      .. (causes[echec] or T('n’a pas pu être relue', 'could not be re-read'))
      .. T(') :\n', '):\n') .. echec.chemin .. T('\nFusion interrompue avant toute modification. Relancez la recherche.',
        '\nMerge stopped before any change. Run the search again.'), 0)
  end
  return true
end
return M
