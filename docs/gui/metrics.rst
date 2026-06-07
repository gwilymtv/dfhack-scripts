gui/metrics
===========

.. dfhack-tool::
    :summary: Chart the fort metrics collected over time.
    :tags: fort inspection

``gui/metrics`` opens a resizable window that plots the per-day snapshots
recorded by the `metrics` script as an ASCII timeseries chart.

Pick any number of metrics from the list on the left; each is drawn as its own
coloured line. Pressing :kbd:`Enter` cycles the highlighted metric through three
states: off, plotted against the **left** axis, then plotted against the
**right** axis. Giving a metric the right axis lets two quantities with very
different scales -- population and wealth, say -- share one chart without either
flattening the other, since each axis auto-scales to only the series assigned to
it.

The chart redraws live, so toggling a metric, typing in the search box, or
resizing the window updates it immediately.

Usage
-----

::

    gui/metrics

You can also launch it with ``metrics gui``.

Controls
--------

:kbd:`Enter`
    Cycle the highlighted metric: off → left axis → right axis → off.

:kbd:`Shift`:kbd:`Z`
    Toggle a zero baseline. When on (the default) each axis range is extended to
    include 0 so counts are read against a real baseline; when off, the axis
    auto-fits tightly to the data so small changes are easier to see.

:kbd:`Shift`:kbd:`R`
    Reload the series from the save, picking up any days recorded since the
    window was opened.

Type to filter the metric list by name.

Collection must be running (``metrics enable``) for there to be anything to
plot; see `metrics` for the full list of recorded figures.
