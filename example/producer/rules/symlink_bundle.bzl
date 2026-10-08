"""Implementation of the symlink_bundle rule.

A bundle whose runfiles are carried by symlinks and root symlinks rather than by
plain files. It is the fixture for runfiles_group_analysis_test comparing symlink
entries by their path and target rather than by object identity.

The runfiles object a group carries is rebuilt by the describer, not taken from
DefaultInfo, so the group and default_runfiles describe the same symlinks through
distinct SymlinkEntry objects -- as any packager that re-creates runfiles does.
"""

load("@rules_runfiles_group//runfiles_group:lib.bzl", "runfiles_groups")

def _symlink_runfiles(ctx, files):
    return ctx.runfiles(
        symlinks = {"links/" + f.basename: f for f in files},
        root_symlinks = {"root_links/" + f.basename: f for f in files},
    )

def _describe_symlink_bundle_runfiles(target, ctx):
    return runfiles_groups.node(add = [runfiles_groups.entry(
        name = ctx.label,
        content = _symlink_runfiles(ctx, ctx.rule.files.srcs),
        kind = "first_party",
    )])

symlink_bundle_runfiles_group_describer = runfiles_groups.make_describer_rule(describe = _describe_symlink_bundle_runfiles)

def _symlink_bundle_impl(ctx):
    return [DefaultInfo(runfiles = _symlink_runfiles(ctx, ctx.files.srcs))]

symlink_bundle = rule(
    implementation = _symlink_bundle_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = True),
        "_aspect_rule_hints": attr.label_list(default = [Label(":symlink_bundle_runfiles_group_describer")]),
        "_runfiles_group_attrs": attr.string_list(default = []),
    },
)
