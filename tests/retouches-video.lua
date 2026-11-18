package.path='lightroom-deduplicate.lrplugin/?.lua;'..package.path
local V,D=require 'RetouchesVideo',require 'Doublons'
local fixture=dofile('tests/video-vierge-lr15.lua')
local function copie(t)
  if type(t)~='table' then return t end
  local r={}; for k,v in pairs(t) do r[k]=copie(v) end; return r
end
local neutre,meta=fixture.develop,fixture.metadata
assert(V.etat(neutre,meta)==false)
-- Chaque contrôle rendu par le vrai SDK est testé, y compris les valeurs
-- neutres non nulles, courbes et tables. La version seule n'est pas une retouche.
for _,profil in ipairs({neutre,fixture.materialisee}) do
 assert(V.etat(profil,meta)==false)
 for cle,valeur in pairs(profil) do
  if cle~='ProcessVersion' then
    local r=copie(profil)
    if type(valeur)=='number' then r[cle]=valeur+1
    elseif type(valeur)=='boolean' then r[cle]=not valeur
    elseif type(valeur)=='string' then r[cle]='autre'
    elseif cle=='TrimStart' then r[cle]={numerator=1,denominator=4}
    elseif cle=='TrimEnd' then r[cle]={numerator=3,denominator=4}
    else r[cle].modification=true end
    assert(V.etat(r,meta)==true,cle..' doit protéger la vidéo')
  end
 end
end
local r=copie(neutre); r.TrimEnd={numerator=12,denominator=12}
assert(V.etat(r,meta)==false,'fractions équivalentes')
r.TrimEnd.denominator=0; assert(V.etat(r,meta)==nil)
r=copie(neutre); r.NouveauReglageVideo=0; assert(V.etat(r,meta)==nil)
r=copie(neutre); r.Saturation=nil; assert(V.etat(r,meta)==nil)
assert(V.etat(nil,meta)==nil and V.etat({},meta)==nil and V.etat(neutre,{})==nil)
assert(V.etat(neutre,{durationInSeconds=1,trimmedDurationInSeconds=0.75})==true)
assert(V.etat(neutre,{durationInSeconds=math.huge,trimmedDurationInSeconds=1})==nil)
local a={id=1,chemin='C:/A.mp4',empreinte='identique',video=true,retouchee=false}
local b={id=2,chemin='C:/A-2.mp4',empreinte='identique',video=true,retouchee=false}
assert(not D.decider({a,b}).aVerifier)
b.retouchee=true
local d=D.decider({a,b}); assert(d.garde==b and not d.aVerifier,'garder la seule copie retouchée')
a.retouchee=true; assert(D.decider({a,b}).aVerifier)
a.retouchee=false; b.erreurReglagesVideo='lecture impossible'
assert(D.decider({a,b}).aVerifier:find('impossible de vérifier',1,true))
print('OK : profil vidéo réel vierge, coupes et corrections protégées, lecture inconnue bloquée, choix de la copie retouchée.')
