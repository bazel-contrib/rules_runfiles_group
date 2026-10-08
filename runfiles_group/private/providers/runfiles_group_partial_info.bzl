"""Defines RunfilesGroupPartialInfo: one materialized piece of a runfiles group.

A packager's aspect turns every RunfilesGroupInfo a target adds into a raw partial
by calling the packager's `materialize` operation, and propagates partials up the
dependency graph inside depsets. Several partials may share a group name -- one
per contributing target -- and the packager's `merge` operation combines them into
a merged partial, either where they meet during aspect application or in
runfiles_groups.finalize(), depending on the packager's `dedup` mode.

The provider is deliberately not part of the constructor API: runfiles_groups
builds every partial, so every one in circulation has been validated.
"""

RunfilesGroupPartialInfo = provider(
    doc = "One target's materialized contribution to a runfiles group, plus the group's metadata.",
    fields = {
        "name": "Label or str: the group this partial belongs to. See RunfilesGroupInfo.name.",
        "contributor": """\
Label or None: for a raw partial, the target whose runfiles the handle holds. None
for a merged partial, whose raw pieces are in `pieces`. Merges order their inputs
by contributor, so results never depend on depset traversal order.
""",
        "pieces": """\
depset of (contributor, handle) tuples: for a merged partial, the raw pieces its
handle was built from, by key; empty for a raw partial. A merged partial references
the pieces of the merged partials it was built from, so merging again further up
is cheap. A packager that rebuilds a merged group instead of concatenating
can read every raw piece's handle from here.
""",
        "handle": """\
Packager-defined: whatever the packager's `materialize` or `merge` returned --
a File (a tar layer, say), a depset, a runfiles object, or a struct/tuple of
those. Opaque to runfiles_groups. MUST be immutable, because it lives inside a
depset element: no lists or dicts.
""",
        "kind": "str: one of KINDS. See RunfilesGroupInfo.kind.",
        "rank": "int: partial ordering key. Lower rank = earlier = more cacheable.",
        "do_not_merge": "bool: if True, finalize() must not merge this group with another.",
        "weight": "int >= 0 or None: merge priority hint. Lighter groups merge first.",
        "merge_affinity": "str: merge grouping hint. \"\" means no affinity.",
    },
)
