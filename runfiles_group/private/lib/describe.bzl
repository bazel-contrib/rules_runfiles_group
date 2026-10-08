"""The rule side: node(), merge_from() and the describer rule."""

load(
    "//runfiles_group/private/lib:constants.bzl",
    "FUNCTION_TYPE",
    "LIST_TYPE",
    "STRING_TYPE",
    "STRUCT_TYPE",
    "TUPLE_TYPE",
)
load("//runfiles_group/private/lib:entry.bzl", "check_entry")
load("//runfiles_group/private/lib:names.bzl", "check_name")
load("//runfiles_group/private/lib:partial.bzl", "check_overrides")
load("//runfiles_group/private/providers:runfiles_group_describer_info.bzl", "RunfilesGroupDescriberInfo")

_FALLBACKS = ["ignore", "synthesize"]

def make_merge_from(attr, *, fallback = "ignore", into = None, regroup = None, **overrides):
    """Describes one attribute whose targets' runfiles groups a target merges in.

    Renaming, regrouping and overriding flatten the attribute's partials, which is
    O(their whole subtree) for this target. Reserve them for targets that sit near
    the top of a graph -- binaries, not libraries. Without them, the attribute's
    partials are merged in by reference.

    Args:
        attr: Name of the attribute. It MUST be listed in the rule's
            _runfiles_group_attrs, which is what the aspect walks.
        fallback: What a target in the attribute contributes when its rule does
            not describe its runfiles groups. "ignore" (the default) contributes
            nothing -- right for a ruleset's own dependency attributes, where such a
            target's DefaultInfo would claim its whole closure. "synthesize"
            contributes one per-target group holding its DefaultInfo -- right for
            `data`-like attributes holding arbitrary targets and files. A
            module-level def (ctx, dep) -> RunfilesGroupInfo or None synthesizes
            the group itself, for a ruleset that knows better than DefaultInfo
            what such a dependency contributes at runtime -- the transitive
            runtime jars of a foreign JVM rule, say. It is called on the merging
            target, with the aspect's ctx, for every dependency without a
            describer, files included; build the entry with
            runfiles_groups.entry(), conventionally named dep.label.
        into: Optional group name every incoming group is renamed to.
        regroup: Optional module-level def (partial, owner_label) -> dict | None,
            called once per incoming partial with the merging target's Label. A
            dict replaces any of name, kind, rank, do_not_merge, weight and
            merge_affinity; None keeps the partial unchanged. Mutually exclusive
            with `into`.
        **overrides: Metadata applied to every incoming group: any of kind, rank,
            do_not_merge, weight and merge_affinity. A regroup result wins over
            these.

    Returns:
        A struct, for runfiles_groups.node(merge_from = [...]).
    """
    where = "runfiles_groups.merge_from({})".format(repr(attr))
    if type(attr) != STRING_TYPE or not attr:
        fail("runfiles_groups.merge_from: attr must be a non-empty attribute name, got ", repr(attr))
    if type(fallback) != FUNCTION_TYPE and fallback not in _FALLBACKS:
        fail("{}: fallback must be one of {} or a function, got {}".format(where, _FALLBACKS, repr(fallback)))
    if into != None:
        check_name(where + ": into", into)
        if regroup != None:
            fail("{}: into and regroup are mutually exclusive".format(where))
    if regroup != None and type(regroup) != FUNCTION_TYPE:
        fail("{}: regroup must be a function, got {}".format(where, type(regroup)))
    if "name" in overrides:
        fail("{}: use into = to rename incoming groups".format(where))
    check_overrides(where, overrides)
    return struct(
        attr = attr,
        fallback = fallback,
        into = into,
        regroup = regroup,
        overrides = overrides,
        relabels = into != None or regroup != None or len(overrides) > 0,
    )

# Marks a struct as the value of runfiles_groups.node(), so aspect_step() can tell
# a describer that returned something else.
NODE_MARKER = "runfiles_groups.node"

def make_node(*, add = [], merge_from = None, executable_group = None):
    """What a runfiles group describer returns: its own runfiles and its merge edges.

    Args:
        add: List of RunfilesGroupInfo, built with runfiles_groups.entry(): the
            runfiles the target ITSELF adds -- its own sources, its own actions'
            outputs. Never a dependency's runfiles: those arrive through
            `merge_from`.
        merge_from: List of attribute names and/or runfiles_groups.merge_from()
            values. A bare name means merge_from(name). None (the default) means
            every attribute in the rule's _runfiles_group_attrs.
        executable_group: The name of the group that should receive the
            executable and its supporting files, or None to let the packager
            decide. Only the root target's is used.

    Returns:
        A struct, for the describer to return.
    """
    if type(add) != LIST_TYPE and type(add) != TUPLE_TYPE:
        fail("runfiles_groups.node: add must be a list of entries, got ", type(add))
    for entry in add:
        check_entry("runfiles_groups.node", entry)
    specs = None
    if merge_from != None:
        specs = []
        attrs = {}
        for spec in merge_from:
            if type(spec) == STRING_TYPE:
                spec = make_merge_from(spec)
            elif type(spec) != STRUCT_TYPE or not hasattr(spec, "relabels"):
                fail("runfiles_groups.node: merge_from must hold attribute names or runfiles_groups.merge_from() values, got ", type(spec))
            if spec.attr in attrs:
                fail("runfiles_groups.node: attribute '{}' appears in merge_from twice".format(spec.attr))
            attrs[spec.attr] = True
            specs.append(spec)
    if executable_group != None:
        check_name("runfiles_groups.node: executable_group", executable_group)
    return struct(
        marker = NODE_MARKER,
        add = add,
        merge_from = specs,
        executable_group = executable_group,
    )

def make_describer_rule(*, describe):
    """Makes the rule whose target a rule's _runfiles_group_describer points at.

    Args:
        describe: A module-level def (target, ctx) -> runfiles_groups.node() or
            None. See RunfilesGroupDescriberInfo.

    Returns:
        A rule. Instantiate it once, next to the rule it describes.
    """
    if type(describe) != FUNCTION_TYPE:
        fail("runfiles_groups.make_describer_rule: describe must be a function, got ", type(describe))
    return rule(
        implementation = lambda ctx: [RunfilesGroupDescriberInfo(describe = describe)],
        doc = "Holds the runfiles group describer of one rule. See RunfilesGroupDescriberInfo.",
    )
