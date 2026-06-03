gui/worldsearch
===============

.. dfhack-tool::
    :summary: Find and locate sites on the world map.
    :tags: fort inspection

The world map shows every site in the world, but finding a particular one means
hovering over each to read its name. This tool adds a searchable, left-docked
list of all sites to the world map -- both the in-fortress world map and the
world map shown when choosing an embark site for a new fort.

It starts as a small ``Find site`` button. Click it or press :kbd:`Ctrl`:kbd:`F`
to open the search panel, then type to filter the list by name and select a site
(click it or highlight it and press :kbd:`Enter`) to center the map on it and
mark it with a blinking ``X``. Press :kbd:`Esc` to close the panel, which clears
the mark. While the panel is closed the world map remains fully usable -- you can
pan, zoom, and click its buttons as normal.

Overlay
-------

This tool is provided as an `overlay` that appears on the in-fortress world map
and the embark site-selection map. Enable it through `gui/control-panel` or
with::

    overlay enable gui/worldsearch.panel
