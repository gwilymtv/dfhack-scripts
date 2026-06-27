gui/worldsearch
===============

.. dfhack-tool::
    :summary: Find and locate sites on the world map.
    :tags: fort inspection

The world map shows every site in the world, but finding a particular one means
hovering over each to read its name. This tool adds a searchable, left-docked
list of all sites to the world map -- the in-fortress world map, the world map
shown when choosing an embark site for a new fort, and the map shown during world
generation (once generation has progressed far enough to display the map).

It starts as a small ``Find site`` button. Click it or press :kbd:`Ctrl`:kbd:`F`
to open the search window, then type to filter the list by name and select a
site (click it or highlight it and press :kbd:`Enter`) to center the map on it
and mark it with a blinking ``X``. Press :kbd:`Esc` or right-click to close the
window, which clears the mark.

Each entry shows the site's owner race, type, total population, and biome
savagery. Hover over an entry to pop up a detail box listing the population
broken down by race and the maximum savagery of the biomes the site touches.

Above the list, the ``Race`` and ``Savagery`` cycles (click them or press
:kbd:`Ctrl`:kbd:`R` / :kbd:`Ctrl`:kbd:`G`) restrict the list to a single owner
race and/or savagery bracket -- for example, every elven savage site at once.
These combine with the name search box, so you can filter by race and savagery
and still type to narrow by name.

Site names can run wider than the default window, so the search window is movable
and resizable: drag its title bar to reposition it, and drag the resize handle in
its bottom-right corner (or its right/bottom edge) to resize it.

Overlay
-------

This tool is provided as an `overlay` that appears on the in-fortress world map
and the embark site-selection map. Enable it through `gui/control-panel` or
with::

    overlay enable gui/worldsearch.panel
