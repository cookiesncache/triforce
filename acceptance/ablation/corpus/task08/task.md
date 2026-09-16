Fixed #37262 -- Restored rendering of html-safe strings in form media.

`Media.__init__()` normalized every string js/css entry into `Script` or
`Stylesheet` objects. `SafeString` is a `str` subclass, so html-safe strings
such as `mark_safe("<script defer src=...></script>")`, a previously-documented
idiom for including complete asset tags, were treated as asset paths,
run through `static()`, and percent-encoded instead of being rendered
verbatim.

Leave objects providing `__html__()` un-normalized so that they take the
verbatim rendering path, restoring the Django 6.0 behavior.

Regression in 8096b5251090bf7539c59956e398b027c7525529.

co-authored-by: Johannes Maron <johannes@maron.family>


Tests that must pass (names only; write them yourself under tests/):
  - test_html_safe_string_css
  - test_html_safe_string_deduplication
  - test_html_safe_string_js
  - test_html_safe_string_merging

Test labels: forms_tests
