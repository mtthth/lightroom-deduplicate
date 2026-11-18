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
  LrLibraryMenuItems = {
    { title = 'Tester la vitesse du catalogue…', file = 'DiagnosticCatalogue.lua' },
    { title = 'Rechercher les doublons pour fusion…', file = 'FusionnerDoublons.lua' },
    { title = 'Fusionner de force la sélection…', file = 'FusionManuelle.lua' },
    { title = 'Restaurer les collections avant fusion ou rafales…', file = 'RestaurerCollections.lua' },
    { title = 'Réduire les rafales…', file = 'ReduireRafales.lua' },
  },
  VERSION = { major = 1, minor = 0, revision = 0 },
}
