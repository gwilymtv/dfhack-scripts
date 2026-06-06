farmplot
========

.. dfhack-tool::
    :summary: Overlay for faster farm plot crop selection.
    :tags: fort productivity buildings interface

This script provides an overlay that is managed by the `overlay` framework.
The script does nothing when executed directly.

The ``farmplot.allseasons`` overlay adds a shortcut to the farm plot info
sheet. When you **shift+click** a crop to assign it to a season, that same
crop is also assigned to every other season in which it can be planted. This
saves you from switching to each season tab and selecting the crop again.

Plain (non-shift) clicks behave normally, changing only the selected season.
Seasons in which the crop cannot be planted are left untouched.
