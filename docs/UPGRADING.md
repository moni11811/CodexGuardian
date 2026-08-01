# Upgrading and rollback

## Supported update path

The supported current path is source-to-source local installation:

```bash
git status --short
./script/install_production.sh
./script/test_production_install.sh
```

Review incoming source and local changes before installing. The installer builds a release, stages it beside `/Applications`, verifies signatures, swaps bundles, activates launchd jobs, and calls the daemon health endpoint.

## Preserved data

Updates preserve:

- SQLite journal and operation history
- local MCP/UI/CLI credentials
- pending recovery state
- remote configuration and identity material, if present

The installer does not reset state to make activation pass.

## Automatic rollback

If candidate verification or activation fails, the installer restores the previous application and launchd configuration. The failed candidate and prior configurations remain in the backup directory for local diagnosis.

After rollback, verify the restored runtime:

```bash
./script/test_production_install.sh
```

Do not repeat the installer unchanged. Use the named failed stage—candidate verification, daemon bootstrap, daemon kickstart, UI bootstrap, UI kickstart, or daemon health—to change the diagnosis.

## Downgrade warning

There is no broad guarantee that an older binary understands state written by a newer schema. Keep backups and verify migration tests before intentional downgrade. Do not hand-edit SQLite or copy only WAL sidecar files.

## Recovery from a broken local install

1. Preserve `~/Library/Application Support/CodexGuardian/`.
2. Inspect bounded launchd status without printing full environments.
3. Run the production verifier.
4. Reinstall from a known reviewed source revision.
5. If necessary, use the archived previous bundle/config as evidence; do not overwrite state blindly.

No update step should restart Codex Desktop automatically.
