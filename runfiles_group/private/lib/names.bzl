"""Group names: the Label and string forms, rendering, ordering and lookup helpers."""

load("//runfiles_group/private/lib:constants.bzl", "LABEL_TYPE", "STRING_TYPE")

def name_str(value):
    """Canonical string form of a group name, for display and artifact naming.

    Not injective by construction: nothing stops a producer from naming one group
    with `Label("//p:t")` and another with the string `"@@//p:t"`. Anything that
    *keys* on the result must therefore reject a collision rather than let one
    group quietly overwrite another -- see runfiles_groups.index_by_name_str and
    finalize()'s max_groups merging.

    Args:
        value: A group name (a Label or a string), or an entry or partial.

    Returns:
        str(label) for a per-target group, the name itself for a named one.
    """

    # Label is checked before the entry/partial case on purpose: a Label has a `name`
    # field of its own (the target name), so probing for `.name` first would
    # quietly return "lib_a" instead of "//src:lib_a".
    if type(value) == LABEL_TYPE:
        return str(value)
    if type(value) == STRING_TYPE:
        return value
    name = value.name
    if type(name) == LABEL_TYPE:
        return str(name)
    return name

def check_name(where, name):
    """Fails unless name is a Label or a non-empty string.

    Args:
        where: Call-site description for error messages.
        name: The group name to check.
    """
    kind = type(name)
    if kind == LABEL_TYPE:
        return
    if kind != STRING_TYPE or not name:
        fail("{}: name must be a Label or a non-empty string, got {}".format(where, repr(name)))

def sort_key(name):
    """A comparison token for a group name that works across both forms.

    A tuple comparison stops at the first unequal element, so putting the form
    discriminator first means a Label is never compared against a string -- which
    Starlark rejects outright. Per-target groups sort before named ones within a
    rank; intra-rank order is unspecified by the protocol either way.
    """
    if type(name) == LABEL_TYPE:
        return (0, name)
    return (1, name)

def sorted_name_strs(names):
    """Sorted string forms of a collection of group names, for diagnostics."""
    return sorted([name_str(name) for name in names])

def described_name(name):
    """A group name rendered with its form, so a Label and a string never look alike."""
    if type(name) == LABEL_TYPE:
        return "Label({})".format(repr(name_str(name)))
    return repr(name)

def group_names(resolved):
    """Returns the group names of a resolved group set, as sorted strings.

    Args:
        resolved: A resolved group set, from runfiles_groups.finalize().

    Returns:
        A sorted list of canonical name strings. Use resolved.by_name if you need
        the names in their original Label-or-string form.
    """
    return sorted_name_strs(resolved.by_name)

def index_by_name_str(resolved):
    """Indexes a resolved group set by canonical name string.

    Useful for a packager whose user-facing configuration names groups as strings:
    a user writes "@@//src:lib_a" (the canonical form of a per-target group's Label)
    or "my_rules#interpreter", and this resolves either against the actual groups.

    Args:
        resolved: A resolved group set, from runfiles_groups.finalize().

    Returns:
        dict[str, RunfilesGroupPartialInfo].
    """
    by_str = {}
    for name, entry in resolved.by_name.items():
        as_str = name_str(name)

        # A Label and the string form of that same label are two distinct groups
        # that render identically. Returning a dict quietly missing one of them is
        # how a packager loses a group's files.
        if as_str in by_str:
            fail(("runfiles_groups.index_by_name_str: groups {} and {} both render as '{}'. Name one of " +
                  "them differently -- a string that spells out a Label's canonical form is a " +
                  "different group from the Label itself.").format(
                described_name(by_str[as_str].name),
                described_name(name),
                as_str,
            ))
        by_str[as_str] = entry
    return by_str
