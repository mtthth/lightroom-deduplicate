local LrPrefs = import 'LrPrefs'
local LrView = import 'LrView'
local Rafales = require 'Rafales'
local Doublons = require 'Doublons'
local Langue = require 'Langue'
local T = Langue.t

-- Relie un champ du dialogue à une préférence, avec sa valeur par défaut.
local function relier(prefs, proprietes, cle, defaut)
  proprietes[cle] = prefs[cle]
  if proprietes[cle] == nil then proprietes[cle] = defaut end
  proprietes:addObserver(cle, function(_, _, valeur) prefs[cle] = valeur or '' end)
end

return {
  sectionsForTopOfDialog = function(f, proprietes)
    local prefs = LrPrefs.prefsForPlugin()
    relier(prefs, proprietes, 'langue', 'fr')
    relier(prefs, proprietes, 'motCollectionRafales', Rafales.MOT_COLLECTION_DEFAUT)
    relier(prefs, proprietes, 'motsDossiersDesordre', Doublons.MOTS_DESORDRE_DEFAUT)
    relier(prefs, proprietes, 'motsDossiersTelecharges', Doublons.MOTS_TELECHARGES_DEFAUT)
    local langues = {}
    for i, l in ipairs(Langue.LANGUES) do langues[i] = { title = l.nom, value = l.code } end
    return { {
      title = T('Langue', 'Language'),
      bind_to_object = proprietes,
      f:row {
        f:static_text { title = T('Langue de l’interface :', 'Interface language:'), width_in_chars = 22 },
        f:popup_menu { items = langues, value = LrView.bind('langue') },
      },
      f:static_text { title = T('Vaut pour les dialogues et les rapports dès la commande suivante. Les titres du menu suivent la langue de Lightroom. Les noms des collections et du mot-clé créés par le module ne changent pas.',
        'Applies to dialogs and reports from the next command on. Menu titles follow Lightroom’s language. The names of the collections and keyword created by the plug-in do not change.'),
        width = 450, height_in_lines = 3 },
    }, {
      title = T('Fusion des doublons', 'Merging duplicates'),
      bind_to_object = proprietes,
      f:static_text { title = T('Pour choisir la copie gardée, un dossier dont le chemin contient l’un de ces mots passe après les dossiers nommés, datés ou d’année. Mots séparés par des virgules, majuscules indifférentes.',
        'When choosing the copy to keep, a folder whose path contains one of these words comes after named, dated or year folders. Comma-separated words, case-insensitive.'),
        width = 450, height_in_lines = 3 },
      f:row {
        f:static_text { title = T('Dossiers mal rangés :', 'Messy folders:'), width_in_chars = 22 },
        f:edit_field { value = LrView.bind('motsDossiersDesordre'), width_in_chars = 30, immediate = true },
      },
      f:row {
        f:static_text { title = T('Téléchargements, copies :', 'Downloads, copies:'), width_in_chars = 22 },
        f:edit_field { value = LrView.bind('motsDossiersTelecharges'), width_in_chars = 30, immediate = true },
      },
      f:static_text { title = T('Par défaut : « ' .. Doublons.MOTS_DESORDRE_DEFAUT .. ' » puis « ' .. Doublons.MOTS_TELECHARGES_DEFAUT .. ' » (ces derniers passent en tout dernier). Laisser vide pour ne pas en tenir compte.',
        'Default: “' .. Doublons.MOTS_DESORDRE_DEFAUT .. '” then “' .. Doublons.MOTS_TELECHARGES_DEFAUT .. '” (the latter come last of all). Leave empty to ignore them.'),
        width = 450, height_in_lines = 2 },
    }, {
      title = T('Réduction des rafales', 'Burst reduction'),
      bind_to_object = proprietes,
      f:static_text { title = T('Les collections dont le nom ou un ensemble parent contient ce texte ne protègent pas les photos.',
        'Collections whose name or parent set contains this text do not protect photos.'), width = 450, height_in_lines = 2 },
      f:row {
        f:static_text { title = T('Texte à ignorer :', 'Text to ignore:') },
        f:edit_field { value = LrView.bind('motCollectionRafales'), width_in_chars = 25, immediate = true },
      },
      f:static_text { title = T('Par défaut : sessions. Laisser vide pour protéger toutes les collections concernées. Les autres protections restent actives.',
        'Default: sessions. Leave empty to protect all such collections. The other protections stay active.'), width = 450, height_in_lines = 2 },
    } }
  end,
}
