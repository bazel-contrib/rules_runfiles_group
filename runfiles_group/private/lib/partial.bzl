"""RunfilesGroupPartialInfo construction, re-labeling and metadata combination."""

load("//runfiles_group/private/lib:constants.bzl", "NO_PIECES", "PARTIAL_FIELDS", "RELABEL_FIELDS")
load("//runfiles_group/private/lib:entry.bzl", "check_metadata")
load("//runfiles_group/private/lib:names.bzl", "check_name", "name_str")
load("//runfiles_group/private/providers:runfiles_group_info.bzl", "KINDS")
load("//runfiles_group/private/providers:runfiles_group_partial_info.bzl", "RunfilesGroupPartialInfo")

def make_partial(entry_or_partial, *, contributor, handle):
    """Builds a raw partial carrying `entry_or_partial`'s name and metadata."""
    return RunfilesGroupPartialInfo(
        name = entry_or_partial.name,
        contributor = contributor,
        handle = handle,
        pieces = NO_PIECES,
        kind = entry_or_partial.kind,
        rank = entry_or_partial.rank,
        do_not_merge = entry_or_partial.do_not_merge,
        weight = entry_or_partial.weight,
        merge_affinity = entry_or_partial.merge_affinity,
    )

def relabel(partial, overrides):
    """A copy of a partial with some name/metadata fields replaced. Validates nothing."""
    return RunfilesGroupPartialInfo(
        name = overrides.get("name", partial.name),
        contributor = partial.contributor,
        handle = partial.handle,
        pieces = partial.pieces,
        kind = overrides.get("kind", partial.kind),
        rank = overrides.get("rank", partial.rank),
        do_not_merge = overrides.get("do_not_merge", partial.do_not_merge),
        weight = overrides.get("weight", partial.weight),
        merge_affinity = overrides.get("merge_affinity", partial.merge_affinity),
    )

def check_overrides(where, overrides):
    for field, value in overrides.items():
        if field not in RELABEL_FIELDS:
            fail("{}: unknown field '{}', expected one of {}".format(where, field, RELABEL_FIELDS))
        check_metadata(where, field, value)

def derive(partial, **overrides):
    """Copies a partial, changing only the name/metadata fields passed.

    For RunfilesGroupTransformInfo transforms and regroup functions' callers. The
    handle, the contributor and the pieces cannot change: they belong to the
    packager and to the aspect.

    Args:
        partial: The RunfilesGroupPartialInfo to copy.
        **overrides: Any subset of name, kind, rank, do_not_merge, weight and
            merge_affinity.

    Returns:
        A new RunfilesGroupPartialInfo.
    """
    check_overrides("runfiles_groups.derive", overrides)
    return relabel(partial, overrides)

def _combine_str(a, b):
    if not a:
        return b
    if not b:
        return a
    return min(a, b)

def max_weight(a, b):
    """The larger of two weights, where None means "no weight".

    Args:
        a: An int or None.
        b: An int or None.

    Returns:
        An int, or None if both are None.
    """
    if a == None:
        return b
    if b == None:
        return a
    return max(a, b)

def combine(a, b, weight):
    """a's identity, with the metadata of a and b combined and the given weight."""
    return RunfilesGroupPartialInfo(
        name = a.name,
        contributor = a.contributor,
        handle = a.handle,
        pieces = a.pieces,
        kind = _combine_str(a.kind, b.kind),
        rank = min(a.rank, b.rank),
        do_not_merge = a.do_not_merge or b.do_not_merge,
        weight = weight,
        merge_affinity = _combine_str(a.merge_affinity, b.merge_affinity),
    )

def check_partial(where, partial):
    """Fails unless partial looks like a RunfilesGroupPartialInfo with a legal name and kind.

    Args:
        where: Call-site description for error messages.
        partial: The value to check.
    """
    for field in PARTIAL_FIELDS:
        if not hasattr(partial, field):
            fail(("{}: expected a RunfilesGroupPartialInfo, got a value without field '{}'; " +
                  "edit groups with runfiles_groups.derive()").format(where, field))
    check_name(where, partial.name)
    if partial.kind not in KINDS:
        fail("{}: group '{}' has kind {}, expected one of {}".format(where, name_str(partial.name), repr(partial.kind), KINDS))
