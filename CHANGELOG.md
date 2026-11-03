# Changelog

## v0.0.1 (unreleased)

### Known issues

These are test-suite issues, not app behaviour.

- The same class of race (an assertion reads one layer before another async layer has settled) has recurred in the t231 tests (#333, #352). A shared wait helper and a forced-delay test seam are proposed as follow-up work.
