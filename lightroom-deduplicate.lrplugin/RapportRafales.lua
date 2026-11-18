-- Rapport construit à partir des décisions réellement proposées par la commande.
local M = {}
local function h(x)
  return (tostring(x or ''):gsub('[&<>"\']', { ['&']='&amp;', ['<']='&lt;', ['>']='&gt;', ['"']='&quot;', ["'"]='&#39;' }))
end
function M.page(source, rafales, bilan)
  local morceaux = { '<!doctype html><html lang="fr"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Rapport des rafales</title>',
    '<style>body{font:16px system-ui;background:#f4f5f7;color:#222;max-width:1400px;margin:auto;padding:24px}h1{margin-bottom:8px}.bloc{background:white;border-radius:10px;padding:16px;margin:12px 0}.cadres{display:flex;flex-wrap:wrap;gap:12px}figure{width:200px;margin:0;background:#f5f6f8;border-radius:8px;overflow:hidden}img,.vide{width:200px;height:150px;object-fit:contain;background:#ddd}.vide{display:grid;place-items:center}figcaption{padding:10px;overflow-wrap:anywhere}small{display:block;margin-top:5px}.retirer{border:2px solid #bb413d}.garder{border:2px solid #39815a}.protege{border:2px solid #5778a0}</style>',
    '<h1>Rapport des rafales</h1><p>' .. h(source) .. ' · ' .. bilan.rafales .. ' rafales · ' .. bilan.cadres .. ' cadres · ' .. bilan.retires .. ' à retirer · ' .. bilan.proteges .. ' protégés</p>',
    '<p>Ce rapport présente les décisions avant confirmation. Aucun fichier n’est supprimé par le module.</p>' }
  for i, rafale in ipairs(rafales) do
    morceaux[#morceaux + 1] = '<h2>Rafale ' .. i .. '</h2>'
    for j, bloc in ipairs(rafale.blocs) do
      morceaux[#morceaux + 1] = '<section class="bloc"><h3>Bloc ' .. j .. '</h3><div class="cadres">'
      for _, c in ipairs(bloc) do
        local classe = c.decision == 'protégé' and 'protege' or c.decision
        local image = c.apercuRapport and '<img loading="lazy" src="' .. h(c.apercuRapport) .. '" alt="">' or '<div class="vide">Aperçu indisponible</div>'
        local raison = c.decision == 'protégé' and table.concat(c.raisons, ', ') or (c.pourquoi or '')
        local fichiers = {}
        for _, f in ipairs(c.fichiers) do fichiers[#fichiers + 1] = f.chemin end
        morceaux[#morceaux + 1] = '<figure class="' .. h(classe) .. '">' .. image .. '<figcaption><strong>' .. h(c.nom) .. '</strong><small>' .. h(c.decision) .. (c.nettete and (' · netteté ' .. h(string.format('%.2f', c.nettete))) or '') .. '</small><small>' .. h(raison) .. '</small><small>' .. h(table.concat(fichiers, ' | ')) .. '</small></figcaption></figure>'
      end
      morceaux[#morceaux + 1] = '</div></section>'
    end
  end
  morceaux[#morceaux + 1] = '</html>'
  return table.concat(morceaux, '\n')
end
return M
