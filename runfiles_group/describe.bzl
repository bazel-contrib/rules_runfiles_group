"""Public API for rules that describe their runfiles groups.

This is the subset of //runfiles_group:lib.bzl a rule needs in order to emit a
runfiles group describer (see RunfilesGroupDescriberInfo). It has nothing for
consuming the groups; see //runfiles_group:packager.bzl for that.

    describe.entry(name, content, kind, rank, do_not_merge, weight, merge_affinity)
        Runfiles this target adds to one group. `content` is either a runfiles
        object or, for a group that is only files, the depset of File itself.
    describe.merge_from(attr, toolchain = , fallback = , into = , regroup = , **metadata)
        Merge in the groups of the targets in one attribute, or of one toolchain.
    describe.node(add = , merge_from = , executable_group = )
        The final grouping for a single target and return value of the describer.
    describe.make_describer_rule(describe = )
        The rule whose single target a rule's _aspect_rule_hints holds.

    describe.KINDS / describe.DEFAULT_METADATA
        The closed set of `kind` values and the metadata a group has when its
        producer doesn't set it.
    describe.RANK_FOUNDATION / describe.RANK_SHARED_DEPS / describe.RANK_EXECUTABLE
        Recommended rank anchors (-1000, -100 and 0).

See //runfiles_group:lib.bzl for the full description of the protocol and of group names.
"""

load("//runfiles_group/private/lib:constants.bzl", "RANK_EXECUTABLE", "RANK_FOUNDATION", "RANK_SHARED_DEPS")
load("//runfiles_group/private/lib:describe.bzl", "make_describer_rule", "make_merge_from", "make_node")
load("//runfiles_group/private/lib:entry.bzl", "make_entry")
load("//runfiles_group/private/providers:runfiles_group_info.bzl", "DEFAULT_METADATA", "KINDS")

describe = struct(
    entry = make_entry,
    merge_from = make_merge_from,
    node = make_node,
    make_describer_rule = make_describer_rule,
    KINDS = KINDS,
    DEFAULT_METADATA = DEFAULT_METADATA,
    RANK_FOUNDATION = RANK_FOUNDATION,
    RANK_SHARED_DEPS = RANK_SHARED_DEPS,
    RANK_EXECUTABLE = RANK_EXECUTABLE,
)
