Fixed #37312, Refs #36605 -- Fixed annotation preservation and key selection in in_bulk().

Bug in 1820d35b17f0a95f4ce888971b9ca0c7a3697c83.

Thank you to Jacob Walls for the review.


Tests that must pass (names only; write them yourself under tests/):
  - test_in_bulk_values_annotation
  - test_in_bulk_values_annotation_all_fields
  - test_in_bulk_values_extra_select_all_fields
  - test_in_bulk_values_list_annotation
  - test_in_bulk_values_list_annotation_before_pk
  - test_in_bulk_values_list_flat_annotation
  - test_in_bulk_values_list_named_annotation

Test labels: lookup
