Fixed #37224 -- Skipped questioner for field changes on unmanaged models.



Tests that must pass (names only; write them yourself under tests/):
  - test_unmanaged_add_field_unique_default
  - test_unmanaged_alter_field_no_default

Test labels: migrations.test_autodetector
