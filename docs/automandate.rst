automandate
===========

.. dfhack-tool::
    :summary: Create work orders to fulfill noble production mandates.
    :tags: fort workorders

When a noble issues a production mandate (e.g. "Make maces (0/3)"),
``automandate`` resolves the mandated item to its production job and queues a
manager work order to satisfy it. Mandates with a specific material requested
produce orders restricted to that material; mandates with no material produce
unrestricted orders.

Existing matching orders are reconciled rather than duplicated, so it is safe to
run ``automandate now`` repeatedly.

Usage
-----

::

    automandate [list]
    automandate now
    automandate simulate

``list`` (the default)
    Show all active production mandates and the work order each would create,
    without changing anything.

``now``
    Create a manager work order for every active production mandate.

``simulate``
    Show the work order that would be created for an any-material mandate of
    every mandatable item type, without changing anything. Useful for
    previewing material choices when you have no active mandates to test with.
