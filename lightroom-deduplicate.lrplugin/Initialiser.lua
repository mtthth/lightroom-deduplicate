-- Signature des fichiers au chargement, comparée au début de chaque commande (Fraicheur.lua).
require 'Fraicheur'
-- Réglages de l'ancien identifiant du module (voir Migration.lua), puis synchronisation de l'historique.
require('Migration').reprendrePreferences(import('LrPrefs').prefsForPlugin)
require('Annulation').demarrer(require('HistoriqueCommun').chemins())
