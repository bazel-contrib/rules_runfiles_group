"""The resolved group set that finalize() returns and transforms rebuild."""

load("//runfiles_group/private/lib:constants.bzl", "LABEL_TYPE")
load(
    "//runfiles_group/private/lib:names.bzl",
    "check_name",
    "described_name",
    "name_str",
    "sorted_name_strs",
)
load("//runfiles_group/private/lib:partial.bzl", "check_partial", "relabel")

def order_key(entry):
    # A module-level def, so sorted(key = order_key) allocates no function value
    # and no closure cell per call site. The name is wrapped in its form
    # discriminator so a Label and a string are never compared against each other.
    name = entry.name
    if type(name) == LABEL_TYPE:
        return (entry.rank, 0, name)
    return (entry.rank, 1, name)

def ordered_groups(by_name, executable_group, executable_group_last):
    """by_name's groups ordered by (rank, name), the executable group last if asked.

    With executable_group_last, the executable group already holds the highest rank
    (see raise_executable_group), so moving it to the end keeps the rank order.

    Args:
        by_name: dict of group name to RunfilesGroupPartialInfo.
        executable_group: The name of the executable group, or None.
        executable_group_last: Whether to move the executable group to the end.

    Returns:
        The list of RunfilesGroupPartialInfo, in order.
    """
    groups = sorted(by_name.values(), key = order_key)
    if not executable_group_last or executable_group == None:
        return groups
    exe = by_name[executable_group]
    return [group for group in groups if group.name != executable_group] + [exe]

def raise_executable_group(by_name, executable_group):
    """Gives the executable group the highest rank among by_name's groups.

    The executable group then sorts after every other group, and still shares a
    rank with the groups at the top, so a group limit can merge it with them.

    Args:
        by_name: dict of group name to RunfilesGroupPartialInfo. Not modified.
        executable_group: The name of the executable group, or None.

    Returns:
        by_name, or a copy of it with the executable group re-ranked.
    """
    if executable_group == None:
        return by_name
    exe = by_name[executable_group]
    top = exe.rank
    for group in by_name.values():
        if group.rank > top:
            top = group.rank
    if top == exe.rank:
        return by_name
    by_name = dict(by_name)
    by_name[executable_group] = relabel(exe, {"rank": top})
    return by_name

def make_resolved(by_name, executable_group, executable_group_last = False):
    return struct(
        groups = ordered_groups(by_name, executable_group, executable_group_last),
        by_name = by_name,
        executable_group = executable_group,
    )

def resolved_groups(groups, *, executable_group = None):
    """Builds a resolved group set from a list of partials, ordered by (rank, name).

    This is what a RunfilesGroupTransformInfo transform returns.

    Args:
        groups: List of RunfilesGroupPartialInfo. Names must be unique.
        executable_group: The name (Label or string) of the group carrying the
            executable, or None. It must name one of `groups`.

    Returns:
        struct(groups, by_name, executable_group).
    """
    by_name = {}
    for partial in groups:
        check_partial("runfiles_groups.resolved", partial)
        if partial.name in by_name:
            fail("runfiles_groups.resolved: duplicate group name '{}'".format(name_str(partial.name)))
        by_name[partial.name] = partial
    if executable_group != None:
        check_name("runfiles_groups.resolved: executable_group", executable_group)
        if executable_group not in by_name:
            fail("runfiles_groups.resolved: executable_group {} names no group. Present groups: {}".format(
                described_name(executable_group),
                sorted_name_strs(by_name),
            ))
    return make_resolved(by_name, executable_group)
