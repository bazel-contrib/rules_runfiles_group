"""The identity packager: groups whose handles are the runfiles contents themselves.

It is the reference implementation of a packager and the fixture runfiles_group_analysis_test
checks producers with. A packager that builds real artifacts follows the same shape with
its own provider and its own ops.
"""

load("//runfiles_group/private:lib.bzl", "runfiles_groups")

RunfilesGroupIdentityInfo = provider(
    doc = """\
The identity packager's view of a target's runfiles groups. Each partial's handle
is a runfiles content value: read it with runfiles_groups.files(handle) or
runfiles_groups.runfiles(ctx, handle).

Pass it to runfiles_groups.finalize(ctx, info, runfiles_groups.IDENTITY_OPS, ...).
""",
    fields = runfiles_groups.PACKAGER_INFO_FIELDS,
)

def _runfiles_groups_identity_aspect_impl(target, ctx):
    return [RunfilesGroupIdentityInfo(**runfiles_groups.aspect_step(
        target,
        ctx,
        runfiles_groups.IDENTITY_OPS,
        info = RunfilesGroupIdentityInfo,
    ))]

runfiles_groups_identity_aspect = aspect(
    implementation = _runfiles_groups_identity_aspect_impl,
    attr_aspects = runfiles_groups.ATTR_ASPECTS,
    provides = [RunfilesGroupIdentityInfo],
    doc = "Collects RunfilesGroupIdentityInfo from a target and everything its runfiles groups merge in.",
)
