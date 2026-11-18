# Deduplicate for Lightroom Classic

*[Version française](README.md)*

A **Lightroom Classic** plug-in (Windows) that finds photos and videos imported more than once, merges them without
losing any of their organisation, and thins out bursts by keeping only the best frames.

The plug-in never deletes a file. Discarded copies are gathered in a "Doublons à retirer" (duplicates to remove)
collection: removing them from the catalog is up to you.

> The plug-in's interface and its full user guide are in French. This page summarises what it does.

## What it does

- **Finds duplicates**, even renamed or re-dated ones: a content fingerprint (metadata rewritten by Lightroom or
  another program is ignored), then a thumbnail comparison for downsized, recompressed or rotated copies.
- **Chooses the copy to keep**: the largest image, then the one edited in Lightroom, then the best-filed one
  (the words that mark a messy folder are configurable).
- **Gathers everything on the kept copy**: collections, keywords, rating, flag, GPS position, title, caption…
  Virtual copies of discarded copies are recreated on it when you force a merge.
- **Shows an HTML report before changing anything**: thumbnails, which copy is kept and why, what changes in each
  collection. You can leave a group out, or force another one and pick the copy to keep.
- **Thins out bursts**: keeps the sharpest frame of each block, and always protects rated, flagged, labelled,
  edited, published or album photos.
- **Videos**: strictly identical copies are merged automatically; converted or trimmed versions can be merged by hand.

## Safety

- Nothing changes before you confirm, and the report shows exactly the plan that will be applied.
- Files are re-read just before merging: if one changed since the analysis, nothing is done.
- A backup of the collections is written and verified before each merge; a command restores it.
- Each merge or burst reduction is **a single Lightroom action**: Ctrl+Z undoes all of it.
- The catalog is read in read-only mode by Python; every change goes through the Lightroom SDK.

As with any tool that changes a catalog, back up your catalog before the first run.

## Requirements

- Lightroom Classic on **Windows** (developed and tested with Lightroom Classic 15).
- **Python 3.12 or later** ([python.org](https://www.python.org/downloads/), default install): required.
- **ImageMagick 7**: recommended (compares images of different sizes, measures burst sharpness, report thumbnails).
- **ffmpeg**: optional (video previews in the report).

## Installation

1. Download the latest version from [Releases](../../releases) and unzip it.
2. In Lightroom Classic: **File → Plug-in Manager → Add**, then choose the `lightroom-deduplicate.lrplugin` folder.
3. The commands appear under **Library → Plug-in Extras**.

The plug-in writes its reports, backups and logs next to the `lightroom-deduplicate.lrplugin` folder: put it in a
folder you can write to.

## Getting started

1. Open a folder or collection (or select a few photos), then run
   **Rechercher les doublons pour fusion…** (find duplicates to merge).
2. Click **Voir le rapport** (view report) and review the groups. Tick "Ne pas fusionner" (don't merge) or
   "Fusionner de force" (force merge) where needed, then **Copier le code** (copy code) and paste it into Lightroom.
3. Confirm. Discarded copies are in "Doublons à retirer"; to really remove them, select them in
   **Catalog → All Photographs**, then **Delete → Remove**.

The [full user guide](lightroom-deduplicate.lrplugin/LISEZ-MOI.md) (French) details every command, the selection
rules, virtual copies, backups and restoring.

## Limitations

- Windows only: ImageMagick, ffmpeg and Python are looked up at their Windows locations.
- French user interface.
- A copy is only found if its duplicates are among the analysed photos (selection or current view).

## Optional companion plug-in

If the [Albums Google Photos](https://github.com/mtthth/lightroom-google-photos) plug-in is installed in the sibling
folder `lightroom-google-photos`, both share the history of discarded photos: Google Photos no longer offers to
download photos that Deduplicate has already set aside.

## Tests

```powershell
node tests/lancer.mjs
```

The 20 Lua suites and 2 Python suites run outside Lightroom on synthetic data, with Node 22+, Lua 5.3 (MiKTeX `texlua` or `lua`)
and Python 3.12+. The `LUA` and `PYTHON` variables select the executables. They also run on GitHub on every push
(`.github/workflows/tests.yml`).

## License

[MIT](LICENSE). Changes are listed in the [changelog](CHANGELOG.md) (French).
