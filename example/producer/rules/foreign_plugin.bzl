"""A rule from "somebody else's" ruleset that does not describe its runfiles groups.

Its DefaultInfo.files holds a build-only report next to the file the plugin needs at
runtime, while its runfiles hold only the latter. starlark_app synthesizes the
group from the runfiles instead (see its runtime_plugins attribute).
"""

def _foreign_plugin_impl(ctx):
    runtime = ctx.actions.declare_file(ctx.label.name + ".plugin.json")
    ctx.actions.write(runtime, json.encode({"name": ctx.label.name}))
    report = ctx.actions.declare_file(ctx.label.name + ".build_report.txt")
    ctx.actions.write(report, "built {}\n".format(ctx.label))
    return [DefaultInfo(
        files = depset([runtime, report]),
        runfiles = ctx.runfiles(files = [runtime]),
    )]

foreign_plugin = rule(
    implementation = _foreign_plugin_impl,
    doc = "A plugin whose outputs include a file it does not need at runtime.",
)
