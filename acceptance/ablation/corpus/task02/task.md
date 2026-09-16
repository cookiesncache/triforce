Fixed #37293 -- Renamed RemovedInDjango71Warning to RemovedInDjango2029Warning.

Per DEP 20, Django's version numbers are calendar-based from 2028, so
deprecation warning classes are now named after the calendar version
that removes the feature they mark, and the deprecation timeline is
headed by the same calendar version.

Updated references to RemovedInDjango71Warning to use the new warning,
and adjusted references to "Django 7.1" to "Django 2029".


Tests that must pass (names only; write them yourself under tests/):

Test labels: async.test_async_queryset deprecation.test_middleware_mixin httpwrappers
