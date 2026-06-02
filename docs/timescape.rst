timescape
=========

.. dfhack-tool::
    :summary: Show a custom date format over the fort date display.
    :tags: fort interface

Covers Dwarf Fortress's stock date readout in the top-right of the fortress map
with a compact custom format, ``YY-MM-DD HHh`` (for example ``173-08-11 13h``),
plus a two-line area for colored ASCII art.

The art is meant to be procedurally generated: edit the ``get_art_lines``
function in the script to return your own colored segments. The default is a
placeholder that draws a season-colored progress bar through the current month.

DF time reference: 1200 ticks per day, 28 days per month, 12 months (336 days)
per year, and 50 ticks per hour.

Usage
-----

``timescape [list]``
    Print the current formatted date to the console.

Overlay
-------

The display is provided as an overlay, enabled by default, on the main fortress
map. Because it draws over DF's own date text, you will want to align it: use
`gui/overlay` or drag it in overlay edit mode so it sits on top of the stock
date.
