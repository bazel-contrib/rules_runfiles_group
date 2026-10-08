"""The packager side: packager_ops(), the identity packager and the aspect configuration."""

load("@bazel_features//:features.bzl", "bazel_features")
load("//runfiles_group/private/lib:constants.bzl", "FUNCTION_TYPE", "STRUCT_TYPE")
load("//runfiles_group/private/lib:content.bzl", "union_contents")

_DEDUP_MODES = ["eager", "root"]

def packager_ops(*, materialize, merge, dedup = "eager"):
    """The two operations that make a packager, and where it deduplicates.

    Both operations MUST be module-level defs. Both may register actions on the
    ctx they are given, and both return a *handle*: whatever the packager wants to
    carry for a group -- a tar File, a struct of Files, a depset, a runfiles
    object. Handles live inside depset elements, so they MUST be immutable: no
    lists, no dicts.

    Args:
        materialize: (ctx, entry) -> handle. Called by aspect_step() once per
            RunfilesGroupInfo a target adds, on the target that adds it, and once
            per synthesized group. It does not see the target: everything it may
            depend on is in the entry.
        merge: (ctx, name, partials) -> handle. Combines several partials into one
            group named `name`. The partials' coverages are pairwise disjoint --
            no raw piece reaches merge twice -- so concatenating their handles is
            correct; a packager that would rather rebuild can read every raw
            piece's handle from partial.pieces, a depset of (contributor, handle)
            (or use the partial itself, if it has none). Called
            for partials that share a name, and for groups merged to satisfy
            max_groups -- so it must not assume its inputs share a name.
        dedup: Where partials that share a group name are combined.
            "eager" (the default): on every target where they meet during aspect
            application. A target forwards a group once when its dependencies
            carry the identical partial, and merges different partials right
            there, so a layer is built where its pieces meet and reused by
            everything above. A target only flattens when it might have to merge,
            and forwards its dependencies' depsets unchanged when it did not.
            "root": never during aspect application. Everything travels by
            reference and runfiles_groups.finalize() combines it once, at the root.

    Returns:
        A struct for aspect_step() and finalize().
    """
    if type(materialize) != FUNCTION_TYPE:
        fail("runfiles_groups.packager_ops: materialize must be a function, got ", type(materialize))
    if type(merge) != FUNCTION_TYPE:
        fail("runfiles_groups.packager_ops: merge must be a function, got ", type(merge))
    if dedup not in _DEDUP_MODES:
        fail("runfiles_groups.packager_ops: dedup must be one of {}, got {}".format(_DEDUP_MODES, repr(dedup)))
    return struct(
        materialize = materialize,
        merge = merge,
        dedup = dedup,
    )

def _identity_materialize(_ctx, entry):
    return entry.content

def _identity_merge(ctx, _name, partials):
    return union_contents(ctx, [partial.handle for partial in partials])

IDENTITY_OPS = packager_ops(
    materialize = _identity_materialize,
    merge = _identity_merge,
)

# Pass to provider(fields = ...) for a packager's own provider, and fill it with
# MyInfo(**runfiles_groups.aspect_step(...)).
PACKAGER_INFO_FIELDS = {
    "owned": """\
depset of RunfilesGroupPartialInfo: per-target groups -- a group named by the
Label of the target that materialized it on itself.
""",
    "shared": """\
depset of RunfilesGroupPartialInfo: every other group reachable from this target:
named groups, groups a target re-labeled, and file targets a parent synthesized.
With dedup = "eager", each name appears at most once.
""",
    "fallback": """\
RunfilesGroupPartialInfo or None: for a target that does not describe its groups,
its DefaultInfo as one synthesized group. Parents use it where they merge with
fallback = "synthesize"; runfiles_groups.finalize() uses it for such a root.
""",
    "executable_group": "Label, str or None: this target's executable_group. Only the root's is used.",
}

def _propagation_filter(propagation_ctx):
    attrs = getattr(propagation_ctx.rule.attr, "_runfiles_group_attrs", None)
    if attrs == None:
        # The rule does not describe which of its attributes carry runfiles
        # groups, so the aspect stops here and the target is synthesized.
        return []
    return attrs.value

ATTR_ASPECTS = _propagation_filter if bazel_features.rules.aspect_propagation_context else ["*"]

def check_ctx(where, ctx):
    """Fails unless ctx is a rule or aspect context.

    Args:
        where: Call-site description for error messages.
        ctx: The value to check.
    """

    # A cheap guard with an expensive payoff: `where(source, aspect_hints = h)` --
    # the pre-ctx spelling of this call -- otherwise fails with "missing 1 required
    # positional argument: source", which points a migrating caller at the wrong
    # parameter. Nothing but a ctx carries a `runfiles` member.
    if not hasattr(ctx, "runfiles"):
        fail("{}: first argument must be the rule or aspect ctx, got {}".format(where, type(ctx)))

def check_ops(where, ops):
    if type(ops) != STRUCT_TYPE or not hasattr(ops, "materialize") or not hasattr(ops, "merge"):
        fail("{}: ops must come from runfiles_groups.packager_ops(), got {}".format(where, type(ops)))
