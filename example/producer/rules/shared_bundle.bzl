"""Implementation of the shared_bundle rule."""

load("@rules_runfiles_group//runfiles_group:lib.bzl", "runfiles_groups")

_AFFINITY = "shared_bundle"

def _describe_shared_bundle_runfiles(target, ctx):
    # A leaf: it adds to one group and merges nothing in.
    return runfiles_groups.node(add = [runfiles_groups.entry(
        # A *named* group, so it needs a ruleset prefix: unlike a Label, a string
        # shares one namespace with every other ruleset reachable from a binary.
        name = ctx.rule.attr.group_name,
        content = target[DefaultInfo].files if ctx.rule.attr.content_form == "files" else target[DefaultInfo].default_runfiles,
        kind = "docs",
        rank = ctx.rule.attr.rank,
        merge_affinity = _AFFINITY,
    )])

shared_bundle_runfiles_group_describer = runfiles_groups.make_describer_rule(describe = _describe_shared_bundle_runfiles)

def _shared_bundle_impl(ctx):
    return [
        DefaultInfo(
            files = depset(ctx.files.srcs, order = "topological"),
            runfiles = ctx.runfiles(files = ctx.files.srcs),
        ),
    ]

shared_bundle = rule(
    implementation = _shared_bundle_impl,
    attrs = {
        "srcs": attr.label_list(
            allow_files = True,
            doc = "Files this target contributes to the shared group.",
        ),
        "group_name": attr.string(
            mandatory = True,
            doc = "Name of the shared group. Several targets may use the same one.",
        ),
        "content_form": attr.string(
            default = "files",
            values = ["files", "runfiles"],
            doc = """\
Which of runfiles_groups.entry()'s two content forms to hand over: the depset of
File itself ("files", what a files-only group should do) or a runfiles object
wrapping it
("runfiles", what a group that carries symlinks or empty filenames has to do).

A real rule has no reason to make this configurable -- it knows which of the two it
is. It exists here so one example binary can be reached by both forms of the same
group.
""",
        ),
        "rank": attr.int(
            doc = "Rank of the shared group. Exists so the examples can rank a group above the executable.",
        ),
        "_runfiles_group_describer": attr.label(default = Label(":shared_bundle_runfiles_group_describer")),
        "_runfiles_group_attrs": attr.string_list(default = []),
    },
)
