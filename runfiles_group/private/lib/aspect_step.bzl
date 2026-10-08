"""The body of a packager's aspect."""

load("//runfiles_group/private/lib:attrs.bzl", "attr_targets", "synthesized_entry")
load("//runfiles_group/private/lib:constants.bzl", "DICT_TYPE", "FUNCTION_TYPE", "NO_PARTIALS", "STRUCT_TYPE")
load("//runfiles_group/private/lib:describe.bzl", "NODE_MARKER", "make_merge_from")
load("//runfiles_group/private/lib:entry.bzl", "check_entry")
load("//runfiles_group/private/lib:packager.bzl", "check_ops")
load("//runfiles_group/private/lib:partial.bzl", "check_overrides", "make_partial", "relabel")
load("//runfiles_group/private/lib:resolve.bzl", "resolve_name")
load("//runfiles_group/private/providers:runfiles_group_describer_info.bzl", "RunfilesGroupDescriberInfo")

def _materialize(ctx, ops, entry, contributor):
    return make_partial(entry, contributor = contributor, handle = ops.materialize(ctx, entry))

def _relabeled(partial, spec, owner):
    """Applies a merge_from() spec's rename, overrides and regroup to one partial."""
    overrides = spec.overrides
    if spec.into != None:
        overrides = dict(overrides, name = spec.into)
    elif spec.regroup != None:
        result = spec.regroup(partial, owner)
        if result != None:
            if type(result) != DICT_TYPE:
                fail("runfiles_groups.merge_from({}): regroup must return a dict or None, got {}".format(repr(spec.attr), type(result)))
            check_overrides("runfiles_groups.merge_from({}): regroup result".format(repr(spec.attr)), result)
            overrides = dict(overrides, **result)
    if not overrides:
        return partial
    return relabel(partial, overrides)

def aspect_step(target, ctx, ops, *, info):
    """The body of a packager's aspect implementation.

        def _my_aspect_impl(target, ctx):
            return [MyInfo(**runfiles_groups.aspect_step(target, ctx, _OPS, info = MyInfo))]

        my_aspect = aspect(
            implementation = _my_aspect_impl,
            attr_aspects = runfiles_groups.ATTR_ASPECTS,
            provides = [MyInfo],
        )

    For a target whose rule has a runfiles group describer, it materializes each
    entry the target adds, and merges in its attributes' partials -- by reference,
    unless the merge_from() spec renames or regroups them. With ops.dedup =
    "eager", shared groups that meet here under one name are forwarded once if
    identical and merged otherwise. For any other target it materializes the
    target's DefaultInfo as `fallback`, for parents to use.

    Args:
        target: The aspect's target.
        ctx: The aspect's ctx.
        ops: From runfiles_groups.packager_ops().
        info: The packager's own provider, whose fields are PACKAGER_INFO_FIELDS.

    Returns:
        A dict of PACKAGER_INFO_FIELDS values.
    """
    check_ops("runfiles_groups.aspect_step", ops)
    describer_target = getattr(ctx.rule.attr, "_runfiles_group_describer", None)
    node = None
    if describer_target != None:
        if RunfilesGroupDescriberInfo not in describer_target:
            fail("{} ({}): _runfiles_group_describer must point at a target of a rule made with runfiles_groups.make_describer_rule()".format(ctx.label, ctx.rule.kind))
        node = describer_target[RunfilesGroupDescriberInfo].describe(target, ctx)
        if node != None and (type(node) != STRUCT_TYPE or getattr(node, "marker", None) != NODE_MARKER):
            fail("{} ({}): the runfiles group describer must return runfiles_groups.node() or None, got {}".format(ctx.label, ctx.rule.kind, type(node)))
    if node == None:
        return {
            "owned": NO_PARTIALS,
            "shared": NO_PARTIALS,
            "fallback": _materialize(ctx, ops, synthesized_entry(ctx, target), ctx.label),
            "executable_group": None,
        }

    walked = getattr(ctx.rule.attr, "_runfiles_group_attrs", [])
    specs = node.merge_from
    if specs == None:
        specs = [make_merge_from(attr) for attr in walked]

    # A partial is owned when it is named by the Label of the target that
    # materialized it on itself: nothing else can produce that name, so owned
    # partials never collide and never need looking at. Everything else is shared.
    owned_direct = []
    owned_transitive = []
    shared_direct = []
    shared_transitive = []
    for entry in node.add:
        partial = _materialize(ctx, ops, entry, ctx.label)
        if entry.name == ctx.label:
            owned_direct.append(partial)
        else:
            shared_direct.append(partial)

    for spec in specs:
        if spec.attr not in walked:
            # On Bazel 9+ the aspect never visits such an attribute, so its targets
            # would silently carry no partials; on older versions it would work.
            fail("{} ({}): merge_from attribute '{}' is not in _runfiles_group_attrs {}".format(ctx.label, ctx.rule.kind, spec.attr, walked))
        value = getattr(ctx.rule.attr, spec.attr, None)
        if value == None:
            # An unset attr.label, or an attribute this Bazel version lacks.
            continue
        owned_in = []
        owned_in_transitive = []
        shared_in = []
        shared_in_transitive = []
        synthesize = spec.fallback == "synthesize"
        custom_fallback = spec.fallback if type(spec.fallback) == FUNCTION_TYPE else None
        for dep in attr_targets("runfiles_groups.aspect_step: attribute '{}'".format(spec.attr), [value]):
            dep_info = dep[info] if info in dep else None
            if dep_info != None and dep_info.fallback == None:
                # The dependency describes its groups.
                owned_in_transitive.append(dep_info.owned)
                shared_in_transitive.append(dep_info.shared)
            elif custom_fallback != None:
                # The ruleset synthesizes the group, here on the merging target. Every
                # parent of the dependency does the same, so the pieces are shared:
                # they can meet further up.
                entry = custom_fallback(ctx, dep)
                if entry != None:
                    check_entry("runfiles_groups.merge_from({}): fallback result".format(repr(spec.attr)), entry)
                    shared_in.append(_materialize(ctx, ops, entry, dep.label))
            elif synthesize:
                if dep_info != None:
                    # Materialized on the dependency itself, so still owned.
                    owned_in.append(dep_info.fallback)
                else:
                    # A file target: aspects never apply to one, so every parent
                    # synthesizes its own piece, and those can meet further up.
                    shared_in.append(_materialize(ctx, ops, synthesized_entry(ctx, dep), dep.label))
        if not spec.relabels:
            owned_direct.extend(owned_in)
            owned_transitive.extend(owned_in_transitive)
            shared_direct.extend(shared_in)
            shared_transitive.extend(shared_in_transitive)
            continue

        # Re-labeled copies are shared even when their name did not change: copies
        # re-labeled at different targets have to meet somewhere to be deduplicated.
        incoming = depset(owned_in + shared_in, transitive = owned_in_transitive + shared_in_transitive)
        for partial in incoming.to_list():
            shared_direct.append(_relabeled(partial, spec, ctx.label))

    return {
        "owned": _union_partials(owned_direct, owned_transitive),
        "shared": _shared_partials(ctx, ops, shared_direct, shared_transitive),
        "fallback": None,
        "executable_group": node.executable_group,
    }

def _union_partials(direct, transitive):
    """depset(direct, transitive = transitive), reusing a lone input by reference."""
    transitive = [partials for partials in transitive if partials]
    if not direct:
        if not transitive:
            return NO_PARTIALS
        if len(transitive) == 1:
            return transitive[0]
    return depset(direct, transitive = transitive)

def _shared_partials(ctx, ops, direct, transitive):
    """The shared depset of a target, deduplicated by name if ops.dedup is "eager".

    A target only flattens when two sources could carry the same name, and hands
    the union through by reference when no name actually collided.
    """
    union = _union_partials(direct, transitive)
    if ops.dedup != "eager" or not union:
        return union
    if not direct and len([partials for partials in transitive if partials]) <= 1:
        # A single source was deduplicated where it was built.
        return union

    by_name = {}
    collided = False
    for partial in union.to_list():
        parts = by_name.get(partial.name)
        if parts == None:
            by_name[partial.name] = [partial]
        else:
            # The flattened depset holds each value once, so this is a different
            # partial of the same name.
            parts.append(partial)
            collided = True
    if not collided:
        return union
    return depset([
        parts[0] if len(parts) == 1 else resolve_name(ctx, ops, name, parts)
        for name, parts in by_name.items()
    ])
