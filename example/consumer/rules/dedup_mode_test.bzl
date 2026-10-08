"""Checks that eager and root deduplication finalize to the same groups.

Two aspects run the same packager operations, one with dedup = "eager" and one
with dedup = "root". Their finalized groups must be identical -- names, metadata
and files -- and the eager one must actually have done its work during aspect
application: the root target's shared depset holds each group name at most once,
and the groups named in `merged` were already merged, from the expected number of
raw pieces, before finalize() ran.
"""

load("@rules_runfiles_group//runfiles_group:lib.bzl", "runfiles_groups")

_EagerInfo = provider(
    doc = "Runfiles groups, deduplicated during aspect application.",
    fields = runfiles_groups.PACKAGER_INFO_FIELDS,
)

_RootInfo = provider(
    doc = "Runfiles groups, deduplicated by finalize() only.",
    fields = runfiles_groups.PACKAGER_INFO_FIELDS,
)

def _materialize(_ctx, entry):
    return entry.content

def _merge(ctx, name, partials):
    # The contract every packager relies on: no raw piece reaches merge twice, so
    # concatenating the inputs never holds a file twice. Checked here directly,
    # because the merged partial's pieces -- a depset -- would hide a duplicate.
    seen = {}
    for partial in partials:
        for key in (partial.pieces.to_list() if partial.pieces else [(partial.contributor, partial.handle)]):
            if key in seen:
                fail("merge of group {} received piece {} twice".format(runfiles_groups.name_str(name), key[0]))
            seen[key] = True
    return runfiles_groups.union(ctx, [partial.handle for partial in partials])

_EAGER_OPS = runfiles_groups.packager_ops(materialize = _materialize, merge = _merge, dedup = "eager")
_ROOT_OPS = runfiles_groups.packager_ops(materialize = _materialize, merge = _merge, dedup = "root")

def _eager_aspect_impl(target, ctx):
    return [_EagerInfo(**runfiles_groups.aspect_step(target, ctx, _EAGER_OPS, info = _EagerInfo))]

def _root_aspect_impl(target, ctx):
    return [_RootInfo(**runfiles_groups.aspect_step(target, ctx, _ROOT_OPS, info = _RootInfo))]

_eager_aspect = aspect(
    implementation = _eager_aspect_impl,
    attr_aspects = runfiles_groups.ATTR_ASPECTS,
    provides = [_EagerInfo],
)

_root_aspect = aspect(
    implementation = _root_aspect_impl,
    attr_aspects = runfiles_groups.ATTR_ASPECTS,
    provides = [_RootInfo],
)

def _short_path(file):
    return file.short_path

def _signature(resolved):
    return [
        (
            runfiles_groups.name_str(group.name),
            group.kind,
            group.rank,
            group.do_not_merge,
            group.weight,
            group.merge_affinity,
            sorted([_short_path(f) for f in runfiles_groups.files(group.handle).to_list()]),
        )
        for group in resolved.groups
    ]

def _check_binary(ctx, binary):
    issues = []
    eager_info = binary[_EagerInfo]
    eager = runfiles_groups.finalize(ctx, eager_info, _EAGER_OPS, aspect_hints = [])
    root = runfiles_groups.finalize(ctx, binary[_RootInfo], _ROOT_OPS, aspect_hints = [])
    if _signature(eager) != _signature(root):
        issues.append("finalized groups differ:\n    eager: {}\n    root:  {}".format(_signature(eager), _signature(root)))
    if eager.executable_group != root.executable_group:
        issues.append("executable_group {} (eager) != {} (root)".format(eager.executable_group, root.executable_group))

    shared = {}
    for partial in eager_info.shared.to_list():
        name = runfiles_groups.name_str(partial.name)
        if name in shared:
            issues.append("eager shared depset holds group '{}' more than once".format(name))
        shared[name] = partial
    for name, pieces in ctx.attr.merged.items():
        partial = shared.get(name)
        if partial == None:
            issues.append("expected group '{}' in the eager shared depset; present: {}".format(name, sorted(shared.keys())))
        elif len(partial.pieces.to_list()) != int(pieces):
            issues.append("expected group '{}' to be merged from {} raw pieces during aspect application, got {}".format(name, pieces, len(partial.pieces.to_list())))
    return issues

def _dedup_mode_test_impl(ctx):
    sections = []
    for binary in ctx.attr.binaries:
        issues = _check_binary(ctx, binary)
        if issues:
            sections.append("Issues with {}:\n{}".format(binary.label, "\n".join(["    " + issue for issue in issues])))
    return [AnalysisTestResultInfo(success = not sections, message = "\n".join(sections))]

dedup_mode_test = rule(
    implementation = _dedup_mode_test_impl,
    attrs = {
        "binaries": attr.label_list(
            aspects = [_eager_aspect, _root_aspect],
            mandatory = True,
        ),
        "merged": attr.string_dict(
            doc = """\
Group name (canonical string form) -> number of raw pieces it must already have
been merged from in every binary's eager shared depset.
""",
        ),
    },
    analysis_test = True,
)
