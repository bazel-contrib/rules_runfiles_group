"""Implementation of the plain_binary rule.

A binary that merges in its data without re-labeling it, so each group keeps the
rank its producer gave it -- including a rank above the executable's. Its own
group is named by its Label, so by (rank, name) alone it sorts first at its rank.
That makes it the fixture for finalize()'s executable_group_last.
"""

load("@rules_runfiles_group//runfiles_group:lib.bzl", "runfiles_groups")

def _describe_plain_binary_runfiles(target, ctx):
    return runfiles_groups.node(
        add = [runfiles_groups.entry(
            name = ctx.label,
            content = depset([target[DefaultInfo].files_to_run.executable]),
            kind = "first_party",
        )],
        merge_from = [runfiles_groups.merge_from("data", fallback = "synthesize")],
        executable_group = ctx.label,
    )

plain_binary_runfiles_group_describer = runfiles_groups.make_describer_rule(describe = _describe_plain_binary_runfiles)

def _plain_binary_impl(ctx):
    exe = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.write(exe, "#!/bin/sh\n", is_executable = True)
    runfiles = ctx.runfiles(files = [exe] + ctx.files.data)
    for dep in ctx.attr.data:
        runfiles = runfiles.merge(dep[DefaultInfo].default_runfiles)
    return [DefaultInfo(executable = exe, runfiles = runfiles)]

plain_binary = rule(
    implementation = _plain_binary_impl,
    attrs = {
        "data": attr.label_list(allow_files = True),
        "_runfiles_group_describer": attr.label(default = Label(":plain_binary_runfiles_group_describer")),
        "_runfiles_group_attrs": attr.string_list(default = ["data"]),
    },
    executable = True,
)
