"""Implementation of the starlark_app rule.

A pluggable application: it composes libraries reached through *five* dependency
attributes, one of each Label-typed attribute kind Bazel offers, because each one
has to say something different:

    main              attr.label                    exactly one entry library
    deps              attr.label_list               plain libraries
    plugins           attr.string_keyed_label_dict  runtime id -> plugin library
    pinned_versions   attr.label_keyed_string_dict  library -> pinned version
    optional_features attr.label_list_dict          feature name -> libraries

All five are *dependency* attributes, so the runfiles group describer merges in
from all five, and the packager's aspect finds the Targets in each of them
whatever shape it has. The ids, versions and feature names are not decoration:
they are written into the app's registry manifest, which is what makes the dict
kinds the right shape rather than a demonstration of them.

`data` is merged in differently: a data target that does not describe its runfiles
groups gets one synthesized for it, where a dependency attribute's target that does
not contributes nothing. See runfiles_groups.merge_from().

attr.label_list_dict is Bazel 9 and newer. On older versions the rule drops
`optional_features` (see _EXTRA_ATTRS below) rather than lose the rest of the
demonstration.
"""

load("@rules_runfiles_group//runfiles_group:lib.bzl", "runfiles_groups")
load("//producer/providers:providers.bzl", "StarlarkInfo")

# Same ruleset-wide affinity as starlark_library/starlark_binary: an app's own
# group belongs with the rest of the Starlark groups under merge pressure.
_AFFINITY = "starlark"

# attr.label_list_dict arrived in Bazel 9. Probing for it keeps this example
# loadable on 7 and 8, where the rule simply has no `optional_features`
# attribute -- and the macro below drops what a BUILD file passes for it, so one
# BUILD file works on every version.
HAS_LABEL_LIST_DICT = hasattr(attr, "label_list_dict")

_EXTRA_ATTRS = {
    "optional_features": attr.label_list_dict(
        providers = [StarlarkInfo],
        doc = "Feature name -> the libraries that implement it.",
    ),
} if HAS_LABEL_LIST_DICT else {}

_DEP_ATTRS = ["main", "deps", "plugins", "pinned_versions"] + (["optional_features"] if HAS_LABEL_LIST_DICT else [])

def _runtime_plugin_entry(_ctx, dep):
    runfiles = dep[DefaultInfo].default_runfiles
    if not runfiles.files and not runfiles.symlinks and not runfiles.root_symlinks:
        return None
    return runfiles_groups.entry(name = dep.label, content = runfiles)

def _describe_starlark_app_runfiles(target, ctx):
    return runfiles_groups.node(
        # The app's own file, the registry, as a per-target group.
        add = [runfiles_groups.entry(
            name = ctx.label,
            content = target[DefaultInfo].files,
            kind = "first_party",
            merge_affinity = _AFFINITY,
        )],
        # A library reached through two of these attributes -- a plugin that is
        # also a plain dep, say -- is one aspect node, so its partials arrive
        # twice by reference and the depset collapses them.
        merge_from = _DEP_ATTRS + [
            runfiles_groups.merge_from("data", fallback = "synthesize"),
            # A runtime plugin contributes its runfiles and nothing else, so the
            # generic fallback -- which also claims DefaultInfo.files -- would put
            # files in a group that the app's runfiles never got. The ruleset knows
            # better and synthesizes the group itself.
            runfiles_groups.merge_from("runtime_plugins", fallback = _runtime_plugin_entry),
        ],
    )

starlark_app_runfiles_group_describer = runfiles_groups.make_describer_rule(describe = _describe_starlark_app_runfiles)

def _loadpath(target):
    return target[StarlarkInfo].loadpath

def _starlark_app_impl(ctx):
    optional_features = getattr(ctx.attr, "optional_features", {})

    dep_targets = [ctx.attr.main] + ctx.attr.deps + ctx.attr.plugins.values() + ctx.attr.pinned_versions.keys()
    for targets in optional_features.values():
        dep_targets += targets

    registry = ctx.actions.declare_file(ctx.label.name + ".registry.json")
    ctx.actions.write(registry, json.encode(struct(
        main = _loadpath(ctx.attr.main),
        deps = [_loadpath(dep) for dep in ctx.attr.deps],
        plugins = {plugin_id: _loadpath(dep) for plugin_id, dep in ctx.attr.plugins.items()},
        pinned = {str(dep.label): version for dep, version in ctx.attr.pinned_versions.items()},
        features = {
            feature: [_loadpath(dep) for dep in targets]
            for feature, targets in optional_features.items()
        },
    )))
    own_files = depset([registry])
    to_merge = [dep[DefaultInfo].default_runfiles for dep in dep_targets]
    to_merge.extend([dep[DefaultInfo].default_runfiles for dep in ctx.attr.data])
    to_merge.extend([dep[DefaultInfo].default_runfiles for dep in ctx.attr.runtime_plugins])
    if ctx.files.data:
        to_merge.append(ctx.runfiles(files = ctx.files.data))
    own_runfiles = ctx.runfiles(transitive_files = own_files)

    return [
        DefaultInfo(
            files = own_files,
            runfiles = own_runfiles.merge_all(to_merge),
        ),
        StarlarkInfo(
            sources = depset(transitive = [dep[StarlarkInfo].sources for dep in dep_targets]),
            loadpath = "//" + ctx.label.package,
            repos = depset(transitive = [dep[StarlarkInfo].repos for dep in dep_targets]),
        ),
    ]

_starlark_app = rule(
    implementation = _starlark_app_impl,
    attrs = dict({
        "main": attr.label(
            providers = [StarlarkInfo],
            mandatory = True,
            doc = "The app's entry library. Exactly one, so attr.label.",
        ),
        "deps": attr.label_list(
            providers = [StarlarkInfo],
            doc = "Libraries the app always loads.",
        ),
        "plugins": attr.string_keyed_label_dict(
            providers = [StarlarkInfo],
            doc = "Runtime plugin id -> the library implementing it.",
        ),
        "pinned_versions": attr.label_keyed_string_dict(
            providers = [StarlarkInfo],
            doc = "Vendored library -> the version recorded for it in the registry.",
        ),
        "data": attr.label_list(
            allow_files = True,
            doc = "Data files available at runtime.",
        ),
        "_runfiles_group_describer": attr.label(default = Label(":starlark_app_runfiles_group_describer")),
        "runtime_plugins": attr.label_list(
            doc = "Targets of any rule whose runfiles, but not their outputs, the app needs at runtime.",
        ),
        "_runfiles_group_attrs": attr.string_list(default = _DEP_ATTRS + ["data", "runtime_plugins"]),
    }, **_EXTRA_ATTRS),
)

def starlark_app(name, optional_features = None, **kwargs):
    """Assembles a pluggable Starlark app from its libraries.

    A macro only so that a BUILD file can pass `optional_features` on every Bazel
    version: attr.label_list_dict, the kind that attribute needs, is Bazel 9 and
    newer, and on older versions the feature libraries are dropped.

    Args:
        name: Target name.
        optional_features: Feature name -> the libraries implementing it. Ignored
            on Bazel 8 and older.
        **kwargs: The rule's other attributes.
    """
    if optional_features and HAS_LABEL_LIST_DICT:
        kwargs["optional_features"] = optional_features
    _starlark_app(name = name, **kwargs)
