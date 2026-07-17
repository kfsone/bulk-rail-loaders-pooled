# Modern Bulk Rail Loaders: Pooled

A pooled-inventory rework of the bulk rail loader concept. Every station has
**one** hidden cargo inventory (the *pool*); each visible silo is a Factorio 2.0
`proxy-container` — a physical window onto that shared pool. Because there is
only one inventory per station:

* Contents can never get unbalanced between wagons. A train's order completes
  whenever the **station total** suffices — no stuck partial loads.
* There is no balancing logic and no recurring UPS cost for it.
* Factory inserters/loaders can feed or drain **any** silo; it all lands in the
  same pool.

Requires **Factorio ≥ 2.0.38** (the version that introduced proxy containers).

## Usage

1. Open a train stop and use the **Bulk loaders** panel: pick the wagon count,
   locomotive gap, and the station mode (**Load** / **Unload**).
2. Silos are placed automatically over each wagon slot; blocked positions get
   ghosts you can revive after clearing obstructions.
3. Loading stations show a hopper structure over each wagon; unloading
   stations show a tipper grate beneath the track.

### Circuit network / Cybersyn

Wire **exactly one** silo (any of them) to your circuit network or Cybersyn
combinator — every silo reports the full shared pool, so wiring two silos
doubles the reading.

## Design notes

* The pool is a hidden, indestructible container placed at the train stop. Its
  usable size is `silo capacity × silo count`, enforced with an inventory bar.
* Mining a silo loses nothing (items live in the pool). Removing the *last*
  silo of a station spills the pool contents on the ground rather than voiding
  them.
* Stations are uniform: the whole station either loads or unloads. Mixed
  stations would mix incoming and outgoing cargo in one pool.
* Hand-placed silos attach to the nearest train stop within 100 tiles
  (preferring stops that already have silos), or get a private pool if none.

## Licensing / attribution

* Code: original to this mod.
* All graphics (`graphics/loader-*.png`, `graphics/unloader-*.png`) are from
  [railloader by mspielberg (therax)](https://github.com/mspielberg/factorio-railloader),
  licensed **LGPL-3.0** (see `LICENSE-railloader-graphics`). Keep that license
  file and this attribution if you redistribute the mod.

## Development

Symlink into your mods folder under the mod's name (the folder name must match
`info.json`):

```
ln -s /path/to/this/repo ~/.factorio/mods/modern-bulk-rail-loader-pooled
```
