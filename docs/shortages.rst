shortages
=========

.. dfhack-tool::
    :summary: Track materials your fort is short on.
    :tags: fort jobs

When a job can't proceed for lack of an ingredient, Dwarf Fortress emits a
cancellation announcement such as ``Urist cancels Make cloth hood: needs 1
unused plant cloth``. These scroll past in the announcement log and are easy to
miss. This tool watches for those ``needs ...`` cancellations and maintains a
running, on-screen summary of the materials your fort is currently short on, so
you don't have to read the announcement stream.

Shortages are aggregated over a rolling window (7 days by default), so a
shortage that stops being reported fades out of the list on its own once your
dwarves are no longer cancelling jobs for it. The window is measured in DF days,
where a month is 28 days and a year is 336 days (4 seasons of 84 days).

The summary is rebuilt from the live announcement log, including any matching
cancellations still within the window that were logged before the tool loaded.
It is recomputed per fort and is not persisted across save/load.

Usage
-----

``shortages [list]``
    Print the current shortage summary to the console.

``shortages window <days>``
    Set the rolling window, in in-game days, over which cancellations are
    aggregated. Defaults to ``7``.

``shortages group item|job|both``
    Choose how shortages are grouped: by the needed ``item`` (the default), by
    the ``job`` that was cancelled, or by ``both`` (job and item together).

Overlay
-------

This tool provides an overlay, enabled by default, that displays the aggregated
shortages in the corner of the main fortress map. The panel hides itself when
there are no current shortages. Each line shows the summed quantity needed,
e.g. ``4 unused plant cloth``.

Use the :kbd:`Ctrl`:kbd:`G` hotkey on the panel to cycle the grouping between
item, job, and both.

Dwarf Fortress collapses repeated identical cancellations into a single
announcement with an ``xN`` repeat count; the tool reads that count, so a job
that keeps failing for the same material is tallied by how many times it has
been cancelled within the window.
