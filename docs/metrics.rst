metrics
=======

.. dfhack-tool::
    :summary: Track and view the evolution of the fort over time.
    :tags: fort inspection

``metrics`` records a daily (in-game) snapshot of fort-wide scalar figures --
the kind shown in the game's top bar -- and saves them with the fort so you can
review how it has changed over time.

Each snapshot captures:

- **population** -- live count of fort citizens
- **military** -- citizens assigned to a squad
- **pets/livestock** and **others** -- counts matching the Citizens screen's
  Pets/Livestock tab (fort-owned animals) and Others tab (everyone else present
  and alive: visitors, merchants, residents, invaders, wildlife)
- **workshops** -- count of workshop and furnace buildings, and how many of them
  currently have an actively-worked job (a non-suspended job with a worker)
- **happiness** -- citizens bucketed into DF's 7 stress bands (miserable,
  unhappy, displeased, content, pleased, happy, ecstatic). Stored internally as a
  cumulative histogram over the stress value bands plus a sum of raw stress
  values (the same form as a Prometheus classic histogram, with its ``_bucket``
  and ``_sum``). The mean is therefore exact, and median/quantile stress can be
  recovered by linear interpolation within a band. ``now`` prints the per-band
  counts plus the exact mean and interpolated p10/median/p90.
- **wealth** -- created (total), weapons, armor and garb, furniture, other
  objects, architecture, displayed, held/worn, imported, and exported
- **stocks** -- food total, drink, seeds, meat, fish, plant, and other

Population, military, happiness, pets/others, and workshops are computed live.
Wealth and stock figures are read from the fort's activity statistics -- the same
periodically-recomputed aggregates DF shows in the status bar -- so they update
on DF's own cadence rather than the instant the snapshot is taken.

This is a v1 that focuses on easily-collected figures; more metrics will be
added over time.

Usage
-----

::

    metrics [status]
    metrics enable|disable
    metrics now
    metrics dump
    metrics clear
    metrics gui

``status`` (the default)
    Report whether collection is enabled and how many data points have been
    recorded.

``enable``/``disable``
    Start or stop daily collection. While enabled, a snapshot is taken once per
    in-game (calendar) day; sampling is keyed to the calendar, so it stays one
    point per day even when `timestream` is speeding the calendar up. The enabled
    state is saved per fortress.

``now``
    Record (or, if one already exists for today, refresh) a snapshot
    immediately and print it in human-readable form.

``dump``
    Print the whole series as CSV (a header row followed by one row per in-game
    day) for piping into a spreadsheet or analysis tool. Use ``now`` for a
    readable single-snapshot view.

``clear``
    Discard all recorded data points for this fort.

``gui``
    Open `gui/metrics` to plot the recorded series as a chart.
