"""Alias pour vérifier la campagne réelle complète."""
from pathlib import Path
import runpy

runpy.run_path(str(Path(__file__).with_name("bilan.py")),run_name="__main__")
