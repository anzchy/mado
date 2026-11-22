# Shared lock tools (#738 WI-2/3)

The repository scripts remain the source and CI implementation. The delegator
installs a named commit for consumers after coordinating with RClick. Tests use
a temporary `HOME`; they never install under a developer's real `~/.local`.

```sh
python3 scripts/locks/install_shared_locks.py --commit "$(git rev-parse HEAD)"
~/.local/bin/heavy-lock --version
~/.local/bin/gui-lock --version
```

The installer copies the commit's shell and Python sources into
`~/.local/share/shared-locks/<commit>/`, records their SHA-256 content hash, and
publishes stable links in `~/.local/bin/`. A single atomic change of the
`current` symlink switches both commands. It refuses to overwrite an altered
snapshot or an unmanaged public link. It never reads or changes lock state.

Run conformance with temporary lock paths and HOME; `--kind` selects the tool's
contract. It asserts only verified behavior from
[`shared-locks-contract.md`](../../docs/agents/shared-locks-contract.md).

```sh
python3 scripts/locks/conformance.py --kind heavy --executable scripts/heavy-lock.sh
python3 scripts/locks/conformance.py --kind gui --executable .agents/skills/mado-delegator/scripts/gui-lock.sh
```

The test suite runs through `scripts/agents/shared-locks.test.mjs` in the
existing Agent tooling lane. A real install and cross-project visibility check
on the developer machine remain the delegator's acceptance step.
