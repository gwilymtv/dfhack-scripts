gui/stockview
=============

.. dfhack-tool::
    :summary: Enhanced fortress-wide stocks browser.
    :tags: fort items inspection

A compact, searchable replacement for browsing your fortress stocks. It lists
every item in the fortress and lets you filter, sort, group, act on, and zoom to
items, taking UI inspiration from the DFHack trade screens. Items in unrevealed
parts of the map (for example, silk in caverns you haven't discovered yet) are
not listed, since you haven't found them.

Press :kbd:`Shift`:kbd:`Z` from the main fortress view to open the browser at
any time. When the script is loaded, an ``enhanced view`` button is also added
to the vanilla stocks screen (:kbd:`z` then select Stocks), so you can open the
browser without leaving the menu. The vanilla stocks screen continues to work
normally.

Usage
-----

::

    gui/stockview
    gui/stockview reset-window

``gui/stockview`` opens the browser from anywhere in fortress mode.

``gui/stockview reset-window`` forgets the saved window size and position,
reverting to the screen-relative default. This is handy if you reduced your
resolution and the remembered window no longer fits on screen.

Filtering and sorting
---------------------

- Type in the search field to narrow the list incrementally.
- Each item flag has its own three-state toggle (forbidden, marked for
  dump/melt/trade, marked hidden, owned, assigned to a military uniform, in
  inventory, construction, in building, garbage, imported, caravan-owned,
  hostile, awaiting burial, caged, in job, on fire, rotten, spider web), styled
  like the squad-assignment screen. Click to cycle
  ``Include`` (no constraint, the default) -> ``Only`` (require it) -> ``Exclude``
  (exclude items with this status).
- The rule: an item is dropped if it has *any* ``Exclude`` status; otherwise, if
  *any* toggle is set to ``Only``, the item must carry at least one ``Only``
  status. So to see just uniform items, set ``Uniform`` to ``Only`` and leave the
  rest alone — items that are also "in inventory" still show, because hiding only
  excludes when you ask for it. Because an item usually carries several statuses,
  ``Exclude`` always wins over ``Only``.
- The ``No status`` toggle covers the plain items that have none of those flags;
  set it to ``Only`` (or ``Exclude`` the rest) to browse just the "abnormal"
  items in your fort.
- ``Reset filters`` (above the toggles) returns every toggle to ``Include``.
- Each status above also appears as a colored single-letter column in the list,
  so you can see at a glance which flags an item (or grouped row) has. Each filter
  toggle's label is tinted in its status's color, tying it to that column.
- Use the quality, condition (wear), and value range sliders to restrict the
  list further.
- Click any column header to sort by it (including the single-letter status
  columns); click the active header again to reverse the direction. Name sorts
  ascending first, everything else descending first. The ``Sort by`` selector is
  a keyboard-friendly fallback for the name/quantity/value/quality/wear columns.
- ``Group items`` collapses identical items into a single counted row.

Selecting and acting on items
-----------------------------

Click or press :kbd:`Enter` to select an item (:kbd:`Shift` to select a range);
``Select all/none`` toggles the whole visible list. The action buttons then
operate on your selection (or on the highlighted row if nothing is selected):

- ``Dump``, ``Forbid``, ``Melt`` toggle the corresponding designation.
- ``Trade`` marks the items for trade at an active trade depot (only available
  while a caravan with a built depot is present).
- ``Zoom`` recenters the map on the highlighted item, following it into
  containers, inventories, and cages.

Settings
--------

The window is resizable and movable, and its size and position are remembered
along with the filter, sort, and grouping state it was closed with, so it reopens
exactly as you left it. Use ``Save default`` to persist the current settings as
your per-fortress default, and ``Restore default`` to revert to it (this restores
the filters but leaves the window where it is; use ``gui/stockview reset-window``
to reset the window itself). Both are saved with your fort. When nothing has been
saved, a sensible built-in baseline is used.
