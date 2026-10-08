"""Public API for the identity packager."""

load(
    "//runfiles_group/private/aspects:identity.bzl",
    _RunfilesGroupIdentityInfo = "RunfilesGroupIdentityInfo",
    _runfiles_groups_identity_aspect = "runfiles_groups_identity_aspect",
)

RunfilesGroupIdentityInfo = _RunfilesGroupIdentityInfo
runfiles_groups_identity_aspect = _runfiles_groups_identity_aspect
