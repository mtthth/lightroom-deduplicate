package.path = 'lightroom-deduplicate.lrplugin/?.lua;' .. package.path
local D, R = require 'Doublons', require 'Rafales'
local lieux, personnes = { localIdentifier=10 }, { localIdentifier=11 }
local effets=D.effets { garde={motsCles={{nom='Paris',objet=lieux}}}, retirees={
  {motsCles={{nom='Paris',objet={localIdentifier=10}},{nom='Paris',objet=personnes}}},
  {motsCles={{nom='Paris',objet={localIdentifier=11}}}} } }
assert(#effets.motsCles==1 and effets.motsCles[1].objet==personnes)

local fichiers={}
for n=1,8 do
  for _,d in ipairs({'A','B'}) do
    fichiers[#fichiers+1]={chemin=string.format('C:/%s/IMG_%04d.jpg',d,1000+n),t=math.floor(n/2)}
  end
end
local rafales=R.rafales(R.cadres(fichiers))
assert(#rafales==2 and #rafales[1]==8 and #rafales[2]==8)
for _,r in ipairs(rafales) do
  local dossier=r[1].dossier
  for _,c in ipairs(r) do assert(c.dossier==dossier) end
end
-- Les séparateurs/casses Windows ne coupent pas une même séquence.
local memes=R.rafales(R.cadres({{chemin='C:/A/IMG_1001.jpg',t=1},
  {chemin='c:\\a\\IMG_1002.jpg',t=2},{chemin='C:/A/IMG_1003.jpg',t=3}}))
assert(#memes==1 and #memes[1]==3)

local a={id=1,chemin='C:/IMG_1.jpg',empreinte='original',pixels=600000,
  preuveComparaison={signature=string.rep(string.char(100),768),largeur=960,hauteur=640}}
local b={id=2,chemin='C:/IMG_1-2.jpg',empreinte='detail',pixels=600000,
  preuveComparaison={signature=string.char(101)..string.rep(string.char(100),767),largeur=960,hauteur=640}}
local d=D.decider({a,b}); assert(d.aVerifier and not d.memeImage)
b.empreinte=a.empreinte; assert(not D.decider({a,b}).aVerifier)
-- Une copie déjà écartée (historique partagé) reste comparée mais n'est jamais gardée.
local rangee={id=5,chemin='D:/Archives/2005/051224. Fête 2005/CIMG0640.JPG',empreinte='m',pixels=786432,octets=200}
local ecartee={id=4,chemin='D:/Archives/Fête/CIMG0640.JPG',empreinte='m',pixels=786432,octets=200,dejaEcartee=true}
d=D.decider({ecartee,rangee})
assert(d.garde==rangee and d.retirees[1]==ecartee and not d.aVerifier, 'même image : la copie non écartée est gardée')
assert(d.pourquoi=='les autres copies avaient déjà été écartées')
local grande={id=6,chemin='D:/Archives/Fête/CIMG0640.JPG',empreinte='g',pixels=3000000,octets=900,dejaEcartee=true,
  preuveComparaison={signature=string.rep(string.char(100),768),largeur=2048,hauteur=1536}}
local petite={id=7,chemin='D:/Archives/2005/CIMG0640.JPG',empreinte='p',pixels=786432,octets=200,
  preuveComparaison={signature=string.rep(string.char(100),768),largeur=1024,hauteur=768}}
d=D.decider({grande,petite})
assert(d.garde==petite and d.aVerifier:find('déjà écartée',1,true), 'meilleure image écartée : à vérifier')
-- Groupe déjà fusionné : rien à reproposer. Écartée encore dans une collection ordinaire : à refaire.
local corbeille={id=90,nom='Doublons à retirer',exclue=true}
rangee.collections={{id=91,nom='TIME 2005'}}
ecartee.collections={corbeille}
d=D.decider({ecartee,rangee}); assert(D.dejaFusionne(d), 'déjà rangée dans la corbeille, rien à transférer')
ecartee.collections={corbeille,{id=92,nom='Fête'}}
d=D.decider({ecartee,rangee}); assert(not D.dejaFusionne(d), 'encore dans une collection : à refusionner')
ecartee.collections={{id=91,nom='TIME 2005'}}
d=D.decider({ecartee,rangee}); assert(not D.dejaFusionne(d), 'hors corbeille : à remettre dans « Doublons à retirer »')
ecartee.collections={corbeille}; ecartee.note=3
d=D.decider({ecartee,rangee}); assert(not D.dejaFusionne(d), 'note à transférer')
ecartee.note=nil; ecartee.dejaEcartee=nil
d=D.decider({ecartee,rangee}); assert(not D.dejaFusionne(d), 'copie hors historique : jamais considérée fusionnée')
-- Copie renommée et redatée, rapprochée par ses dimensions : toujours à vérifier, motif explicite.
local exportee={id=8,chemin='D:/Archives/albums-manquantes/img20211101_20185594.jpg',empreinte='q78',
  pixels=599090,octets=74510,preuveComparaison={signature=string.rep(string.char(100),768),largeur=862,hauteur=695}}
local originale={id=9,chemin='D:/Archives/Scans/PPD-001.jpg',empreinte='q95',
  pixels=599090,octets=183680,preuveComparaison={signature=string.rep(string.char(100),768),largeur=862,hauteur=695}}
d=D.decider({exportee,originale})
assert(d.garde==originale and d.aVerifier:find('noms différents',1,true), 'rapprochement par dimensions à vérifier')

-- regrouper avec fenêtre de moyennes = comparaison complète d'origine.
local Sm=require 'Similitude'
local function complet(classes)
  local restantes={}
  for i,c in ipairs(classes) do restantes[i]=c end
  table.sort(restantes,function(a,b)
    if (a.pixels or 0)~=(b.pixels or 0) then return (a.pixels or 0)>(b.pixels or 0) end
    return (a.octets or 0)>(b.octets or 0)
  end)
  local groupes={}
  while #restantes>0 do
    local m=table.remove(restantes,1); local g,autres={m},{}
    for _,c in ipairs(restantes) do if Sm.memeVue(m,c) then g[#g+1]=c else autres[#autres+1]=c end end
    restantes=autres; groupes[#groupes+1]=g
  end
  return groupes
end
math.randomseed(7)
for essai=1,30 do
  local classes={}
  for i=1,60 do
    local base=math.random(0,12)*3   -- quelques vues, chacune déclinée en copies proches ou non
    local bruit=math.random(0,3)
    local t={}
    for k=1,768 do t[k]=string.char(math.max(0,math.min(255,100+base+((k*7+i)%(bruit+1))))) end
    classes[i]={id=i,pixels=math.random(1,3)*1000,octets=math.random(1,5000),largeur=4,hauteur=3,
      signature=(i%11==0) and nil or table.concat(t)}
  end
  local a,b=Sm.regrouper(classes),complet(classes)
  assert(#a==#b,'même nombre de groupes')
  for g=1,#a do
    assert(#a[g]==#b[g])
    for k=1,#a[g] do assert(a[g][k]==b[g][k],'même composition et même ordre') end
  end
end
-- Copies tournées (Picasa…) : même photo, quelle que soit la rotation, et le choix revient à l'utilisateur.
local motif={}
for y=0,15 do for x=0,15 do
  local v=(x<4 and y<8) and 250 or (x*13+y*3)%120   -- motif sans symétrie
  motif[#motif+1]=string.char(v,v,v)
end end
motif=table.concat(motif)
local quart=Sm.tourner(motif)
assert(quart~=motif and Sm.tourner(Sm.tourner(Sm.tourner(quart)))==motif, 'quatre quarts de tour = identité')
local couchee={signature=motif,largeur=3264,hauteur=2176}
local debout={signature=quart,largeur=2176,hauteur=3264}
assert(Sm.rotation(debout,couchee)==90 and Sm.rotation(couchee,debout)==270)
assert(Sm.rotation(couchee,{signature=Sm.tourner(quart),largeur=3264,hauteur=2176})==180)
assert(not Sm.memeVue(couchee,{signature=quart,largeur=3264,hauteur=2176}), 'quart de tour sans changement de forme : refusé')
assert(not Sm.memeVue(couchee,{signature=quart,largeur=3000,hauteur=3264}), 'forme incompatible')
-- Versions conservées à part : seules celles qui gardent le cadrage sont proposées dans le rapport.
local eclaircie=motif:gsub('.',function(c) return string.char(math.min(255,c:byte()+40)) end)
local recadree={}
for y=0,15 do for x=0,15 do
  local v=((x+5)*7+(y+9)*11)%200   -- autre cadrage : aucune structure commune
  recadree[#recadree+1]=string.char(v,v,v)
end end
recadree=table.concat(recadree)
assert(Sm.memeCadrage(couchee,{signature=eclaircie}), 'exposition retouchée : même cadrage')
assert(Sm.memeCadrage(couchee,{signature=Sm.tourner(eclaircie)}), 'version tournée : même cadrage')
assert(not Sm.memeCadrage(couchee,{signature=recadree}), 'autre cadrage : écarté')
assert(Sm.memeCadrage(couchee,{}), 'sans miniature : gardée')
assert(Sm.memeCadrage(couchee,{signature=string.rep(string.char(90),768)}), 'miniature unie : gardée')
local orig={id=10,chemin='D:/2006/061224. Week-end en famille/Originals/R0011056.JPG',empreinte='o',pixels=7102464,octets=2543100,
  preuveComparaison=couchee}
local picasa={id=11,chemin='D:/2006/061224. Week-end en famille/R0011056.JPG',empreinte='p',pixels=7102464,octets=2541600,
  preuveComparaison=debout}
d=D.decider({orig,picasa})
assert(#d.retirees==1 and d.aVerifier:find('orientations différentes',1,true), 'copie tournée : à vérifier')
-- Version « _filtered » de même vue : proposée, à vérifier, jamais fusionnée par défaut.
local vue={signature=motif,largeur=4000,hauteur=3000}
local brute={id=12,chemin='D:/2021/IMG_2000.jpg',empreinte='b',pixels=12000000,octets=3000000,preuveComparaison=vue}
local filtree={id=13,chemin='D:/2021/IMG_2000_filtered.jpg',empreinte='f',pixels=12000000,octets=3400000,preuveComparaison=vue}
d=D.decider({brute,filtree})
assert(#d.retirees==1 and d.aVerifier and d.aVerifier:find('version retouchée d’après son nom',1,true), '_filtered : à vérifier')
local modifiee={id=14,chemin='D:/2021/IMG_2000-Modifier.jpg',empreinte='b',pixels=12000000,octets=3000000}
d=D.decider({brute,modifiee})
assert(d.aVerifier==nil, 'nom de retouche mais empreinte identique : doublon ordinaire')
-- Mots des dossiers mal rangés et des téléchargements : valeurs par défaut, puis réglages.
assert(D.rangDossier('D:/Photos/Désordre/IMG_1.jpg')==4 and D.rangDossier('D:/Photos/albums-manquantes/IMG_1.jpg')==5)
assert(D.rangDossier('D:/Photos/A trier/IMG_1.jpg')==1)
D.reglerDossiers({motsDossiersDesordre=' A trier ; Inbox ',motsDossiersTelecharges='WhatsApp'})
assert(D.rangDossier('D:/Photos/A TRIER/IMG_1.jpg')==4 and D.rangDossier('D:/Photos/inbox/IMG_1.jpg')==4)
assert(D.rangDossier('D:/Photos/WhatsApp Images/IMG_1.jpg')==5 and D.rangDossier('D:/Photos/Désordre/IMG_1.jpg')==1)
D.reglerDossiers({motsDossiersDesordre='',motsDossiersTelecharges=''})
assert(D.rangDossier('D:/Photos/albums-manquantes/IMG_1.jpg')==1, 'listes vides : aucun mot pris en compte')
D.reglerDossiers(nil)
assert(D.rangDossier('D:/Photos/albums-manquantes/IMG_1.jpg')==5, 'retour aux valeurs par défaut')
-- À qualité égale, la copie qui a une date de prise de vue est gardée, même dans un dossier moins bien rangé.
local sansDate={id=30,chemin='D:/Archives/Vidéos/bef9a313.mp4',empreinte='v',pixels=0,octets=8000000,video=true,retouchee=true}
local datee={id=31,chemin='D:/Archives/Vidéos/2021/VIDR-2021-08-27bef9a313.mp4',empreinte='v',pixels=0,octets=8000000,video=true,
  retouchee=true,date=651700800}
d=D.decider({sansDate,datee})
assert(d.garde.id==31 and d.pourquoi=='a une date de prise de vue', d.pourquoi)
d=D.decider({datee,sansDate})
assert(d.garde.id==31, 'ordre des copies indifférent')
local grandeSansDate={id=32,chemin='D:/Archives/x.jpg',empreinte='g',pixels=2000,octets=10}
local petiteDatee={id=33,chemin='D:/Archives/2021/x.jpg',empreinte='p',pixels=1000,octets=10,date=651700800}
assert(D.decider({petiteDatee,grandeSansDate}).garde.id==32, 'la qualité passe avant la date')
-- Copies renommées par Google Photos ou un export : séparateurs changés, nom doublé.
assert(D.cleNom('D:/Noel/20171228_192040_p1070693.jpg') == D.cleNom('D:/manquantes/20171228-192040-p1070693.jpg'))
assert(D.cleNom('a/20180609_203338_20180609_203338.jpg') == D.cleNom('b/20180609_203338.jpg'))
assert(D.cleNom('a/20180609-203338-20180609_203338.jpg') == D.cleNom('b/20180609_203338-2.jpg'))
assert(D.cleNom('a/P1250640.JPG') ~= D.cleNom('a/P1250641.JPG'))
assert(D.cleNom('a/IMG_6527-2.JPG') == 'img6527')
print('OK : mots-clés homonymes distincts, rafales intercalées séparées, variantes seulement proposées, copies déjà écartées, rapprochements par dimensions, copies tournées, versions au nom de retouche proposées.')


