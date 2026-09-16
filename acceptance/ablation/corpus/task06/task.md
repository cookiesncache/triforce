Fixed #37260 -- Made alterations between Python on_delete options noops.

Support for database-level delete options removed "on_delete" from
`Field.non_db_attrs` because changes to or from the new `DB_CASCADE`,
`DB_SET_DEFAULT`, and `DB_SET_NULL` options require schema changes. As a
consequence, an `AlterField` changing only a Python-level `on_delete` option
(such as `CASCADE` to `PROTECT`) performs unnecessary schema changes when it
was previously a no-op at the database level.

This commit makes `ForeignObject.non_db_attrs` a property that includes
`"on_delete"`only when the option is not a database-level one, so that:

- Python-level to Python-level changes skip DDL again,
- changes to, from, or between database-level options still alter the
  field.

Regression in 0c487aa3a7b2417481bf48c1e5355c855873e210.


Tests that must pass (names only; write them yourself under tests/):
  - test_alter_field_python_level_on_delete_noop
  - test_fk_alter_on_delete_db_level
  - test_fk_alter_on_delete_python_level_noop

Test labels: migrations.test_operations schema
