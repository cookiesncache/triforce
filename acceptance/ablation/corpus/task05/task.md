Fixed #37278 -- Made QuerySet.totally_ordered understand aliases to pure Col/ColPairs.

Thanks Simon Charette for the review.


Tests that must pass (names only; write them yourself under tests/):
  - test_alias
  - test_alias_relation
  - test_alias_self_relation
  - test_alias_totally_ordered

Test labels: composite_pk.test_order_by ordering
