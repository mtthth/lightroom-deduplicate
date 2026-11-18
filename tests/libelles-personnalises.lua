package.path='lightroom-deduplicate.lrplugin/?.lua;'..package.path
local f=assert(io.open('lightroom-deduplicate.lrplugin/ReduireRafales.lua','rb'))
local src=f:read('*a'); f:close()
local debut=assert(src:find('local function lireFichiers',1,true))
local fin=assert(src:find('local function historiqueARetirer',debut,true))
local lire=assert(load('return function(Parallele,Historique,TAILLE_LOT,LIBELLES_COULEUR) '
  ..src:sub(debut,fin-1)..' return lireFichiers end'))()(
  {parLots=function(lot,_,fn) return fn(lot,1,#lot)~=false end},
  {contient=function() return false end},1000,{red=true,yellow=true,green=true,blue=true,purple=true})
local photos,raw,formatted={},{},{}
for i=1,4 do
  local p={localIdentifier=i}; photos[i]=p
  raw[p]={path='C:/test/IMG_100'..i..'.jpg',dateTimeOriginal=i,fileSize=100,colorNameForLabel='white'}
  formatted[p]={label=''}
end
formatted[photos[1]].label='À vérifier 🧪'
raw[photos[2]].colorNameForLabel='gray'
raw[photos[3]].colorNameForLabel='red' -- repli si le texte n'est pas rendu
formatted[photos[4]].label='rouge'
local c={batchGetRawMetadata=function() return raw end,
  batchGetFormattedMetadata=function(_,_,keys) assert(keys[1]=='label'); return formatted end}
local p={isCanceled=function() return false end,setCaption=function() end,setPortionComplete=function() end}
local fichiers=lire(c,photos,{}, {},p)
assert(#fichiers==4)
local R=require 'Rafales'
local cadres=R.cadres(fichiers)
for _,cadre in ipairs(cadres) do R.proteger(cadre) end
local rafales=R.rafales(cadres); R.blocs(rafales,4); R.decider(rafales)
assert(cadres[1].decision=='protégé' and cadres[3].decision=='protégé' and cadres[4].decision=='protégé')
assert(not cadres[2].protege)
assert(cadres[1].raisons[1]:find('À vérifier 🧪',1,true),'le rapport indique le vrai libellé')
print('OK : libellés personnalisés et jeu de couleurs, sans protéger les photos sans libellé.')
