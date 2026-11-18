package.path = 'lightroom-deduplicate.lrplugin/?.lua;' .. package.path
local commandes = {}
function import(nom)
  if nom == 'LrTasks' then return { pcall = pcall, execute = function(cmd) commandes[#commandes + 1] = cmd end } end
  if nom == 'LrMD5' then return { digest = function() return 'session-test' end } end
  if nom == 'LrPathUtils' then return { child = function(a,b) return a .. '/' .. b end,
    getStandardFilePath = function() return 'C:/Temp' end } end
  if nom == 'LrFileUtils' then return {
    directoryEntries = function() local fait = false; return function()
      if not fait then fait = true; return 'C:/Program Files/ImageMagick-test' end
    end end,
    exists = function() return 'file' end, delete = function() end,
    readFile = function(p) if p:match('%.rvb$') then return string.rep('\0', 768) end; return '640 480 TopLeft' end,
  } end
  error(nom)
end
local V = require 'Vignettes'
assert(V.signature('C:/Photos/test.JPG').largeur == 640)
assert(commandes[1]:find('identify -ping -format', 1, true))
assert(V.signature('C:/Photos/test.png').hauteur == 480)
assert(not commandes[2]:find('-ping', 1, true))
-- Deux tâches à la fois, getStandardFilePath rendant la main (comme le SDK) : chacune garde ses propres
-- fichiers temporaires (sinon une image recevrait la miniature d'une autre).
local cede = false
package.loaded['Vignettes'] = nil
local importOriginal = import
function import(nom)
  local m = importOriginal(nom)
  if nom == 'LrPathUtils' then
    return { child = m.child, getStandardFilePath = function()
      if cede then coroutine.yield() end
      return m.getStandardFilePath()
    end }
  end
  return m
end
V = require 'Vignettes'
V.magick()
cede, commandes = true, {}
local t1 = coroutine.create(function() return V.signature('C:/Photos/a.JPG') end)
local t2 = coroutine.create(function() return V.signature('C:/Photos/b.JPG') end)
coroutine.resume(t1); coroutine.resume(t2); coroutine.resume(t1); coroutine.resume(t2)
assert(#commandes == 2)
local f1, f2 = commandes[1]:match('rgb:"([^"]+)"'), commandes[2]:match('rgb:"([^"]+)"')
assert(f1 and f2 and f1 ~= f2, 'fichiers temporaires distincts')
assert(loadfile('lightroom-deduplicate.lrplugin/Vignettes.lua'))
print('OK : en-tête rapide pour JPEG, décodage des autres formats inchangé, signature RVB valide.')
