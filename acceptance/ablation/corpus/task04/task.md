Fixed #37259 -- Restored support for old-signature Model.from_db() overrides.

The fetch modes feature made all query iteration paths (ModelIterable,
RawModelIterable, and RelatedPopulator) call Model.from_db() with a
fetch_mode keyword argument. This crashed with a TypeError for models
overriding from_db() with the previously documented signature
from_db(cls, db, field_names, values).

Query iteration now detects, once per query rather than per row, whether
the model's from_db() accepts the fetch_mode keyword argument (or
**kwargs) and calls old-style overrides without it, emitting a
RemovedInDjango70Warning asking authors to add the argument.

Regression in e097e8a12f21a4e92594830f1ad1942b31916d0f.


Tests that must pass (names only; write them yourself under tests/):
  - test_new_signature_receives_fetch_mode
  - test_new_signature_receives_fetch_mode_peers
  - test_old_signature_get
  - test_old_signature_iteration
  - test_old_signature_raw
  - test_old_signature_select_related

Test labels: basic
