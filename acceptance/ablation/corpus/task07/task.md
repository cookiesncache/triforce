Fixed #37248 -- Skipped unique validation of a dynamic DatabaseDefault expression.



Tests that must pass (names only; write them yourself under tests/):
  - test_database_default_expression
  - test_unique_db_default_expression
  - test_unique_together_db_default_expression

Test labels: constraints validation validation.test_unique
