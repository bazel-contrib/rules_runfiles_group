"""Library for describing, materializing and merging runfiles groups.

The protocol has three participants:

    RULES describe how runfiles are grouped. A rule opts in with a runfiles group describer (see
        RunfilesGroupDescriberInfo) that returns runfiles_groups.node(): the runfiles
        the target ITSELF adds, as RunfilesGroupInfo entries, and the attributes it
        merely merges runfiles in from.
    PACKAGERS build artifacts. A packager supplies two operations through
        runfiles_groups.packager_ops(): `materialize` turns one target's added
        runfiles into the packager's own artifact (a tar layer, say), and `merge`
        combines several of those into one. Work therefore happens at the node that
        owns the runfiles, and is shared by every consumer of that node.
    THIS LIBRARY connects them. runfiles_groups.aspect_step() is the body of a
        packager's aspect, and runfiles_groups.finalize() runs once at the root.
        The library does not ship a packager's aspect, because every packager needs
        its own provider: two aspects returning the same provider on one target
        collide. The identity packager (//runfiles_group:identity_packager.bzl)
        is the reference implementation.

GROUP NAMES come in two forms, because there are two kinds of group:

    a Label   -- a PER-TARGET group: "the runfiles this one target contributes".
                 Pass ctx.label for your own group, or dep.label for a dependency's.
                 Globally unique, so it needs no ruleset prefix.
    a string  -- a NAMED group that several targets contribute to: "interpreter",
                 "std", "third_party". Strings share one namespace across every
                 ruleset reachable from a binary, so prefix them with something
                 unique to your ruleset ("my_rules#interpreter").

Both forms are ordered, folded, merged and looked up the same way.

RULE SIDE -- inside a describer (target, ctx), with rule attributes under ctx.rule:

    runfiles_groups.entry(name, content, kind, rank, do_not_merge, weight, merge_affinity)
        Runfiles this target adds to one group. `content` is either a runfiles
        object or, for a group that is only files, the depset of File itself.
    runfiles_groups.merge_from(attr, fallback = , into = , regroup = , **metadata)
        Merge in the groups of the targets in one attribute. `fallback =
        "synthesize"` gives a dependency that does not describe itself one group
        holding its DefaultInfo; `into` renames every incoming group; `regroup` is
        a module-level def (partial, owner_label) -> dict of overrides, or None.
        Renaming and regrouping only touch metadata: the packager's artifacts pass
        through unchanged.
    runfiles_groups.node(add = , merge_from = , executable_group = )
        The final grouping for a single target and return value of the describer.
        `merge_from` takes attribute names or merge_from() values and defaults
        to every attribute in _runfiles_group_attrs.
    runfiles_groups.make_describer_rule(describe = )
        The rule whose single target a rule's _runfiles_group_describer points at.

PACKAGER SIDE:

    runfiles_groups.packager_ops(materialize = , merge = , dedup = )
        dedup = "eager" combines groups that share a name on the target where
        they meet during aspect application; "root" leaves it all to finalize().
    runfiles_groups.PACKAGER_INFO_FIELDS
        The fields of the packager's own provider.
    runfiles_groups.ATTR_ASPECTS
        The aspect's attr_aspects: Uses aspect propagation filter (Bazel 9+), "*" before that.
    runfiles_groups.aspect_step(target, ctx, ops, info = )
        The aspect implementation's body: MyInfo(**aspect_step(...)).
    runfiles_groups.finalize(ctx, info, ops, aspect_hints = , max_groups = ,
                             default_weight = , merged_group_name = )
        Flattens the partial groups, combines those that share a name,
        honors aspect hints (transforms), merges groups down to max_groups,
        and orders by (rank, name). Returns struct(groups, by_name, executable_group, group_count),
        whose groups are RunfilesGroupPartialInfo.
    runfiles_groups.limit(ctx, ops, resolved, max_groups = , default_weight = ,
                          merged_group_name = )
        finalize()'s max_groups step on its own, for a packager whose limit
        depends on finalize()'s result.
    runfiles_groups.IDENTITY_OPS
        The packager whose handle is the runfiles content itself, and whose merge
        is runfiles_groups.union(). Used for testing.
    runfiles_groups.resolved(groups, executable_group = ) / runfiles_groups.derive()
        What a RunfilesGroupTransformInfo transform returns, and how it edits a
        group's metadata.
    runfiles_groups.files(content) / runfiles_groups.runfiles(ctx, content) /
    runfiles_groups.union(ctx, contents)
        Read and combine runfiles content values (a depset of File or a runfiles
        object), e.g. an entry's content or an identity packager's handle.
    runfiles_groups.name_str() / group_names() / index_by_name_str()
        Naming helpers.

runfiles_groups.KINDS / runfiles_groups.DEFAULT_METADATA
    The closed set of `kind` values and the metadata a group has when its producer
    doesn't set it.

runfiles_groups.RANK_FOUNDATION / runfiles_groups.RANK_SHARED_DEPS /
runfiles_groups.RANK_EXECUTABLE
    Recommended rank anchors. Foundational content (runtimes, interpreters,
    standard libraries) anchors at RANK_FOUNDATION (-1000), shared third-party
    dependencies at RANK_SHARED_DEPS (-100), and the executable / first-party code
    at RANK_EXECUTABLE (0, the default). The anchors are spaced far apart so finer
    sub-tiers can be slotted in between. See the README for details.

runfiles_groups.RULE_ATTRS / runfiles_groups.is_enabled(ctx)
    Deprecated. The global on/off switch predates on-demand collection through an
    aspect, and nothing in the protocol reads it any more.
"""

load("//runfiles_group/private/lib:aspect_step.bzl", "aspect_step")
load("//runfiles_group/private/lib:constants.bzl", "RANK_EXECUTABLE", "RANK_FOUNDATION", "RANK_SHARED_DEPS")
load("//runfiles_group/private/lib:content.bzl", "content_files", "content_runfiles", "union_contents")
load("//runfiles_group/private/lib:describe.bzl", "make_describer_rule", "make_merge_from", "make_node")
load("//runfiles_group/private/lib:entry.bzl", "make_entry")
load("//runfiles_group/private/lib:finalize.bzl", "finalize")

# buildifier: disable=deprecated-function
load("//runfiles_group/private/lib:flag.bzl", "RULE_ATTRS", "is_enabled")
load("//runfiles_group/private/lib:limit.bzl", "limit")
load("//runfiles_group/private/lib:names.bzl", "group_names", "index_by_name_str", "name_str")
load(
    "//runfiles_group/private/lib:packager.bzl",
    "ATTR_ASPECTS",
    "IDENTITY_OPS",
    "PACKAGER_INFO_FIELDS",
    "packager_ops",
)
load("//runfiles_group/private/lib:partial.bzl", "derive")
load("//runfiles_group/private/lib:resolved.bzl", "resolved_groups")
load("//runfiles_group/private/providers:runfiles_group_info.bzl", "DEFAULT_METADATA", "KINDS")

runfiles_groups = struct(
    # rule side
    entry = make_entry,
    merge_from = make_merge_from,
    node = make_node,
    make_describer_rule = make_describer_rule,
    # packager side
    packager_ops = packager_ops,
    PACKAGER_INFO_FIELDS = PACKAGER_INFO_FIELDS,
    ATTR_ASPECTS = ATTR_ASPECTS,
    aspect_step = aspect_step,
    finalize = finalize,
    limit = limit,
    IDENTITY_OPS = IDENTITY_OPS,
    # transforms
    resolved = resolved_groups,
    derive = derive,
    # content and naming helpers
    files = content_files,
    runfiles = content_runfiles,
    union = union_contents,
    name_str = name_str,
    group_names = group_names,
    index_by_name_str = index_by_name_str,
    # entry metadata vocabulary
    KINDS = KINDS,
    DEFAULT_METADATA = DEFAULT_METADATA,
    # Recommended rank anchors (see README "Recommended rank values").
    RANK_FOUNDATION = RANK_FOUNDATION,
    RANK_SHARED_DEPS = RANK_SHARED_DEPS,
    RANK_EXECUTABLE = RANK_EXECUTABLE,
    # Deprecated global on/off switch (see //runfiles_group:enabled).
    RULE_ATTRS = RULE_ATTRS,
    is_enabled = is_enabled,
)
