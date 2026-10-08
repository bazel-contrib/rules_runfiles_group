"""Implementation of the starlark_toolchain rule."""

load("@rules_runfiles_group//runfiles_group:lib.bzl", "runfiles_groups")
load(":starlark_runtime.bzl", "runtime_merge_from", "starlark_runtime")

def _describe_starlark_toolchain_runfiles(_target, _ctx):
    return runfiles_groups.node(merge_from = runtime_merge_from("interpreter", "standard_library"))

starlark_toolchain_runfiles_group_describer = runfiles_groups.make_describer_rule(describe = _describe_starlark_toolchain_runfiles)

def _starlark_toolchain_impl(ctx):
    runtime = starlark_runtime(ctx, ctx.attr.interpreter, ctx.attr.standard_library)
    return [platform_common.ToolchainInfo(runtime = runtime)]

starlark_toolchain = rule(
    implementation = _starlark_toolchain_impl,
    attrs = {
        "interpreter": attr.label(
            mandatory = True,
            executable = True,
            cfg = "target",
            doc = "Starlark interpreter binary.",
        ),
        "standard_library": attr.label(
            mandatory = True,
            doc = "The standard library: a starlark_library.",
        ),
        "_aspect_rule_hints": attr.label_list(default = [Label(":starlark_toolchain_runfiles_group_describer")]),
        "_runfiles_group_attrs": attr.string_list(default = ["interpreter", "standard_library"]),
    },
)
