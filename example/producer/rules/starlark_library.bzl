"""Implementation of the starlark_library rule."""

load("@rules_runfiles_group//runfiles_group:lib.bzl", "runfiles_groups")
load("//producer/providers:providers.bzl", "StarlarkInfo")

# All groups produced by this ruleset share a single merge_affinity so that a
# packager forced to merge prefers to keep Starlark groups together (and,
# symmetrically, keeps other rulesets' groups together). Following the
# recommendation, this is the ruleset's identity; a real ruleset would use its
# module name (e.g. "rules_python"). Other modules may reuse this value to opt
# their runfiles groups into the same affinity.
_AFFINITY = "starlark"

def _describe_starlark_library_runfiles(target, ctx):
    own_weight = ctx.rule.attr.runfiles_weight if ctx.rule.attr.runfiles_weight > 0 else None
    own_affinity = ctx.rule.attr.merge_affinity if ctx.rule.attr.merge_affinity else _AFFINITY
    kind = "third_party" if ctx.rule.attr.repository else "first_party"

    group = ctx.rule.attr.runfiles_group
    if group:
        # One *named* group for this library and everything it reaches: its own
        # sources and its deps' and data's groups all go into it.
        # This exists for demo purposes and isn't needed for real implementations.
        return runfiles_groups.node(
            add = [runfiles_groups.entry(
                name = group,
                content = target[DefaultInfo].files,
                kind = kind,
                weight = own_weight,
                merge_affinity = own_affinity,
            )] if ctx.rule.files.srcs else [],
            merge_from = [
                runfiles_groups.merge_from("deps", into = group),
                runfiles_groups.merge_from("data", fallback = "synthesize", into = group),
            ],
        )

    return runfiles_groups.node(
        # What this library ADDS: its own sources, as a per-target group.
        add = [runfiles_groups.entry(
            name = ctx.label,
            content = target[DefaultInfo].files,
            kind = kind,
            weight = own_weight,
            merge_affinity = own_affinity,
        )],
        # What it merely MERGES IN. The two attributes are handled differently: a
        # `deps` target is another starlark_library, which describes itself, while
        # a `data` target can be anything: a rule that support runfiles groups, or one that doesn't.
        # In the latter case, "synthesize" generates a group for the data dependency on the fly.
        merge_from = [
            "deps",
            runfiles_groups.merge_from("data", fallback = "synthesize"),
        ],
    )

starlark_library_runfiles_group_describer = runfiles_groups.make_describer_rule(describe = _describe_starlark_library_runfiles)

def _canonical_repo_name(ctx):
    return ctx.label.repo_name or "_main"

def _starlark_library_impl(ctx):
    direct_srcs = ctx.files.srcs

    transitive_sources = [dep[StarlarkInfo].sources for dep in ctx.attr.deps]
    all_sources = depset(direct_srcs, transitive = transitive_sources)

    transitive_repos = [dep[StarlarkInfo].repos for dep in ctx.attr.deps]
    current_repo = _canonical_repo_name(ctx)
    repos = depset([(ctx.attr.repository, current_repo)], transitive = transitive_repos)

    if ctx.attr.repository:
        loadpath = "@" + ctx.attr.repository + "//" + ctx.label.package
    else:
        loadpath = "//" + ctx.label.package

    own_files = depset(direct_srcs)
    to_merge = [dep[DefaultInfo].default_runfiles for dep in ctx.attr.deps]
    to_merge.extend([dep[DefaultInfo].default_runfiles for dep in ctx.attr.data])
    if ctx.files.data:
        to_merge.append(ctx.runfiles(files = ctx.files.data))
    own_runfiles = ctx.runfiles(transitive_files = own_files)
    runfiles = own_runfiles.merge_all(to_merge) if to_merge else own_runfiles

    return [
        DefaultInfo(
            files = own_files,
            runfiles = runfiles,
        ),
        StarlarkInfo(
            sources = all_sources,
            loadpath = loadpath,
            repos = repos,
        ),
    ]

starlark_library = rule(
    implementation = _starlark_library_impl,
    attrs = {
        "srcs": attr.label_list(
            allow_files = [".star", ".bzl"],
            doc = "Starlark source files.",
        ),
        "deps": attr.label_list(
            providers = [StarlarkInfo],
            doc = "Other starlark_library targets.",
        ),
        "data": attr.label_list(
            allow_files = True,
            doc = "Data files available at runtime.",
        ),
        "repository": attr.string(
            default = "",
            doc = "Repository name for the load path. If empty, loadpath is '//package'. If set, loadpath is '@repository//package'.",
        ),
        "runfiles_weight": attr.int(
            default = 0,
            doc = "Weight hint for this library's runfiles group. If > 0, set as the group entry's weight.",
        ),
        "runfiles_group": attr.string(
            default = "",
            doc = """\
If set, a named runfiles group that this library's own sources and everything it
merges in from deps and data go into, instead of one per-target group each.

For a library that is always packaged as a whole -- a standard library, say --
this makes the library itself the place where its pieces are merged, so all
binaries share one layer for it. Prefix the name with something unique to your
ruleset, e.g. "starlark_runfiles_group#std".

Note: This exists for demo purposes. Real implementations don't need this.
""",
        ),
        "merge_affinity": attr.string(
            default = "",
            doc = """\
Overrides the merge_affinity of this library's runfiles group. If empty
(default), the group uses the ruleset-wide affinity ("starlark") so that all
Starlark groups prefer to merge together. Set this to share an affinity with
another ruleset (the recommendation is to use a module name, e.g. all
JVM-shaped libraries across modules could use "rules_java").
""",
        ),
        # These attributes signal support for runfiles groups.
        # Without them, a packager would synthesize a
        # coarse-grained group for all runfiles of this target
        # on the fly.
        "_runfiles_group_describer": attr.label(default = Label(":starlark_library_runfiles_group_describer")),
        "_runfiles_group_attrs": attr.string_list(default = ["data", "deps"]),
    },
)
