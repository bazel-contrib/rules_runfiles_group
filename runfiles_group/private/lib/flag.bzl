"""The deprecated global on/off switch."""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")

# Deprecated. Attribute fragment that gave a rule access to the global
# RunfilesGroupInfo on/off switch, back when rules emitted the provider eagerly.
# Groups are now collected on demand by a packager's aspect, so nothing reads the
# switch any more. Kept, with is_enabled(ctx), so existing rules still load.
#
# Label("//runfiles_group:enabled") is resolved in this module's repo context,
# so it points at @rules_runfiles_group//runfiles_group:enabled in every
# consumer repo — consumers merge in this fragment without naming the flag.
RULE_ATTRS = {
    "_runfiles_group_enabled": attr.label(default = Label("//runfiles_group:enabled")),
}

def is_enabled(ctx):
    """Returns the value of the global runfiles group switch.

    Reads the @rules_runfiles_group//runfiles_group:enabled build setting.
    Requires runfiles_groups.RULE_ATTRS to have been merged into the rule's attrs.

    Args:
        ctx: The rule context.

    Returns:
        The value of @rules_runfiles_group//runfiles_group:enabled.

    Deprecated:
        Groups are collected on demand by a packager's aspect, so nothing reads
        the switch any more.
    """
    return ctx.attr._runfiles_group_enabled[BuildSettingInfo].value
