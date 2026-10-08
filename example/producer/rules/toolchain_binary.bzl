"""Implementation of the toolchain_binary rule."""

load("@rules_runfiles_group//runfiles_group:lib.bzl", "runfiles_groups")

_RUNTIME = Label("//producer/toolchains:runtime_toolchain_type")
_TOOL = Label("//producer/toolchains:tool_toolchain_type")
_MISSING = Label("//producer/toolchains:missing_toolchain_type")

def _describe_toolchain_binary_runfiles(target, ctx):
    return runfiles_groups.node(
        add = [runfiles_groups.entry(
            name = ctx.label,
            content = depset([target[DefaultInfo].files_to_run.executable]),
            kind = "first_party",
        )],
        merge_from = [
            runfiles_groups.merge_from(toolchain = _RUNTIME),
            runfiles_groups.merge_from(toolchain = _TOOL, fallback = "synthesize"),
            runfiles_groups.merge_from(toolchain = _MISSING),
        ],
        executable_group = ctx.label,
    )

toolchain_binary_runfiles_group_describer = runfiles_groups.make_describer_rule(describe = _describe_toolchain_binary_runfiles)

def _toolchain_binary_impl(ctx):
    exe = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.write(exe, "#!/bin/sh\n", is_executable = True)
    runfiles = ctx.runfiles(files = [exe])
    for toolchain_type in [_RUNTIME, _TOOL, _MISSING]:
        toolchain = ctx.toolchains[toolchain_type]
        if toolchain != None:
            runfiles = runfiles.merge(toolchain.runfiles)
    return [DefaultInfo(executable = exe, runfiles = runfiles)]

toolchain_binary = rule(
    implementation = _toolchain_binary_impl,
    attrs = {
        "_aspect_rule_hints": attr.label_list(default = [
            Label(":toolchain_binary_runfiles_group_describer"),
            _RUNTIME,
            _TOOL,
            _MISSING,
        ]),
        "_runfiles_group_attrs": attr.string_list(default = []),
    },
    toolchains = [
        _RUNTIME,
        _TOOL,
        config_common.toolchain_type(_MISSING, mandatory = False),
    ],
    executable = True,
)
