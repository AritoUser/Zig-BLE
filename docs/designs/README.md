# Designs

Approved designs for larger changes live here, one file per change. A design is written before
the code and says what changes, why, what it costs and how it will be verified on hardware.

How a design gets here ("design with an elephant, review with a goldfish"):

1. Draft it with the full context of the work (the elephant).
2. Have it reviewed by agents or people who have not seen that context (the goldfish). They
   read only the design and the code it points to, so unstated assumptions show up.
3. Resolve the findings, then the maintainer approves it.

With Claude Code the [elephant-goldfish-model](https://github.com/google/elephant-goldfish-model)
plugin runs these steps (`/egm:egm-draft`, `/egm:egm-review`, `/egm:egm-resolve`). The plugin is
optional; a design reviewed by hand is just as valid.

A review does not replace tests. A design is done when the change ran on real hardware
([../HARDWARE_TESTS.md](../HARDWARE_TESTS.md)), not when it was approved.

Keep designs short ([../PHILOSOPHY.md](../PHILOSOPHY.md)): a design that needs a long page
usually describes too much change at once.
