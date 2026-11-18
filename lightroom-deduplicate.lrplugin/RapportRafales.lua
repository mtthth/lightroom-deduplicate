-- Rapport construit à partir des décisions réellement proposées par la commande.
local M = {}
local function h(x)
  return (tostring(x or ''):gsub('[&<>"\']', { ['&']='&amp;', ['<']='&lt;', ['>']='&gt;', ['"']='&quot;', ["'"]='&#39;' }))
end
function M.page(source, rafales, bilan)
  local T = require('Langue').t
  local DECISIONS = { garder = T('gardé', 'kept'), retirer = T('à retirer', 'to remove'), ['protégé'] = T('protégé', 'protected') }
  local morceaux = { '<!doctype html><html lang="' .. require('Langue').code() .. '"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>' .. T('Rapport des rafales', 'Burst report') .. '</title>',
    '<style>body{font:16px system-ui;background:#f4f5f7;color:#222;max-width:1400px;margin:auto;padding:24px}h1{margin-bottom:8px}.bloc{background:white;border-radius:10px;padding:16px;margin:12px 0}.cadres{display:flex;flex-wrap:wrap;gap:12px}figure{width:200px;margin:0;background:#f5f6f8;border-radius:8px;overflow:hidden}img,.vide{width:200px;height:150px;object-fit:contain;background:#ddd}.vide{display:grid;place-items:center}figcaption{padding:10px;overflow-wrap:anywhere}small{display:block;margin-top:5px}.retirer{border:2px solid #bb413d}.garder{border:2px solid #39815a}.protege{border:2px solid #5778a0}</style>',
    '<h1>' .. T('Rapport des rafales', 'Burst report') .. '</h1><p>' .. h(source) .. ' · ' .. bilan.rafales .. T(' rafales · ', ' bursts · ') .. bilan.cadres
      .. T(' cadres · ', ' frames · ') .. bilan.retires .. T(' à retirer · ', ' to remove · ') .. bilan.proteges .. T(' protégés', ' protected') .. '</p>',
    '<p>' .. T('Ce rapport présente les décisions avant confirmation. Aucun fichier n’est supprimé par le module.',
      'This report shows the decisions before confirmation. The plug-in never deletes a file.') .. '</p>' }
  for i, rafale in ipairs(rafales) do
    morceaux[#morceaux + 1] = '<h2>' .. T('Rafale ', 'Burst ') .. i .. '</h2>'
    for j, bloc in ipairs(rafale.blocs) do
      morceaux[#morceaux + 1] = '<section class="bloc"><h3>' .. T('Bloc ', 'Block ') .. j .. '</h3><div class="cadres">'
      for _, c in ipairs(bloc) do
        local classe = c.decision == 'protégé' and 'protege' or c.decision
        local image = c.apercuRapport and '<img loading="lazy" src="' .. h(c.apercuRapport) .. '" alt="">' or '<div class="vide">' .. T('Aperçu indisponible', 'No preview') .. '</div>'
        local raison = c.decision == 'protégé' and table.concat(c.raisons, ', ') or (c.pourquoi or '')
        local fichiers = {}
        for _, f in ipairs(c.fichiers) do fichiers[#fichiers + 1] = f.chemin end
        morceaux[#morceaux + 1] = '<figure class="' .. h(classe) .. '">' .. image .. '<figcaption><strong>' .. h(c.nom) .. '</strong><small>' .. h(DECISIONS[c.decision] or c.decision) .. (c.nettete and (T(' · netteté ', ' · sharpness ') .. h(string.format('%.2f', c.nettete))) or '') .. '</small><small>' .. h(raison) .. '</small><small>' .. h(table.concat(fichiers, ' | ')) .. '</small></figcaption></figure>'
      end
      morceaux[#morceaux + 1] = '</div></section>'
    end
  end
  morceaux[#morceaux + 1] = '</html>'
  return table.concat(morceaux, '\n')
end
return M
