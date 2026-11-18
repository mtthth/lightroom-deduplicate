local LrPrefs = import 'LrPrefs'
local LrView = import 'LrView'
local Rafales = require 'Rafales'
local Doublons = require 'Doublons'

-- Relie un champ du dialogue à une préférence, avec sa valeur par défaut.
local function relier(prefs, proprietes, cle, defaut)
  proprietes[cle] = prefs[cle]
  if proprietes[cle] == nil then proprietes[cle] = defaut end
  proprietes:addObserver(cle, function(_, _, valeur) prefs[cle] = valeur or '' end)
end

return {
  sectionsForTopOfDialog = function(f, proprietes)
    local prefs = LrPrefs.prefsForPlugin()
    relier(prefs, proprietes, 'motCollectionRafales', Rafales.MOT_COLLECTION_DEFAUT)
    relier(prefs, proprietes, 'motsDossiersDesordre', Doublons.MOTS_DESORDRE_DEFAUT)
    relier(prefs, proprietes, 'motsDossiersTelecharges', Doublons.MOTS_TELECHARGES_DEFAUT)
    return { {
      title = 'Fusion des doublons',
      bind_to_object = proprietes,
      f:static_text { title = 'Pour choisir la copie gardée, un dossier dont le chemin contient l’un de ces mots passe après les dossiers nommés, datés ou d’année. Mots séparés par des virgules, majuscules indifférentes.', width = 450, height_in_lines = 3 },
      f:row {
        f:static_text { title = 'Dossiers mal rangés :', width_in_chars = 22 },
        f:edit_field { value = LrView.bind('motsDossiersDesordre'), width_in_chars = 30, immediate = true },
      },
      f:row {
        f:static_text { title = 'Téléchargements, copies :', width_in_chars = 22 },
        f:edit_field { value = LrView.bind('motsDossiersTelecharges'), width_in_chars = 30, immediate = true },
      },
      f:static_text { title = 'Par défaut : « ' .. Doublons.MOTS_DESORDRE_DEFAUT .. ' » puis « ' .. Doublons.MOTS_TELECHARGES_DEFAUT .. ' » (ces derniers passent en tout dernier). Laisser vide pour ne pas en tenir compte.', width = 450, height_in_lines = 2 },
    }, {
      title = 'Réduction des rafales',
      bind_to_object = proprietes,
      f:static_text { title = 'Les collections dont le nom ou un ensemble parent contient ce texte ne protègent pas les photos.', width = 450, height_in_lines = 2 },
      f:row {
        f:static_text { title = 'Texte à ignorer :' },
        f:edit_field { value = LrView.bind('motCollectionRafales'), width_in_chars = 25, immediate = true },
      },
      f:static_text { title = 'Par défaut : sessions. Laisser vide pour protéger toutes les collections concernées. Les autres protections restent actives.', width = 450, height_in_lines = 2 },
    } }
  end,
}
