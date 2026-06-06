gui/combat-log
==============

.. dfhack-tool::
    :summary: Real-time combat log for a unit.
    :tags: fort adventure inspection units military

A compact, live-updating combat log window for a single unit. Unlike the
built-in combat history screens, this window:

- packs each report onto a single line (no wasted space for clickable icons)
- shows the oldest entry first
- keeps updating in real time while the game is running, so you can watch a
  fight unfold without pausing
- can be moved and resized, and remembers its position and size
- can optionally pause the game whenever a new entry appears
- highlights newly added entries (drawn inverted) so you can see what just
  occurred when single-stepping the game; the highlight clears once the game
  advances another step without new entries
- keeps the log view uncluttered: a line too long for the window is shown in
  full only when you hover it, via a small popup near the cursor (lines that
  already fit show no popup)

The window draws from the unit's combat, hunting, and sparring reports, merged
into a single chronological log and colored to match the native announcements.

Usage
-----

::

    gui/combat-log

View a unit (in the unit list, unit sheet, or by hovering over it on the map),
then run the command to open the log for that unit. You can also select a
corpse to open the log for the dead unit it belonged to. Run it again with a
different unit selected to point the window at the new unit.

If you scroll up to read older entries, the log stops auto-scrolling so your
position is preserved. It resumes auto-scrolling once you scroll back to the
bottom (or click :kbd:`Shift`:kbd:`E` to jump to the end).

Click a line to recenter the map on the location where that event happened.

Settings
--------

:kbd:`Shift`:kbd:`P`
    Toggle "pause on new entry". When on, the game pauses each time a new log
    entry appears for this unit.

:kbd:`Shift`:kbd:`E`
    Jump to the end of the log (re-enable auto-scrolling).
