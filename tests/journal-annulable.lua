package.path='lightroom-deduplicate.lrplugin/?.lua;'..package.path
_PLUGIN={}
local J=require 'JournalAnnulable'
local props,photos={},{}
local c={}
function c:getPropertyForPlugin(_,k) return props[k] end
function c:setPropertyForPlugin(_,k,v) props[k]=v end
function c:findPhotoByPath(path) return photos[path] end
local function photo(id,path)
  local p={localIdentifier=id}
  function p:getRawMetadata() return path end
  function p:getPropertyForPlugin() return self.token end
  function p:setPropertyForPlugin(_,_,v) self.token=v end
  photos[path]=p; return p
end
local a,b=photo(1,'C:/é/A.jpg'),photo(2,'C:/B.jpg')
J.ajouter(c,'base\n','un\n',a); assert(J.lire(c)=='base\nun\n')
J.memoriser(c)
J.ajouter(c,J.lire(c),'deux\n',b); assert(J.lire(c)=='base\nun\ndeux\n')
J.memoriser(c)
-- Undo ne modifie jamais props, comme dans Lightroom ; seuls les témoins changent.
b.token=nil; assert(J.lire(c)=='base\nun\n')
a.token=nil; assert(J.lire(c)=='base\n')
a.token='1'; b.token='2'; assert(J.lire(c)=='base\nun\ndeux\n')
-- Nouvelle branche sur une autre photo, après Undo.
b.token=nil
J.ajouter(c,J.lire(c),'branche\n',a)
assert(J.lire(c)=='base\nun\nbranche\n')
a.token='1'; assert(J.lire(c)=='base\nun\n')
a.token='3'; J.memoriser(c)
-- Retirer un original ensuite ne supprime pas son exclusion. Un autre original
-- réimporté au même chemin ne doit pas servir de témoin pour l'ancien identifiant.
photos['C:/é/A.jpg']=nil; assert(J.lire(c)=='base\nun\nbranche\n')
photo(99,'C:/é/A.jpg'); assert(J.lire(c)=='base\nun\nbranche\n')
photos['C:/é/A.jpg']=a
package.loaded.JournalAnnulable=nil; J=require 'JournalAnnulable'
assert(J.lire(c)=='base\nun\nbranche\n')
-- Undo après rechargement suit toujours la branche de la métadonnée.
a.token='1'; assert(J.lire(c)=='base\nun\n')
local avant=props.registreExclusionsV3
J.ajouter(c,J.lire(c),'',a); assert(props.registreExclusionsV3==avant)
props.registreExclusionsV3=avant:sub(1,-2)
assert(not pcall(J.lire,c),'un registre tronqué doit interrompre la synchronisation')
print('OK : témoins de photos annulables, propriétés de catalogue persistantes, branches, retrait/réimport et rechargement.')
