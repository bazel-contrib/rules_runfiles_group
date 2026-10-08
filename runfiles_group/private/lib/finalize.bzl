"""The root step: fold, transform, limit and order."""

load("//runfiles_group/private/lib:constants.bzl", "STRUCT_TYPE")
load("//runfiles_group/private/lib:limit.bzl", "limit")
load("//runfiles_group/private/lib:names.bzl", "described_name", "sorted_name_strs")
load("//runfiles_group/private/lib:packager.bzl", "check_ctx", "check_ops")
load("//runfiles_group/private/lib:resolve.bzl", "fold")
load("//runfiles_group/private/lib:resolved.bzl", "make_resolved", "raise_executable_group", "resolved_groups")
load("//runfiles_group/private/providers:runfiles_group_transform_info.bzl", "RunfilesGroupTransformInfo")

def finalize(ctx, info, ops, *, aspect_hints, max_groups = None, default_weight = 0, merged_group_name = None, executable_group_last = True):
    """Turns a root target's packager info into its final, ordered groups.

    This is the only place in the protocol that flattens a whole closure, and it
    flattens partials -- one small record per (target, group) -- never files. Call
    it once per *consuming* target.

    `aspect_hints` is a mandatory keyword: with a default, the correct call and the
    call that silently ignores every user hint look identical. Pass the root's
    aspect_hints, or [].

    Args:
        ctx: The rule or aspect context, handed to ops.merge.
        info: The root target's packager provider (PACKAGER_INFO_FIELDS).
        ops: From runfiles_groups.packager_ops().
        aspect_hints: The root's aspect_hints (list of Targets), or [].
        max_groups: If set, merge groups until at most this many remain. Merges
            stay within a rank and never touch a do_not_merge group, prefer pairs
            that share a merge_affinity ("" is the shared "no affinity" bucket),
            and then the two lightest by weight. The caller MUST check
            group_count: those constraints can make max_groups unreachable.
        default_weight: Weight to assume for groups whose weight is None.
        merged_group_name: Optional function
            (lighter_name, lighter_weight, heavier_name, heavier_weight) -> name
            naming a group merged for max_groups. The names it receives are in their
            original Label-or-string form. If None, the heavier group's name is kept.
        executable_group_last: If True, the executable group, which usually changes
            most often, comes last: after the transforms it takes the highest rank
            of all present groups, so it still merges with the groups at that
            rank, and it sorts after them. If False, it is ordered like any other
            group.

    Returns:
        struct(groups, by_name, executable_group, group_count). `groups` are
        RunfilesGroupPartialInfo ordered by (rank, name), with the executable group
        last if executable_group_last; executable_group, if not None, names one of
        them. A root that does not describe its groups yields
        one synthesized group, which also carries the executable.
    """
    check_ctx("runfiles_groups.finalize", ctx)
    check_ops("runfiles_groups.finalize", ops)
    executable_group = info.executable_group
    if info.fallback != None:
        by_name = {info.fallback.name: info.fallback}
        executable_group = info.fallback.name
    else:
        by_name = fold(ctx, ops, depset(transitive = [info.owned, info.shared]).to_list())
    if executable_group != None and executable_group not in by_name:
        fail("runfiles_groups.finalize: executable_group {} names no group. Present groups: {}".format(
            described_name(executable_group),
            sorted_name_strs(by_name),
        ))

    resolved = make_resolved(by_name, executable_group)
    for hint in aspect_hints:
        if RunfilesGroupTransformInfo in hint:
            result = hint[RunfilesGroupTransformInfo].transform(resolved)
            if type(result) != STRUCT_TYPE or not hasattr(result, "groups"):
                fail("aspect_hint {}: transform must return runfiles_groups.resolved(...), got {}".format(
                    hint.label,
                    type(result),
                ))

            # Re-validated here so that a transform which drops the executable
            # group or emits a hand-rolled group fails naming the hint, rather
            # than three rules downstream.
            resolved = resolved_groups(
                result.groups,
                executable_group = getattr(result, "executable_group", None),
            )

    if executable_group_last:
        resolved = make_resolved(
            raise_executable_group(resolved.by_name, resolved.executable_group),
            resolved.executable_group,
            executable_group_last = True,
        )

    if max_groups == None:
        return struct(
            groups = resolved.groups,
            by_name = resolved.by_name,
            executable_group = resolved.executable_group,
            group_count = len(resolved.by_name),
        )
    return limit(
        ctx,
        ops,
        resolved,
        max_groups = max_groups,
        default_weight = default_weight,
        merged_group_name = merged_group_name,
        executable_group_last = executable_group_last,
    )
