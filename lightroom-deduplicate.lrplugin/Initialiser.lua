-- Réglages de l'ancien identifiant du module (voir Migration.lua), puis synchronisation de l'historique.
require('Migration').reprendrePreferences(import('LrPrefs').prefsForPlugin)
require('Annulation').demarrer(require('HistoriqueCommun').chemins())
