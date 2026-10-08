"""Consumer rule that packages a binary's runfiles groups via the identity packager."""

load("@rules_runfiles_group//runfiles_group:identity_packager.bzl", "RunfilesGroupIdentityInfo", "runfiles_groups_identity_aspect")
load("@rules_runfiles_group//runfiles_group:lib.bzl", "runfiles_groups")

_FakePackageHintsInfo = provider(
    doc = "The binary's aspect_hints, forwarded so the packaging rule can resolve groups.",
    fields = {"aspect_hints": "list of Target: the binary's aspect_hints."},
)

def _fake_package_aspect_impl(_target, ctx):
    return [_FakePackageHintsInfo(aspect_hints = ctx.rule.attr.aspect_hints)]

_fake_package_aspect = aspect(
    implementation = _fake_package_aspect_impl,
)

def _short_path(file):
    return file.short_path

def _fake_package_impl(ctx):
    binary = ctx.attr.binary
    hints = binary[_FakePackageHintsInfo].aspect_hints
    resolved = runfiles_groups.finalize(
        ctx,
        binary[RunfilesGroupIdentityInfo],
        runfiles_groups.IDENTITY_OPS,
        aspect_hints = hints,
    )

    # Write the manifest from an Args object rather than a string built during
    # analysis: json.encode(...) over every path materialized an O(all files)
    # string and ctx.actions.write stored it inside the action, retained for the
    # whole build. With Args, only the (already shared) nested sets are held and
    # the file is rendered at execution time.
    #
    # runfiles_groups.name_str renders either name form: a per-target group's Label
    # or a named group's string. before_each rather than format_each, because group
    # names are arbitrary strings and '%' is legal in a label, which would corrupt a
    # format template.
    # The identity packager's handles are runfiles contents, and
    # runfiles_groups.files() reads either content form, so this packager never has
    # to know whether a producer handed over a runfiles object or a bare depset. A
    # packager that has to place a complete runfiles tree -- symlinks, empty files
    # and all -- would call runfiles_groups.runfiles(ctx, group.handle) instead, and
    # would still not care which form it started from.
    args = ctx.actions.args()
    args.set_param_file_format("multiline")
    for group in resolved.groups:
        args.add_all(
            runfiles_groups.files(group.handle),
            before_each = "{}\t{}".format(group.kind, runfiles_groups.name_str(group.name)),
            map_each = _short_path,
            expand_directories = False,
        )

    manifest = ctx.actions.declare_file(ctx.label.name + ".manifest")
    ctx.actions.write(manifest, args)

    # Output group names have to be strings, so this is one of the places a
    # packager canonicalizes. A real packager would also put the launcher, the
    # runfiles symlinks and the repo mapping manifest into resolved.executable_group.
    output_groups = {}
    for group in resolved.groups:
        output_groups[runfiles_groups.name_str(group.name)] = runfiles_groups.files(group.handle)

    return [
        DefaultInfo(files = depset([manifest])),
        OutputGroupInfo(**output_groups),
    ]

fake_package = rule(
    implementation = _fake_package_impl,
    attrs = {
        "binary": attr.label(
            mandatory = True,
            aspects = [_fake_package_aspect, runfiles_groups_identity_aspect],
            doc = "A binary target. Its runfiles groups are used when it describes them.",
        ),
    },
)
