"""Defines RunfilesGroupInfo: runfiles a target adds to a group.

A rule's runfiles group describer returns these in `runfiles_groups.node(add = ...)`.
Each one describes runfiles the target ITSELF adds -- its own sources, the outputs
of its own actions -- to one named group. Several targets may add to the same
group; the packager merges them.

An instance is short-lived: the packager's aspect hands it to the packager's
`materialize` operation on the same node and drops it.

`runfiles_groups.entry()` is the only supported constructor, so every instance in
circulation has been validated.
"""

# Closed set of group kinds. "" means unspecified.
#
# `kind` is the protocol's stable, machine-readable selector. A group name is either
# a Label or a ruleset-internal prefixed string, so packager configuration keyed on a
# name breaks the moment a target is renamed; `kind` does not.
#
# It deliberately has no effect on ordering or merging -- that is what `rank` and
# `merge_affinity` are for.
KINDS = [
    "",
    "foundation",  # language runtimes, interpreters, standard libraries
    "third_party",  # dependencies from outside the workspace
    "first_party",  # the workspace's own code and data
    "debug",  # debug symbols, source maps
    "docs",  # documentation, licences, manifests
]

# The metadata a group has when its producer doesn't provide it;
# runfiles_groups.entry()'s defaults.
DEFAULT_METADATA = struct(
    rank = 0,
    do_not_merge = False,
    weight = None,
    kind = "",
    merge_affinity = "",
)

RunfilesGroupInfo = provider(
    doc = "Runfiles a target adds to one group: a name, the contents, and ordering/merge metadata.",
    fields = {
        "name": """\
Label or str: the identity of the group this adds to. A Label means a per-target
group -- "the runfiles this one target contributes" -- and needs no prefix, because
a Label is globally unique. A string means a named group that several targets may
contribute to; prefix those with something unique to your ruleset.
runfiles_groups.name_str() renders either form as a string.
""",
        "content": """\
runfiles or depset of File: the contents of this group. A depset is the shorthand
for a group that is only files, which uses less memory; a runfiles object is the
general form that can represent empty files, runfiles symlinks, root symlinks, and files.
""",
        "kind": "str: one of KINDS. A stable selector for packagers. \"\" means unspecified.",
        "rank": "int: partial ordering key. Lower rank = earlier = more cacheable. Default 0.",
        "do_not_merge": "bool: if True, packagers must not merge this group. Default False.",
        "weight": "int >= 0 or None: merge priority hint. Lighter groups merge first.",
        "merge_affinity": "str: merge grouping hint. \"\" means no affinity.",
    },
)
