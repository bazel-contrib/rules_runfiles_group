"""Public API for packagers that consume runfiles groups through an aspect.

This is the subset of //runfiles_group:lib.bzl a packager needs in order to build
its aspect. It has nothing for describing groups; see //runfiles_group:describe.bzl
for that.

    packager.packager_ops(materialize = , merge = , dedup = )
        The two operations a packager supplies: `materialize` turns one target's
        added runfiles into the packager's own artifact, and `merge` combines
        several of those into one.
    packager.PACKAGER_INFO_FIELDS
        The fields of the packager's own provider.
    packager.ATTR_ASPECTS / packager.TOOLCHAINS_ASPECTS
        The aspect's attr_aspects and toolchains_aspects. Bazel 7 has no
        toolchains_aspects parameter: pass it only when non-empty.
    packager.aspect_step(target, ctx, ops, info = )
        The aspect implementation's body: MyInfo(**aspect_step(...)).
    packager.finalize(ctx, info, ops, aspect_hints = , max_groups = ,
                      default_weight = , merged_group_name = )
        Runs once at the root: flattens, combines, transforms, limits and orders.
    packager.limit(ctx, ops, resolved, max_groups = , default_weight = , merged_group_name = )
        finalize()'s max_groups step on its own.
    packager.IDENTITY_OPS
        The packager whose handle is the runfiles content itself. Used for testing.
    packager.resolved(groups, executable_group = ) / packager.derive()
        What a RunfilesGroupTransformInfo transform returns, and how it edits a
        group's metadata.
    packager.files(content) / packager.runfiles(ctx, content) / packager.union(ctx, contents)
        Read and combine runfiles content values.
    packager.name_str() / group_names() / index_by_name_str()
        Naming helpers.
    packager.KINDS / packager.DEFAULT_METADATA
        The closed set of `kind` values and the default group metadata.

See //runfiles_group:lib.bzl for the full description of the protocol and of group names.
"""

load("//runfiles_group/private/lib:aspect_step.bzl", "aspect_step")
load("//runfiles_group/private/lib:content.bzl", "content_files", "content_runfiles", "union_contents")
load("//runfiles_group/private/lib:finalize.bzl", "finalize")
load("//runfiles_group/private/lib:limit.bzl", "limit")
load("//runfiles_group/private/lib:names.bzl", "group_names", "index_by_name_str", "name_str")
load(
    "//runfiles_group/private/lib:packager.bzl",
    "ATTR_ASPECTS",
    "IDENTITY_OPS",
    "PACKAGER_INFO_FIELDS",
    "TOOLCHAINS_ASPECTS",
    "packager_ops",
)
load("//runfiles_group/private/lib:partial.bzl", "derive")
load("//runfiles_group/private/lib:resolved.bzl", "resolved_groups")
load("//runfiles_group/private/providers:runfiles_group_info.bzl", "DEFAULT_METADATA", "KINDS")

packager = struct(
    packager_ops = packager_ops,
    PACKAGER_INFO_FIELDS = PACKAGER_INFO_FIELDS,
    ATTR_ASPECTS = ATTR_ASPECTS,
    TOOLCHAINS_ASPECTS = TOOLCHAINS_ASPECTS,
    aspect_step = aspect_step,
    finalize = finalize,
    limit = limit,
    IDENTITY_OPS = IDENTITY_OPS,
    resolved = resolved_groups,
    derive = derive,
    files = content_files,
    runfiles = content_runfiles,
    union = union_contents,
    name_str = name_str,
    group_names = group_names,
    index_by_name_str = index_by_name_str,
    KINDS = KINDS,
    DEFAULT_METADATA = DEFAULT_METADATA,
)
