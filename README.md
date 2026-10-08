# rules_runfiles_group

A Bazel module that lets `*_binary` rules split their runfiles into named **groups**, and lets
packaging rules consume those groups as partially ordered **layers**. Where a binary's ruleset
describes its groups, a packager can produce better artifacts — container images with shared base
layers, archives that keep interpreter, standard library and application code apart — instead of
packing one flat runfiles tree.

```starlark
load("@rules_foo//foo:defs.bzl", "foo_binary")
load("@rules_acme_pkg//pkg:defs.bzl", "pkg_creator")

foo_binary(
    name = "app",
    # rules_foo describes groups like "interpreter", "stdlib",
    # "third_party", "app_code" -- or one per dependency.
    ...
)

pkg_creator(
    name = "app_tar",
    binary = ":app",
    # Walks the binary's graph with an aspect, builds one layer per group
    # where the group's runfiles are, merges groups down to a limit,
    # orders them, and emits one package per group.
)
```

Rules only **describe**: which runfiles a target adds itself, and which attributes it merges
runfiles in from. Packagers **build**: their aspect turns each target's own runfiles into an
artifact — a tar layer, say — on that target, where it is shared by every binary that reaches it.

Nothing about this is mandatory on either side. A packager that meets a target whose rule does not
describe its groups packages its `DefaultInfo` as a single group.

**Who should read what:** users → [For users](#for-users). Authors of `*_binary` and `*_library`
rules → [For rule authors](#for-rule-authors). Authors of packaging rules →
[For packaging rule authors](#for-packaging-rule-authors).

## Installation

Add the module to your `MODULE.bazel`, taking the version from the
[releases page](https://github.com/bazel-contrib/rules_runfiles_group/releases):

```starlark
bazel_dep(name = "rules_runfiles_group", version = "…")
```

Tested against Bazel 7, 8, 9 and rolling.

## The providers

| Provider | Returned by | Purpose |
|----------|-------------|---------|
| `DefaultInfo` | every rule | The executable and runfiles tree. The fallback for targets that do not describe their groups. |
| `RunfilesGroupDescriberInfo` | the `_runfiles_group_describer` attribute of participating rules | Holds the function that describes a rule's groups. |
| `RunfilesGroupInfo` | a describer, in `runfiles_groups.node(add = ...)` | Runfiles a target adds to one group, with ordering and merge metadata. |
| `RunfilesGroupPartialInfo` | a packager's aspect | One target's piece of a group, materialized by the packager. |
| `RunfilesGroupTransformInfo` | an `aspect_hints` target | Transforms the finalized group set (drop a group, remap names, re-rank). |

The full API reference is generated from the docstrings in
[`runfiles_group/lib.bzl`](runfiles_group/lib.bzl),
[`runfiles_group/providers.bzl`](runfiles_group/providers.bzl) and
[`runfiles_group/identity_packager.bzl`](runfiles_group/identity_packager.bzl). The
[`example/`](example/) directory is a complete end-to-end demo:
[`example/producer/`](example/producer/) implements `*_library` and `*_binary` rules,
[`example/consumer/`](example/consumer/) packaging rules, and
[`example/src/`](example/src/) holds user-facing `BUILD` files.

---

## For users

**It just works.** You can package any `*_binary`. If its ruleset doesn't describe runfiles groups,
packaging rules use the flat runfiles from `DefaultInfo`. If it does, you get smarter layer
splitting with no change to your `BUILD` files.

**Customizing groups with `aspect_hints`.** Rulesets may ship hint targets as mixins that adjust
how groups are transformed — for example, one that drops the interpreter group because the base
image already has it:

```starlark
load("@rules_foo//foo:hints.bzl", "skip_interpreter")

skip_interpreter(name = "skip_interpreter")

foo_binary(
    name = "app",
    aspect_hints = [":skip_interpreter"],
    ...
)
```

Hints work by attaching `RunfilesGroupTransformInfo`, which packaging rules pick up through an
aspect; several can be combined on one target. See [the finalize step](#the-finalize-step).

---

## For rule authors

If splitting runfiles isn't meaningful for your rule — a single statically linked executable, say —
do nothing; packagers fall back to `DefaultInfo`. If it is (interpreter, standard library,
`data` attribute, first-party code, third-party deps, debug symbols), give your rules a runfiles group describer.

### Opting in

A rule opts in with two private attributes: the describer target, and the attributes a packager's
aspect should walk into.

```starlark
load("@rules_runfiles_group//runfiles_group:lib.bzl", "runfiles_groups")

def _describe_foo_library_runfiles(target, ctx):
    ...  # see below

foo_library_runfiles_group_describer = runfiles_groups.make_describer_rule(
    describe = _describe_foo_library_runfiles,
)

foo_library = rule(
    implementation = _foo_library_impl,
    attrs = {
        ...
        "_runfiles_group_describer": attr.label(default = Label("//foo:foo_library_runfiles_group_describer"), provides = [RunfilesGroupDescriberInfo]),
        "_runfiles_group_attrs": attr.string_list(default = ["deps", "data"]),
    },
)
```

and instantiate the describer rule once, next to the rule:

```starlark
foo_library_runfiles_group_describer(
    name = "foo_library_runfiles_group_describer",
    visibility = ["//visibility:public"],
)
```

The describer is called by a packager's aspect with the target and the aspect's `ctx`, so rule
attributes are under `ctx.rule.attr`.

### Writing the describer

A describer returns `runfiles_groups.node()`, which keeps two things **separate**:

```starlark
def _describe_foo_library_runfiles(target, ctx):
    return runfiles_groups.node(
        # What this target ADDS: its own sources, its own actions' outputs.
        add = [runfiles_groups.entry(
            name = ctx.label,  # a per-target group
            content = target[DefaultInfo].files,
            kind = "first_party",
            merge_affinity = "rules_foo",
        )],
        # What it merely MERGES IN, by attribute.
        merge_from = [
            "deps",
            runfiles_groups.merge_from("data", fallback = "synthesize"),
        ],
    )
```

Never put a dependency's runfiles into `add`. The list of `add`-ed groups is used to describe runfiles groups added by the current target.
This may include things like `srcs` of the target (for interpreted languages), or file generated by the target's actions.
The `merge_from` list contains the attributes from which the current target merges runfiles into it's own runfiles obect.
Keeping the two apart is important. This allows a packager to build artifacts incrementally as part of the aspect application.
`merge_from` defaults to every attribute in `_runfiles_group_attrs`; every attribute
it names must be listed there, because that list is what the aspect walks.

A describer may return `None` to opt out for one target. The target is then packaged as one synthesized group.

### Creating entries

`runfiles_groups.entry()` is the only supported constructor for `RunfilesGroupInfo`; it validates
every field.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `name` | Label or str | — | The group's identity — see [Naming groups](#naming-groups). |
| `content` | depset of File, or runfiles | — | The runfiles this target adds — see [The two content forms](#the-two-content-forms). |
| `kind` | str | `""` | One of `runfiles_groups.KINDS`. A stable, machine-readable selector for packagers. Does **not** affect ordering or merging. |
| `rank` | int | `0` | Partial ordering key. Lower rank = earlier in the output. Groups at different ranks are never merged. |
| `do_not_merge` | bool | `False` | If True, packagers must not merge this group with another. |
| `weight` | int >= 0 or None | `None` | Merge priority hint. Lighter groups merge first when reducing group count. `None` lets the packager pick a default. |
| `merge_affinity` | str | `""` | Merge grouping hint: groups sharing an affinity are preferred merge partners. `""` means no affinity. |

### The two content forms

A group's contents are either a **depset of File** or a **runfiles object**. Choose whichever best matches the subset of outputs a target produces.
If you already have a runfiles object or depset with the correct contents for other purposes, reusing it is the cheapest option.

**A depset of File** means "this group is only files". Most `*_library` groups are: symlinks, root
symlinks and empty filenames are things interpreters and launchers need, not source trees. Hand over
the depset your rule already built — `target[DefaultInfo].files`, often.

**A runfiles object** is the general form, and the only one that can carry symlinks, root symlinks or
empty filenames. Use it for those, and for contents you received from another rule — do not flatten
an existing runfiles object to decide whether it could have been a depset.

Packagers can handle either form using helper methods:

```starlark
runfiles_groups.files(content)          # returns depset of File for either input
runfiles_groups.runfiles(ctx, content)  # returns a runfiles object for either input
runfiles_groups.union(ctx, contents)    # several contents as one
```

### Merging in from attributes

`runfiles_groups.merge_from(attr, ...)` describes one attribute. Every Label-typed attribute kind
is accepted, whatever shape `ctx.rule.attr` gives it:

| Attribute kind | `ctx.rule.attr` value |
|----------------|------------------|
| `attr.label` | a `Target` |
| `attr.label_list` | a list of `Target` |
| `attr.label_keyed_string_dict` | `Target` → string |
| `attr.string_keyed_label_dict` | string → `Target` |
| `attr.label_list_dict` (Bazel 9+) | string → list of `Target` |

Every `Target` found contributes; the string side of a keyed dict is skipped.
[`example/producer/rules/starlark_app.bzl`](example/producer/rules/starlark_app.bzl) merges in from
one attribute of every kind, with [`example/src/app/`](example/src/app/) checking that each one's
libraries land in a group.

**`fallback`** says what a target contributes when its rule does not describe its groups:

- `"ignore"` (the default) contributes nothing. Right for your own dependency attributes —
  `deps` — whose targets are your own `*_library` rules. One that doesn't describe itself is a bug,
  and synthesizing a group would both hide it and claim that target's whole `DefaultInfo`, which for
  a `*_library` is its entire closure's runfiles and overlaps the groups of everything else that
  closure reaches.
- `"synthesize"` contributes one per-target group named by the target's `Label`, covering its
  `DefaultInfo.files` and `default_runfiles`, with no `kind` and no `merge_affinity`. Right for
  `data`-like attributes, which can hold anything, including plain files. Because the name *is*
  the label, two paths to the same target produce the same group and get deduplicated automatically.
- A module-level function `(ctx, dep) -> RunfilesGroupInfo | None` synthesizes the group itself,
  for a ruleset that knows better than `DefaultInfo` what such a dependency contributes at
  runtime. rules_java, for example, takes a foreign JVM rule's transitive runtime jars and its
  `default_runfiles`, but not its `DefaultInfo.files`, which for a neverlink library holds jars
  that never reach a binary. It runs on the merging target, for every dependency without a
  describer (files included), and returns an entry built with `runfiles_groups.entry()`,
  conventionally named `dep.label`, or `None` for a dependency that contributes nothing.

So a dependency that does not describe itself *and* contributes to your `default_runfiles` must be
merged in with `fallback = "synthesize"` or a fallback function, or a packager will find no group
holding its files.

**`into`, `regroup` and metadata overrides** re-label incoming groups, which is how a binary decides
the grouping its dependencies are packaged with:

```starlark
runfiles_groups.merge_from(
    "interpreter",
    fallback = "synthesize",
    into = "my_rules#interpreter",          # rename every incoming group
    kind = "foundation",                    # override metadata
    rank = runfiles_groups.RANK_FOUNDATION,
    do_not_merge = True,
)
runfiles_groups.merge_from("deps", regroup = _bucket_by_repo)

def _bucket_by_repo(partial, owner):
    # Called once per incoming group with the merging target's Label. Return a dict
    # of name/metadata overrides, or None to keep the group as it is.
    return {"name": "my_rules#" + (partial.name.repo_name or "_main")}
```

Re-labeling only touches names and metadata — a packager's artifacts pass through unchanged — but
it flattens the attribute's partials, which is O(the subtree) for that target. Reserve it for
targets near the top of a graph: binaries, not libraries. A binary nested in another binary's
`data` re-labels its own subtree, and the outer binary then re-labels what it receives.

> **There is no single best grouping.** Prefer many fine-grained groups and let users coarsen them
> via `aspect_hints`; set `weight` so packagers can merge well.

### Naming groups

A group's name says which of two kinds it is.

**One group per target** — "the runfiles this one target contributes". Name it with a **Label**:
`ctx.label` for your own. A Label is globally unique, so there is no prefix to invent and no
namespace to coordinate, and it is free — Bazel already interns Labels.

**Many targets contributing to one group** — "interpreter", "std", "one per repository". No single
target owns it, so name it with a **string**. Strings share one namespace across every ruleset
reachable from a binary, so **prefix them with something unique to your ruleset**:

```starlark
runfiles_groups.entry(name = ctx.label, content = own_files)              # per-target
runfiles_groups.entry(name = "my_rules#interpreter", content = ...)       # named
```

Both forms are ordered, merged and looked up identically. Where you need a plain string — an
artifact name, an `OutputGroupInfo` key, a manifest line, an error message — use
`runfiles_groups.name_str()`.

Several targets adding to the **same** name is legal: the packager merges their pieces into one
group, taking `min` of `rank`, `or` of `do_not_merge`, the sum of their `weight`s, and whichever
`kind` and `merge_affinity` is set. Contributors to a shared named group need not agree on a
content form.

### Recommended rank values

Ranks form a partial order: lower rank = earlier layer = content that changes least often and is
shared most widely. Negative ranks sort before the default `0`, so foundational content lands in the
earliest, most cacheable layers.

| Constant | Value | Use for |
|----------|-------|---------|
| `runfiles_groups.RANK_FOUNDATION` | `-1000` | Rarely-changing content shared by many binaries: runtimes, interpreters, standard libraries. |
| `runfiles_groups.RANK_SHARED_DEPS` | `-100` | Third-party dependencies shared across binaries. |
| `runfiles_groups.RANK_EXECUTABLE` | `0` | The executable and first-party code. Also the default. |

The anchors are spaced far apart so finer sub-tiers slot in without renumbering — an interpreter at
`RANK_FOUNDATION`, its standard library at `RANK_FOUNDATION + 100`. Put such a derived rank in a
**module-level constant**: Bazel only caches small integers, so computing one per target allocates
and retains a boxed integer per target. Within a rank, the packager may order and merge freely.

### `kind`, `merge_affinity` and `weight`

`kind` is the protocol's stable selector. Names are Labels or ruleset-internal strings, so packager
configuration keyed on a name breaks the moment a target is renamed; `kind` doesn't, which makes it
the right key for a packager's "include these / exclude those / put these in that layer" options.
`runfiles_groups.KINDS` is a closed set — `""`, `"foundation"`, `"third_party"`, `"first_party"`,
`"debug"`, `"docs"` — and deliberately has **no** effect on ordering or merging.

`merge_affinity` steers *which* groups merge when a packager must reduce the group count.
**Recommendation: use your module name, and stamp it on every group your ruleset produces**, so your
groups consolidate together under merge pressure instead of interleaving with unrelated ones.
Affinities are a shared namespace, so modules may deliberately reuse a value to opt into the same
grouping — `rules_java` could cover every JVM-shaped group, including those from
`rules_jvm_external` or Kotlin rules.

Weights are language-specific; two that work well are a file count per group (cheap, computed in an
aspect) and real byte sizes recorded by a repository rule. Heavy groups are the ones left unmerged,
which is what you want — they benefit most from separate caching.

### Marking the group that carries the executable

The groups only cover what is inside `DefaultInfo.default_runfiles`. The remaining pieces of an
executable — the runfiles symlinks, the repo mapping manifest — still need a home. Point
`executable_group` at the group where they belong:

```starlark
runfiles_groups.node(
    add = [...],
    executable_group = "my_rules#app_code",  # or a Label, for a per-target group
)
```

`runfiles_groups.finalize()` fails if it names no surviving group, so it cannot go stale after a
rename or a merge; `None` leaves the choice to the packager. Only the **root** target's counts, so a
binary used as another binary's `data` can't claim the outer entrypoint.

### Testing your implementation

`runfiles_group_analysis_test` walks each target with the identity packager and checks:

1. **Well-formedness** — every group is valid, and `executable_group` (if set) names a surviving
   group. Checked by `runfiles_groups.finalize()` itself.
2. **Completeness** — per runfiles component (`files`, `empty_filenames`, `symlinks`,
   `root_symlinks`), the union of all groups must equal `DefaultInfo.default_runfiles` exactly. A
   files-only group contributes its files and nothing to the other three, so a rule whose runfiles
   carry symlinks cannot cover them with a depset-form group.
3. **Overlap** — runfiles appearing in more than one group.
   `overlapping_group_behavior` picks `"warn"` (default), `"error"` or `"ignore"`.
4. **Ordering and merging** — asserted with `expected_group_names`, `expected_executable_group`,
   `max_groups` and `expected_group_count`.

```starlark
load("@rules_runfiles_group//runfiles_group:runfiles_group_analysis_test.bzl", "runfiles_group_analysis_test")

runfiles_group_analysis_test(
    name = "test_runfiles_group_invariants",
    binaries = [":my_binary", ":my_other_binary"],
    overlapping_group_behavior = "error",
)
```

> [!CAUTION]
> The test materializes every depset to compare file sets, so it is expensive on large targets. This
> is a tool for rule authors' own test suites, not for every `*_binary` in a production build.

---

## For packaging rule authors

### Writing a packager

A packager is two operations, a provider and an aspect. This module does not ship your aspect:
every packager needs its own provider, because two aspects returning the same provider on one
target collide.

```starlark
load("@rules_runfiles_group//runfiles_group:lib.bzl", "runfiles_groups")

def _materialize(ctx, entry):
    # Runs on the target that adds the runfiles. Return a handle -- here, a layer.
    layer = ctx.actions.declare_file(...)
    ctx.actions.run(...)  # tar up runfiles_groups.files(entry.content)
    return struct(layer = layer, files = runfiles_groups.files(entry.content))

def _merge(ctx, name, partials):
    # Several partials become one group: concatenate their layers -- their pieces
    # are disjoint -- or rebuild one from the pieces' handles in p.pieces, a
    # depset of (contributor, handle). Called for
    # partials sharing a name, and for groups merged to satisfy max_groups --
    # don't assume the inputs share a name.
    ...

_OPS = runfiles_groups.packager_ops(materialize = _materialize, merge = _merge)

MyLayersInfo = provider(fields = runfiles_groups.PACKAGER_INFO_FIELDS)

def _my_layers_aspect_impl(target, ctx):
    return [MyLayersInfo(**runfiles_groups.aspect_step(target, ctx, _OPS, info = MyLayersInfo))]

my_layers_aspect = aspect(
    implementation = _my_layers_aspect_impl,
    attr_aspects = runfiles_groups.ATTR_ASPECTS,
    provides = [MyLayersInfo],
)
```

`aspect_step()` calls `materialize` once per entry a target adds, on that target, so the action is
shared by every binary that reaches it. A target whose rule does not describe its groups gets its
`DefaultInfo` materialized as a fallback, for parents that merge it in with
`fallback = "synthesize"`.

A handle is whatever you need to carry for a group — a `File`, a `struct` of `File`s and depsets, a
runfiles object. It lives inside a depset element, so it **must be immutable**: no lists, no dicts.
Both operations must be module-level `def`s.

**Where same-named groups are combined.** `aspect_step()` keeps two depsets per target. *Owned*
groups are named by the Label of the target that materialized them on itself; nothing else can
produce that name, so they always travel by reference. Every other group — named groups, groups a
binary re-labeled, file targets a parent synthesized — is *shared*, and can meet a group of the same
name further up. `runfiles_groups.packager_ops(..., dedup = ...)` decides what happens then:

- `"eager"` (the default): on the target where they meet. If its dependencies carry the identical
  partial, it is forwarded once; otherwise your `merge` combines them right there, so a layer is
  built where its pieces meet and reused by everything above. A target only flattens its shared
  depsets when two sources could collide, and forwards them unchanged when nothing merged.
- `"root"`: never during aspect application. Everything travels by reference and `finalize()`
  combines it once.

Either way, a merged partial records the raw pieces it was built from in `partial.pieces`, a
depset of `(contributor, handle)` tuples that references the pieces of whatever it merged instead
of copying them. **`merge` always receives inputs with disjoint pieces**: concatenating their layers never ships a
file twice. A packager that would rather rebuild a merged layer reads its pieces' handles from
`partial.pieces`.

**Propagation cost before Bazel 9.** `ATTR_ASPECTS` walks exactly each rule's
`_runfiles_group_attrs` where Bazel offers an aspect propagation filter (Bazel 9+). On Bazel 7 and 8
it is `["*"]`: the aspect visits the whole graph, exec-configured tools included, and materializes
a fallback for every target without a describer. Those actions only run when a parent uses them, but
they cost analysis time and memory.

### The finalize step

`runfiles_groups.finalize()` runs once at the root and is the only place that flattens the intermediate providers into the final set of groups. It:

1. **Takes the fallback** if the root does not describe its groups: one synthesized group, which
   also carries the executable.
2. **Combines groups that share a name** — all of them with `dedup = "root"`, only those that met
   for the first time at the root with `dedup = "eager"` — forwarding identical ones once and
   merging the rest with your `merge`.
3. **Applies transforms** from every `aspect_hints` entry providing
   `RunfilesGroupTransformInfo`, in order, re-validating each result.
4. **Merges down to `max_groups`**, if given — see [Group count limits](#group-count-limits).
5. **Orders by `(rank, name)`**, with the executable group last. Before merging, the executable
   group takes the highest rank of all present groups, so it still merges with the groups at that
   rank, and it sorts after them: the content that changes with every build goes on top. Pass
   `executable_group_last = False` to order it like any other group.

It returns `struct(groups, by_name, executable_group, group_count)`, where `groups` are
`RunfilesGroupPartialInfo` and `executable_group` is one of `by_name`'s keys, or `None`.

```starlark
# In an aspect, hints are ctx.rule.attr.aspect_hints; in a rule that cannot see
# them, pass []. The argument is mandatory on purpose: with a default, the correct
# call and the one that silently ignores every user hint look identical.
resolved = runfiles_groups.finalize(ctx, binary[MyLayersInfo], _OPS, aspect_hints = hints, max_groups = 5)
if resolved.group_count > 5:
    fail("could not reduce to 5 groups")  # do_not_merge / rank constraints

for group in resolved.groups:
    # group.name is a Label (per-target) or a string (named); runfiles_groups.name_str()
    # renders either. Also: group.kind, group.rank, group.weight, group.merge_affinity,
    # and group.handle -- whatever your materialize or merge returned.
    ...
    if group.name == resolved.executable_group:
        # Add the executable, the runfiles symlinks and the repo mapping manifest here.
        ...
```

Key the coarse, user-configurable parts of your API on `group.kind` rather than on individual
names. Where you do accept names — an "exclude this group" option — match them against
`runfiles_groups.index_by_name_str(resolved)`, so a user can write either `"@@//src:lib_a"` (a
per-target group's canonical label string) or `"my_rules#interpreter"`.

If ordering is irrelevant to your format, still finalize — that is what honors user hints — and
treat the order of `resolved.groups` as arbitrary.

The **identity packager** in
[`runfiles_group/identity_packager.bzl`](runfiles_group/identity_packager.bzl) is the reference
implementation: its handles are the runfiles contents themselves, and its merge is
`runfiles_groups.union()`.

### Group count limits

`finalize(..., max_groups = N)` merges groups until at most `N` remain, for formats with a hard cap
such as container image layers. It picks each merge in this order:

1. **Same rank only.** Groups at different ranks never merge.
2. **Prefer the same `merge_affinity`** (`""` is the shared "no affinity" bucket). It only merges
   across affinities when no same-affinity pair remains at any rank.
3. **Lightest first**, by `weight`.

Each merged group is built with one call to your `merge`, however many steps produced it. When the limit depends on
`finalize()`'s result — reserving a layer for the executable only if no group carries it, say —
call `finalize()` without `max_groups` and then `runfiles_groups.limit(ctx, ops, resolved,
max_groups = N)` yourself, with the same `executable_group_last`.
`do_not_merge` groups are never touched, so `max_groups` may be unreachable — the caller **must**
check `group_count`. The optional `merged_group_name` callback receives the two names in their
original form and may return either; a merged group is rarely still one target's, so a string built
with `runfiles_groups.name_str()` is the usual answer.

### Respecting `aspect_hints`

`aspect_hints` is only reachable from an aspect. Your packager's aspect can forward the root's
`ctx.rule.attr.aspect_hints` in its provider, or a second, non-propagating aspect can.
[`example/consumer/rules/fake_package.bzl`](example/consumer/rules/fake_package.bzl) does the
latter.

---

## Compatibility

### Rulesets describing runfiles groups (`*_binary` rules)

| Ruleset | Grouping | Metadata | Weight hints |
|---------|----------|----------|-------------|
| *Your ruleset here* | | | |

### Packaging rules consuming runfiles groups

| Ruleset | Ordering | Merge-to-limit | `aspect_hints` support |
|---------|----------|----------------|----------------------|
| *Your ruleset here* | | | |

> To add your ruleset to these tables, open a pull request.
