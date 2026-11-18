"""Séquence de recherches seules, sans modification des photos du catalogue."""
from pathlib import Path
import subprocess
import sys

driver=Path(__file__).with_name('piloter.py')
output=driver.resolve().parents[2]/'sortie'/'catalogue-compact'/'campagne'
for case in ['R01','R02','R03','R04','R05','R06','R07','R08','R09','E03']:
    if (output/('rafales-'+case+'.json')).exists(): continue
    subprocess.run([sys.executable,str(driver),'rafales-'+case,'ReduireRafales','--cas',case],check=True)
