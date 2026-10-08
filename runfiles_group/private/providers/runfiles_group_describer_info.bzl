"""Defines RunfilesGroupDescriberInfo: how a rule describes its runfiles groups."""

_DOC = """\
Describes, for a packager's aspect, which runfiles a rule's targets add to which
groups and which attributes they merge runfiles in from.

A rule opts in with a private attribute, and optionally a second one:

    "_aspect_rule_hints": attr.label_list(default = [":my_rule_runfiles_group_describer"]),
    "_runfiles_group_attrs": attr.string_list(default = ["deps", "data"]),

where the describer target is an instance of a rule made with
runfiles_groups.make_describer_rule(describe = ...), and `_runfiles_group_attrs`
lists every attribute the aspect should walk into. Without it, the aspect walks
every attribute, and the describer names the ones to merge in from. Toolchain types the aspect
should walk into (declared in the rule's `toolchains`) are listed in
`_aspect_rule_hints` too, and merged in only through merge_from(toolchain = ...).
`_aspect_rule_hints` may also
hold helpers for other aspects; entries without RunfilesGroupDescriberInfo are
ignored, and at most one entry may carry it.

`describe(target, ctx)` is called by runfiles_groups.aspect_step() with the target
and the aspect's ctx (rule attributes are under ctx.rule). It returns
runfiles_groups.node(...), or None to opt out -- the target is then treated like a
rule without a describer, whose DefaultInfo becomes one synthesized group.

A describer only DESCRIBES: it should not register actions or build a depset that
combines its own runfiles with its dependencies'. That is the packager's job.

`describe` MUST be a module-level def: a nested function captures everything it
closes over for as long as the provider lives.
"""

RunfilesGroupDescriberInfo = provider(
    doc = _DOC,
    fields = {
        "describe": "A module-level function (target, ctx) -> runfiles_groups.node(...) or None.",
    },
)
