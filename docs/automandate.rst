automandate
===========

.. dfhack-tool::
    :summary: Create work orders to fulfill noble production mandates.
    :tags: fort workorders

When a noble issues a production mandate (e.g. "Make maces (0/3)"),
``automandate`` resolves the mandated item to its production job and queues a
manager work order to satisfy it. Mandates with no specific material requested
pick the most abundant usable material in the fort (metal, stone, wood, leather,
cloth, bone, or glass).

An order is only created when there is enough usable material in stock to make
the full quantity -- whether the noble named the material or it was chosen
automatically. If there isn't enough (or the item can't be mapped to a job),
the mandate is skipped and a warning is printed instead.

Existing matching orders count toward the mandate: if they already cover the
mandated quantity (or an order is set to repeat indefinitely), nothing is added.
If they fall short, ``automandate`` adds a *new* order for just the remaining
quantity -- it never modifies an existing order, whose count may be deliberate.
This makes it safe to run ``automandate now`` repeatedly.

Usage
-----

::

    automandate [list]
    automandate now
    automandate simulate
    automandate enable|disable|status

``list`` (the default)
    Show all active production mandates and the work order each would create,
    without changing anything.

``now``
    Create a manager work order for every active production mandate.

``simulate``
    Show the work order that would be created for an any-material mandate of
    every mandatable item type, without changing anything. Useful for
    previewing material choices when you have no active mandates to test with.

``enable``/``disable``/``status``
    Turn automatic fulfillment on or off, or report the current state.

Automation
----------

When enabled, ``automandate`` fulfills mandates on a recurring cycle (every 14
days). It stays quiet about mandates that need nothing, but for every order it
creates it prints the full breakdown -- the job, quantity, and the ranked
material candidates with the chosen one marked -- plus any warnings. The enabled
state is saved per fortress. Toggle it here or from the Automation tab of
`gui/control-panel`.

There is also an optional ``unfilled_mandates`` `notify` notification (off by
default) that reports how many production mandates currently have no work
order.
