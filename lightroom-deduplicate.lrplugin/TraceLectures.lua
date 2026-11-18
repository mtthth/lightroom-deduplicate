-- Journal persistant avant/après chaque appel : reste lisible même si le SDK ne rend pas la main.
local LrDate = import 'LrDate'
local LrTasks = import 'LrTasks'
local M = {}
local function texte(v)
  return tostring(v == nil and '?' or v):gsub('[\r\n\t]', ' ')
end
function M.ouvrir(chemin, progression, commande)
  local sequence = 0
  local origine = LrDate.currentTime()
  local session = os.date('%Y%m%d-%H%M%S') .. '-' .. tostring({}):gsub('[^%w]', '')
  local ferme = false
  local etapes = {}
  local function ecrire(ligne)
    local f, erreur = io.open(chemin, 'ab')
    if not f then error('Impossible d’écrire le diagnostic : ' .. tostring(erreur), 0) end
    local ok, probleme = f:write(os.date('%Y-%m-%d %H:%M:%S') .. '\t' .. ligne .. '\trun=' .. session .. '\n')
    f:close()
    if not ok then error('Impossible d’écrire le diagnostic : ' .. tostring(probleme), 0) end
  end
  ecrire('SESSION\tDiagnostic 1.0.2\tcommande=' .. texte(commande or 'lecture des collections'))
  local trace = { chemins = {}, progression = progression }
  local function champs(valeurs)
    local cles, r = {}, {}
    for cle in pairs(valeurs or {}) do cles[#cles + 1] = cle end
    table.sort(cles)
    for _, cle in ipairs(cles) do r[#r + 1] = texte(cle) .. '=' .. texte(valeurs[cle]) end
    return table.concat(r, '\t')
  end
  function trace:compteurs(nom, valeurs) ecrire('COMPTEURS\t' .. texte(nom) .. '\t' .. champs(valeurs)) end
  function trace:debutEtape(nom, valeurs)
    local debut, terminee = LrDate.currentTime(), false
    ecrire('ETAPE_DEBUT\t' .. texte(nom) .. '\t' .. champs(valeurs))
    local function finir(etat, autres)
      if terminee then return end
      terminee = true
      ecrire('ETAPE_FIN\t' .. texte(nom) .. '\tsecondes=' .. string.format('%.3f', LrDate.currentTime() - debut)
        .. '\tetat=' .. texte(etat or 'ok') .. '\t' .. champs(autres))
    end
    etapes[#etapes + 1] = finir
    return finir
  end
  local function pack(...) return { n = select('#', ...), ... } end
  local unpackResultat = unpack or table.unpack
  function trace:mesurer(nom, valeurs, travail)
    local finir = self:debutEtape(nom, valeurs)
    local retour = pack(LrTasks.pcall(travail))
    finir(retour[1] and 'ok' or 'erreur')
    if not retour[1] then error(retour[2], 0) end
    return unpackResultat(retour, 2, retour.n)
  end
  function trace:fin(etat)
    if ferme then return end
    ferme = true
    for _, terminerEtape in ipairs(etapes) do terminerEtape(etat or 'interrompu') end
    ecrire('SESSION_FIN\tetat=' .. texte(etat) .. '\tsecondes=' .. string.format('%.3f', LrDate.currentTime() - origine))
  end
  function trace:appel(contexte, operation, lire)
    sequence = sequence + 1
    local n, debut = sequence, LrDate.currentTime()
    local identite = 'photo=' .. texte(contexte.numero) .. '/' .. texte(contexte.total)
      .. '\tid=' .. texte(contexte.id) .. '\tchemin=' .. texte(contexte.chemin)
      .. '\tcollection=' .. texte(contexte.collection) .. '\tnom=' .. texte(contexte.nom)
    ecrire('DEBUT\t' .. n .. '\t' .. operation .. '\t' .. identite)
    local fichier = (contexte.chemin or ''):match('[^/\\]+$') or ('id ' .. texte(contexte.id))
    if self.progression then self.progression:setCaption('Photo ' .. texte(contexte.numero) .. '/' .. texte(contexte.total)
      .. ' · ' .. fichier .. ' · ' .. operation
      .. (contexte.collection and (' · collection ' .. texte(contexte.collection)) or '')) end
    -- Si APPEL manque, l'attente concerne la mise à jour de progression, pas le SDK.
    ecrire('APPEL\t' .. n .. '\t' .. operation)
    local ok, resultat = LrTasks.pcall(lire)
    ecrire((ok and 'FIN' or 'ERREUR') .. '\t' .. n .. '\t'
      .. string.format('%.3f s', LrDate.currentTime() - debut) .. '\t' .. operation
      .. (ok and (type(resultat) == 'string' and ('\tvaleur=' .. texte(resultat)) or '')
        or ('\t' .. texte(resultat))))
    if not ok then error(resultat, 0) end
    return resultat
  end
  function trace:terminer(etat) ecrire('SESSION\t' .. etat) end
  return trace
end
return M
