"""Defines provider for transforming resolved runfiles groups.

This provider is intended for use as an aspect_hint on a target
to transform runfiles groups.
"""

_DOC = """\
Information about how to transform a target's resolved runfiles groups.

`transform` takes the value `runfiles_groups.finalize()` produced before limiting --
`struct(groups, by_name, executable_group)`, whose groups are
RunfilesGroupPartialInfo -- and returns a new one, built with
`runfiles_groups.resolved()`. Edit individual groups with
`runfiles_groups.derive()`. A transform that changes nothing should
`return resolved` unchanged.

It runs once per consuming target, after the partials have been flattened and
merged by name, so it is pure list and dict work. A transform has no `ctx` and no
access to the packager, so it can drop, rename, re-rank or otherwise re-label
groups, but it cannot create contents: a partial's handle is whatever the
packager's `materialize` or `merge` built, and is opaque to a transform.

    def _drop_docs(resolved):
        if not [e for e in resolved.groups if e.kind == "docs"]:
            return resolved
        return runfiles_groups.resolved(
            [e for e in resolved.groups if e.kind != "docs"],
            executable_group = resolved.executable_group,
        )

`transform` MUST be a module-level `def`, never a lambda or a nested function
created during analysis: a nested function captures a cell per free variable and
pins everything it closes over -- ctx, dep lists, dicts -- for as long as the
provider lives. A module-level def closes only over its module, which Bazel
already retains for the lifetime of the server.
"""

def _make_runfilestransforminfo_init(*, transform):
    if transform == None:
        fail("RunfilesGroupTransformInfo: transform must not be None")
    return {"transform": transform}

RunfilesGroupTransformInfo, _ = provider(
    doc = _DOC,
    init = _make_runfilestransforminfo_init,
    fields = {
        "transform": "A module-level Starlark function (resolved) -> resolved.",
    },
)
