Fixed #37254 -- Added fields.E323 for models referenced by ManyToManyFields.

Thanks Jacob Walls and Sarah Boyce for reviews.

Tests that must pass (names only; write them yourself under tests/):
  - test_db_python_m2m_chain

Test labels: invalid_models_tests.test_relative_fields
