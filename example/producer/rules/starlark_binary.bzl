"""Implementation of the starlark_binary rule."""

load("@hermetic_launcher//launcher:lib.bzl", "launcher")
load("@rules_runfiles_group//runfiles_group:lib.bzl", "runfiles_groups")
load("//producer/providers:providers.bzl", "StarlarkInfo")
load(
    ":starlark_runtime.bzl",
    "STARLARK_TOOLCHAIN_TYPE",
    "USE_STARLARK_TOOLCHAIN",
    "runtime_merge_from",
    "starlark_runtime",
    _AFFINITY = "AFFINITY",
    _GROUP_PREFIX = "GROUP_PREFIX",
)

_GROUP_ENTRYPOINT = _GROUP_PREFIX + "entrypoint"
_RUNTIME_MERGE_FROM = [
    runfiles_groups.merge_from(toolchain = STARLARK_TOOLCHAIN_TYPE),
] if USE_STARLARK_TOOLCHAIN else runtime_merge_from("_interpreter", "_standard_library")

_RUNTIME_ATTRS = {
    "_aspect_rule_hints": attr.label_list(default = [
        Label(":starlark_binary_runfiles_group_describer"),
        STARLARK_TOOLCHAIN_TYPE,
    ]),
    "_runfiles_group_attrs": attr.string_list(default = ["data", "deps"]),
} if USE_STARLARK_TOOLCHAIN else {
    "_aspect_rule_hints": attr.label_list(default = [Label(":starlark_binary_runfiles_group_describer")]),
    "_interpreter": attr.label(
        default = Label("//producer/interpreter"),
        executable = True,
        cfg = "target",
    ),
    "_runfiles_group_attrs": attr.string_list(default = ["data", "deps", "_interpreter", "_standard_library"]),
    "_standard_library": attr.label(
        default = "@std",
    ),
}

def _canonical_repo_name(ctx):
    return ctx.label.repo_name or "_main"

_ENTRYPOINT_OUTPUT_GROUP = "_starlark_runfiles_group_entrypoint"

def _describe_starlark_binary_runfiles(target, ctx):
    grouping = ctx.rule.attr.runfiles_grouping
    if grouping == "disabled":
        # Opt out: the packager treats this binary as one synthesized group.
        return None

    # What this binary ADDS: the launcher, the entrypoint source and the outputs of
    # its own actions.
    entrypoint_files = getattr(target[OutputGroupInfo], _ENTRYPOINT_OUTPUT_GROUP)

    # The grouping options exist here to demo what is possible.
    # A real implementation of "describe" doesn't need to regroup at all.
    if grouping == "by_target":
        # One group per transitive target, re-ranked relative to this binary.
        executable_group = _GROUP_ENTRYPOINT
        regroup = _rank_by_repo
    else:
        # One *named* group per repository, because many targets contribute to
        # each one. The entrypoint lands in this repository's group, where the
        # packager merges it with this repository's libraries.
        executable_group = _GROUP_PREFIX + _canonical_repo_name(ctx)
        regroup = _bucket_by_repo

    return runfiles_groups.node(
        add = [runfiles_groups.entry(
            name = executable_group,
            content = entrypoint_files,
            kind = "first_party",
            rank = runfiles_groups.RANK_EXECUTABLE,
            merge_affinity = _AFFINITY,
        )],
        merge_from = _RUNTIME_MERGE_FROM + [
            runfiles_groups.merge_from("deps", regroup = regroup),
            runfiles_groups.merge_from("data", fallback = "synthesize", regroup = regroup),
        ],
        executable_group = executable_group,
    )

starlark_binary_runfiles_group_describer = runfiles_groups.make_describer_rule(describe = _describe_starlark_binary_runfiles)

def _entry_repo(name):
    """Canonical repository name a group belongs to, or "" for the main repository."""
    if type(name) == "Label":
        return name.repo_name
    return ""

# Regroup functions run once per partial merged in from deps and data, so they are
# module-level defs and touch only metadata: the packager's handles pass through.

def _rank_by_repo(partial, owner):
    """by_target: re-ranks a group relative to this binary.

    First-party groups sit just below the executable, third-party groups anchor at
    the shared-deps rank.
    """
    if _entry_repo(partial.name) == owner.repo_name:
        return {"rank": runfiles_groups.RANK_EXECUTABLE - 1}
    return {"rank": runfiles_groups.RANK_SHARED_DEPS}

def _bucket_by_repo(partial, owner):
    """by_repo: rename every group to its repository's group."""
    repo = _entry_repo(partial.name)
    name = _GROUP_PREFIX + (repo or "_main")
    if repo == owner.repo_name:
        return {
            "name": name,
            "kind": "first_party",
            "rank": runfiles_groups.RANK_EXECUTABLE,
            "merge_affinity": _AFFINITY,
        }
    return {"name": name, "rank": runfiles_groups.RANK_SHARED_DEPS}

def _starlark_binary_impl(ctx):
    if USE_STARLARK_TOOLCHAIN:
        runtime = ctx.toolchains[STARLARK_TOOLCHAIN_TYPE].runtime
    else:
        runtime = starlark_runtime(ctx, ctx.attr._interpreter, ctx.attr._standard_library)
    interpreter_exe = runtime.interpreter
    entrypoint = ctx.file.src
    current_repo = _canonical_repo_name(ctx)

    # Collect repos from all deps + self + standard library
    transitive_repos = [dep[StarlarkInfo].repos for dep in ctx.attr.deps]
    all_repos = depset(
        [
            (ctx.attr.repository, current_repo),
            ("std", runtime.standard_library_repo),
        ],
        transitive = transitive_repos,
    )

    # Generate loadmap file
    loadmap = ctx.actions.declare_file(ctx.label.name + ".loadmap")
    output_args = ctx.actions.args()
    output_args.add("--output", loadmap)
    repo_args = ctx.actions.args()
    repo_args.set_param_file_format("multiline")
    repo_args.use_param_file("--repos=%s", use_always = True)
    repo_args.add_all(all_repos, map_each = _format_repo)

    ctx.actions.run(
        executable = ctx.executable._loadmap_generator,
        arguments = [output_args, repo_args],
        outputs = [loadmap],
        mnemonic = "StarlarkLoadmap",
        progress_message = "Generating loadmap for %{label}",
    )

    # Write properties file
    properties = ctx.actions.declare_file(ctx.label.name + ".properties.json")
    expanded_props = {}
    for k, v in ctx.attr.properties.items():
        expanded_props[k] = ctx.expand_location(v, ctx.attr.data)
    ctx.actions.write(properties, json.encode(expanded_props))

    # Build launcher stub: interpreter --repo <repo> --loadmap <loadmap> --properties <props> <entrypoint_label>
    if ctx.attr.repository:
        entry_label = "@" + ctx.attr.repository + "//" + entrypoint.owner.package + ":" + entrypoint.owner.name
    else:
        entry_label = "//" + entrypoint.owner.package + ":" + entrypoint.owner.name

    embedded_args, transformed_args = launcher.args_from_entrypoint(interpreter_exe)
    embedded_args, transformed_args = launcher.append_embedded_arg(
        arg = "--repo",
        embedded_args = embedded_args,
        transformed_args = transformed_args,
    )
    embedded_args, transformed_args = launcher.append_embedded_arg(
        arg = current_repo,
        embedded_args = embedded_args,
        transformed_args = transformed_args,
    )
    embedded_args, transformed_args = launcher.append_embedded_arg(
        arg = "--loadmap",
        embedded_args = embedded_args,
        transformed_args = transformed_args,
    )
    embedded_args, transformed_args = launcher.append_runfile(
        file = loadmap,
        embedded_args = embedded_args,
        transformed_args = transformed_args,
    )
    embedded_args, transformed_args = launcher.append_embedded_arg(
        arg = "--properties",
        embedded_args = embedded_args,
        transformed_args = transformed_args,
    )
    embedded_args, transformed_args = launcher.append_runfile(
        file = properties,
        embedded_args = embedded_args,
        transformed_args = transformed_args,
    )
    embedded_args, transformed_args = launcher.append_embedded_arg(
        arg = entry_label,
        embedded_args = embedded_args,
        transformed_args = transformed_args,
    )

    output = ctx.actions.declare_file(ctx.label.name)
    launcher.compile_stub(
        ctx = ctx,
        embedded_args = embedded_args,
        transformed_args = transformed_args,
        output_file = output,
        template_file = ctx.file._launcher,
    )

    # Runfiles: interpreter + entrypoint + loadmap + stdlib + data + all deps.
    entrypoint_files = depset([output, entrypoint, loadmap, properties])
    entrypoint_runfiles = ctx.runfiles(transitive_files = entrypoint_files)
    to_merge = [
        runtime.interpreter_runfiles,
        runtime.standard_library_runfiles,
    ]
    if ctx.files.data:
        to_merge.append(ctx.runfiles(files = ctx.files.data))
    to_merge.extend([dep[DefaultInfo].default_runfiles for dep in ctx.attr.deps])
    to_merge.extend([dep[DefaultInfo].default_runfiles for dep in ctx.attr.data])
    runfiles = entrypoint_runfiles.merge_all(to_merge)

    return [
        DefaultInfo(
            executable = output,
            runfiles = runfiles,
        ),
        OutputGroupInfo(**{_ENTRYPOINT_OUTPUT_GROUP: entrypoint_files}),
    ]

def _format_repo(repo_tuple):
    return repo_tuple[0] + "\0" + repo_tuple[1]

starlark_binary = rule(
    implementation = _starlark_binary_impl,
    executable = True,
    attrs = {
        "src": attr.label(
            allow_single_file = [".star", ".bzl"],
            mandatory = True,
            doc = "Starlark source file used as the entrypoint.",
        ),
        "deps": attr.label_list(
            providers = [StarlarkInfo],
            doc = "starlark_library targets providing source files.",
        ),
        "data": attr.label_list(
            allow_files = True,
            doc = "Data files available at runtime.",
        ),
        "properties": attr.string_dict(
            doc = "Key-value properties accessible via get_property() at runtime. Values support $(location) expansion.",
        ),
        "runfiles_grouping": attr.string(
            default = "by_repo",
            values = ["by_repo", "by_target", "disabled"],
            doc = "How to describe this binary's runfiles groups.",
        ),
        "repository": attr.string(
            default = "",
            doc = "Repository name for the load path. If empty, uses the main repo.",
        ),
        "_launcher": attr.label(
            default = "@hermetic_launcher//launcher/template:prebuilt",
            allow_single_file = True,
            cfg = "target",
        ),
        "_loadmap_generator": attr.label(
            default = Label("//producer/interpreter/loadmap"),
            executable = True,
            cfg = "exec",
        ),
    } | _RUNTIME_ATTRS,
    toolchains = [
        launcher.finalizer_toolchain_type,
    ] + ([STARLARK_TOOLCHAIN_TYPE] if USE_STARLARK_TOOLCHAIN else []),
)
