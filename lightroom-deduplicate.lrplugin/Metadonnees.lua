-- Champ interne : contrairement aux propriétés globales du catalogue,
-- une métadonnée de photo écrite dans l'action suit Annuler et Rétablir.
return {
  schemaVersion=1,
  metadataFieldsForPhotos={
    { id='operationExclusionsV3', dataType='string', searchable=false, browsable=false, version=1 },
  },
}
