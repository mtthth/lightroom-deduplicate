-- Module Lightroom Classic pour fusionner les doublons et réduire les rafales.

return {
  LrSdkVersion = 10.0,
  LrSdkMinimumVersion = 6.0,
  LrToolkitIdentifier = 'io.github.mtthth.deduplicate',
  LrPluginName = 'Deduplicate',
  LrMetadataProvider = 'Metadonnees.lua',
  LrPluginInfoProvider = 'Reglages.lua',
  LrInitPlugin = 'Initialiser.lua',
  LrEnablePlugin = 'Initialiser.lua',
  LrShutdownPlugin = 'Arreter.lua',
  LrDisablePlugin = 'Arreter.lua',
  -- Les titres du menu suivent la langue de Lightroom (TranslatedStrings_en.txt), pas le réglage du module :
  -- Lightroom les lit avant que le module puisse consulter ses préférences.
  LrLibraryMenuItems = {
    { title = LOC '$$$/Deduplicate/Menu/Diagnostic=Tester la vitesse du catalogue…', file = 'DiagnosticCatalogue.lua' },
    { title = LOC '$$$/Deduplicate/Menu/Doublons=Rechercher les doublons pour fusion…', file = 'FusionnerDoublons.lua' },
    { title = LOC '$$$/Deduplicate/Menu/Manuelle=Fusionner de force la sélection…', file = 'FusionManuelle.lua' },
    { title = LOC '$$$/Deduplicate/Menu/Restaurer=Restaurer les collections avant fusion ou rafales…', file = 'RestaurerCollections.lua' },
    { title = LOC '$$$/Deduplicate/Menu/Rafales=Réduire les rafales…', file = 'ReduireRafales.lua' },
  },
  VERSION = { major = 1, minor = 1, revision = 4 },
}
