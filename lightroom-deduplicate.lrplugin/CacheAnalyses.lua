local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local LrTasks = import 'LrTasks'
local LrMD5 = import 'LrMD5'
local M = {}
local function hex(s) return (s:gsub('.', function(c) return string.format('%02x', c:byte()) end)) end
local function unhex(s)
  assert(#s % 2 == 0 and not s:find('[^%da-f]'), 'Cache tronqué')
  return (s:gsub('..', function(x) return string.char(tonumber(x, 16)) end))
end
local function citer(p)
  assert(not p:find('["%%!&|<>^\r\n]'), 'Chemin de commande incompatible')
  for i = 1, #p do assert(p:byte(i) < 128, 'Chemin temporaire non ASCII') end
  return '"' .. p .. '"'
end
local function encode(kind, valeur)
  if kind ~= 'S' then return valeur end
  return string.format('%d,%d:', valeur.largeur, valeur.hauteur) .. valeur.signature
end
local function decode(kind, valeur)
  if not valeur then return nil end
  if kind ~= 'S' then
    if kind == 'G' then return valeur:match('^complet:%x+$') and valeur or nil end
    return (valeur:match('^jpeg:%x+$') or valeur:match('^brut:%x+$') or valeur:match('^mdat:%x+$')
      or valeur:match('^gros:%d+:%x+$')) and valeur or nil
  end
  local w, h, rgb = valeur:match('^(%d+),(%d+):(.*)$')
  if not w or tonumber(w) <= 0 or tonumber(h) <= 0 or #rgb ~= 768 then return nil end
  return { largeur = tonumber(w), hauteur = tonumber(h), signature = rgb }
end

function M.ouvrir(dossier, magick, diagnostic)
  local self = { donnees = {}, sales = {}, stats = {}, desactive = false }
  local function journal(nom, valeurs) if diagnostic then diagnostic:compteurs(nom, valeurs) end end
  local function commande(mode, kind, lignes)
    local base = LrPathUtils.child(LrPathUtils.getStandardFilePath('temp'),
      'lrdedup-cache-' .. LrMD5.digest(tostring({}) .. os.time()))
    local script, requete, sortie = base .. '.py', base .. '.txt', base .. '.out'
    local ok, result = LrTasks.pcall(function()
      local exe = assert(require('Python').chemin(), 'Python introuvable')
      LrFileUtils.copy(LrPathUtils.child(_PLUGIN.path, 'cache_analyses.py'), script)
      local f = assert(io.open(requete, 'wb'))
      local contenu = { 'LRCACHE1', mode .. '\t' .. kind, hex(LrPathUtils.child(dossier, 'cache-analyses.sqlite3')),
        hex(_PLUGIN.path), hex(magick or '') }
      for _, ligne in ipairs(lignes) do contenu[#contenu + 1] = ligne end
      contenu[#contenu + 1] = 'END'
      local ecrit = f:write(table.concat(contenu, '\n') .. '\n'); f:close(); assert(ecrit, 'Requête cache non écrite')
      local code = LrTasks.execute(exe .. ' ' .. citer(script) .. ' ' .. citer(requete) .. ' ' .. citer(sortie))
      local texte = LrFileUtils.readFile(sortie)
      assert(texte, 'Cache sans réponse')
      texte = texte:gsub('\r\n', '\n')
      local erreur = texte:match('^ERROR\t([%da-f]*)')
      assert(code == 0 and not erreur, erreur and unhex(erreur) or 'Lecture du cache impossible')
      assert(texte:match('^LRCACHE1\n'), 'Format cache inconnu')
      return texte
    end)
    for _, p in ipairs({ script, requete, sortie }) do LrTasks.pcall(function()
      if LrFileUtils.exists(p) then LrFileUtils.delete(p) end
    end) end
    if not ok then self.desactive = true; journal('cache_erreur', { mode = mode, type = kind, message = tostring(result) }); return nil end
    return result
  end
  function self:charger(kind, chemins)
    self.donnees[kind] = self.donnees[kind] or {}
    self.sales[kind] = self.sales[kind] or {}
    self.stats[kind] = self.stats[kind] or { reutilises = 0, calcules = 0 }
    if self.desactive then return end
    local lignes, attendus = {}, {}
    for _, path in ipairs(chemins) do
      if not attendus[path] then attendus[path] = true; lignes[#lignes + 1] = hex(path) end
    end
    if #lignes == 0 then return end
    local texte = commande('LOAD', kind, lignes)
    if not texte then return end
    local chargees, nb = {}, 0
    local ok, erreur = LrTasks.pcall(function()
      for pathHex, stampHex, payloadHex in texte:gmatch('\nR\t([%da-f]+)\t([%da-f%-]+)\t([%da-f%-]+)') do
        local path = unhex(pathHex)
        assert(attendus[path] and not chargees[path], 'Photo inattendue dans le cache')
        chargees[path] = { stamp = stampHex ~= '-' and unhex(stampHex) or nil,
          valeur = payloadHex ~= '-' and decode(kind, unhex(payloadHex)) or nil }
        nb = nb + 1
      end
      local fin = tonumber(texte:match('\nEND\t(%d+)\t%d+\t%d+\t%d+\n$'))
      assert(fin == #lignes and nb == #lignes, 'Cache incomplet')
    end)
    if not ok then self.desactive = true; journal('cache_erreur', { type = kind, message = tostring(erreur) }); return end
    for path, valeur in pairs(chargees) do self.donnees[kind][path] = valeur end
  end
  function self:obtenir(kind, path)
    local entree = not self.desactive and self.donnees[kind] and self.donnees[kind][path]
    if entree and entree.valeur then
      self.stats[kind].reutilises = self.stats[kind].reutilises + 1
      return entree.valeur
    end
    return nil
  end
  function self:retenir(kind, path, valeur)
    if not valeur then return end -- Ne jamais cacher un échec ou une absence de fichier.
    self.stats[kind] = self.stats[kind] or { reutilises = 0, calcules = 0 }
    self.stats[kind].calcules = self.stats[kind].calcules + 1
    local entree = self.donnees[kind] and self.donnees[kind][path]
    if not self.desactive and entree and entree.stamp then
      entree.valeur = valeur
      self.sales[kind][path] = true
    end
  end
  function self:enregistrer()
    if not self.desactive then
      for kind, chemins in pairs(self.sales) do
        local lignes = {}
        for path in pairs(chemins) do
          local e = self.donnees[kind][path]
          if e.stamp and e.valeur then lignes[#lignes + 1] = hex(path) .. '\t' .. hex(e.stamp) .. '\t' .. hex(encode(kind, e.valeur)) end
        end
        if #lignes > 0 then
          local texte = commande('SAVE', kind, lignes)
          if texte then
            local _, _, ecrits, modifies = texte:match('\nEND\t(%d+)\t(%d+)\t(%d+)\t(%d+)\n$')
            journal('cache_ecriture', { type = kind, ecrits = ecrits, modifies_pendant_lecture = modifies })
          end
        end
        self.sales[kind] = {}
      end
    end
    for kind, compteurs in pairs(self.stats) do journal('cache_' .. kind, compteurs) end
  end
  return self
end
return M
