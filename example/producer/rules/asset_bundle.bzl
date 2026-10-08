"""Implementation of the asset_bundle rule.

This is a deliberately tiny, standalone "ruleset" that has nothing to do with
Starlark. It exists to show two things: that runfiles groups coming from
*different* rulesets carry *different* merge affinities, and that two rulesets can
both name their per-target groups by Label without any risk of collision -- there
is no prefix to agree on, because a Label is already unique.
"""

load("@rules_runfiles_group//runfiles_group:lib.bzl", "runfiles_groups")

# This ruleset stamps its own module-style affinity on every group it emits.
_AFFINITY = "asset_bundle"

def _describe_asset_bundle_runfiles(target, ctx):
    return runfiles_groups.node(add = [runfiles_groups.entry(
        name = ctx.label,
        content = target[DefaultInfo].default_runfiles,
        kind = "first_party",
        rank = runfiles_groups.RANK_SHARED_DEPS,
        weight = ctx.rule.attr.weight if ctx.rule.attr.weight > 0 else None,
        merge_affinity = _AFFINITY,
    )])

asset_bundle_runfiles_group_describer = runfiles_groups.make_describer_rule(describe = _describe_asset_bundle_runfiles)

def _asset_bundle_impl(ctx):
    runfiles = ctx.runfiles(files = ctx.files.srcs)
    return [
        DefaultInfo(
            files = depset(ctx.files.srcs),
            runfiles = runfiles,
        ),
    ]

asset_bundle = rule(
    implementation = _asset_bundle_impl,
    attrs = {
        "srcs": attr.label_list(
            allow_files = True,
            doc = "Asset files bundled into this group.",
        ),
        "weight": attr.int(
            default = 0,
            doc = "Weight hint for this bundle's runfiles group. If > 0, set as the group entry's weight.",
        ),
        "_runfiles_group_describer": attr.label(default = Label(":asset_bundle_runfiles_group_describer")),
        "_runfiles_group_attrs": attr.string_list(default = []),
    },
)
