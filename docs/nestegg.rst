nestegg
=======

.. dfhack-tool::
    :summary: Keep nesting animals on their claimed nestboxes.
    :tags: fort auto animals

``nestegg`` is a roam-friendly alternative to `autonestbox`. Rather than
rounding up every female egg-layer, it acts only on Dwarf Fortress's own
nestbox-claim state: it puts a 1x1 pasture over each nestbox and, when an animal
has claimed a box, pastures *only* that claimant onto it so it broods where you
can collect the eggs. Animals with no claim are left free to roam.

For each nestbox, ``nestegg``:

- creates a 1x1 pen/pasture over it, unless it is already covered by a pasture
  (so your own larger, manually-assigned pastures are never disturbed);
- if the nestbox is unclaimed, empties its 1x1 pasture so any assigned animal
  roams free;
- if the nestbox is claimed, assigns only the claimant to its 1x1 pasture, as
  long as the claimant is free to take it.

A claim is cleared (and the pasture left empty) instead of assigned when the
claimant cannot or should not be confined to a 1x1 pen: it is a grazer (which
would starve), it is caged, chained, or restrained, or it is already assigned to
one of your other pastures.

``nestegg`` never proactively assigns animals that have not claimed a box. If you
want animals to stay in an area, pasture them yourself into a larger zone that
includes nestboxes; ``nestegg`` will leave those animals and zones alone.

Usage
-----

::

    enable nestegg
    nestegg [status]
    nestegg now

When enabled, ``nestegg`` runs a cycle periodically. ``nestegg now`` runs a
single cycle immediately without requiring the tool to be enabled.

Examples
--------

``enable nestegg``
    Start keeping nesting animals on their claimed nestboxes.

``nestegg now``
    Run a single pass right now: create missing 1x1 pastures and reconcile each
    with its nestbox's claim.
