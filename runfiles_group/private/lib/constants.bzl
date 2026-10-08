"""Shared constants: rank anchors, type names and field lists."""

# Recommended rank anchors (see README "Recommended rank values").
#
# Ranks form a partial order: lower rank = earlier layer = changes least often.
# These anchors are spaced far apart on purpose so rule authors can slot extra
# sub-tiers in between (e.g. an interpreter at RANK_FOUNDATION and a standard
# library at RANK_FOUNDATION + 100) without renumbering everything.
RANK_FOUNDATION = -1000
RANK_SHARED_DEPS = -100
RANK_EXECUTABLE = 0

# Bazel keeps one empty depset per order, process-wide.
NO_PARTIALS = depset()

# The pieces of a raw partial: none.
NO_PIECES = NO_PARTIALS
DEPSET_TYPE = type(NO_PARTIALS)
LABEL_TYPE = type(Label("@rules_runfiles_group//runfiles_group"))
STRING_TYPE = type("")
INT_TYPE = type(0)
BOOL_TYPE = type(False)
FUNCTION_TYPE = "function"
TARGET_TYPE = "Target"
STRUCT_TYPE = type(struct())
LIST_TYPE = type([])
TUPLE_TYPE = type(())
DICT_TYPE = type({})
ENTRY_FIELDS = ["name", "content", "kind", "rank", "do_not_merge", "weight", "merge_affinity"]
PARTIAL_FIELDS = ["name", "contributor", "handle", "pieces", "kind", "rank", "do_not_merge", "weight", "merge_affinity"]

# The partial fields a regroup, an override or runfiles_groups.derive() may change.
# `handle`, `contributor` and `pieces` belong to the packager and to the aspect.
RELABEL_FIELDS = ["name", "kind", "rank", "do_not_merge", "weight", "merge_affinity"]
