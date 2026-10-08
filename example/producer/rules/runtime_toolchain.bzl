"""Implementation of the runtime_toolchain and plain_toolchain rules."""

load("@rules_runfiles_group//runfiles_group:lib.bzl", "runfiles_groups")

def _describe_runtime_toolchain_runfiles(target, _ctx):
    return runfiles_groups.node(add = [runfiles_groups.entry(
        name = "example#runtime",
        content = target[DefaultInfo].default_runfiles,
        kind = "foundation",
        rank = runfiles_groups.RANK_FOUNDATION,
    )])

runtime_toolchain_runfiles_group_describer = runfiles_groups.make_describer_rule(describe = _describe_runtime_toolchain_runfiles)

def _toolchain_impl(ctx):
    runfiles = ctx.runfiles(files = ctx.files.srcs)
    return [
        DefaultInfo(runfiles = runfiles),
        platform_common.ToolchainInfo(runfiles = runfiles),
    ]

runtime_toolchain = rule(
    implementation = _toolchain_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = True),
        "_aspect_rule_hints": attr.label_list(default = [Label(":runtime_toolchain_runfiles_group_describer")]),
        "_runfiles_group_attrs": attr.string_list(default = []),
    },
)

plain_toolchain = rule(
    implementation = _toolchain_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = True),
    },
)
