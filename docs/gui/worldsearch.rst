gui/worldsearch
===============

.. dfhack-tool::
    :summary: Find and locate sites on the world map.
    :tags: fort inspection

When playing in fortress mode, the world map shows every site in the world, but
finding a particular one means hovering over each to read its name. This tool
adds a searchable, left-docked list of all sites to the world map.

Press :kbd:`Ctrl`:kbd:`F` to activate the search and type to filter the list by
name, then select a site (click it or highlight it and press :kbd:`Enter`) to
center the map on it and mark it with a blinking ``X``. Changing the search
clears the mark. While the search is not active, the world map remains fully
usable underneath the panel -- you can pan, zoom, and click its buttons as
normal.

Overlay
-------

This tool is provided as an `overlay` that appears on the fortress-mode world
map. Enable it through `gui/control-panel` or with::

    overlay enable gui/worldsearch.panel
