# Security

Please report security problems privately, not as a public issue: under **Security > Report a
vulnerability** in this repository. That includes a way around the secret guard
(`hooks/block-secrets.sh`) that Claude could plausibly hit by accident, anything in `install.ps1`
that could run, overwrite or expose something it should not, and a secret that slipped into the
repository.

The guard is meant to stop accidents, not a determined attacker; its header lists what it does
not cover, and those cases need no report. Reports are answered when time allows; once a fix is
out, the report can be made public.
