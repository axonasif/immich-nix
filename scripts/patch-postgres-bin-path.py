"""Drop Immich's hardcoded Debian postgres path from the backup service.

Immich builds the pg_dump/pg_restore command as
`/usr/lib/postgresql/${databaseMajorVersion}/bin/${bin}`, which does not exist
under nix. We put the matching postgres client on PATH instead, so the bare
binary name is what we want. nixpkgs patches the same line in its package.

Scheduled database backups are enabled by default, so without this the nightly
job fails silently.
"""

import sys

OLD = "`/usr/lib/postgresql/${databaseMajorVersion}/bin/${bin}`"
NEW = "`${bin}`"


def main() -> None:
    path = sys.argv[1]
    source = open(path).read()

    if OLD not in source:
        raise SystemExit(
            f"{path}: expected postgres bin path not found.\n"
            "Upstream may have restructured this; re-check the file at the "
            "target tag before dropping or adapting this patch."
        )

    open(path, "w").write(source.replace(OLD, NEW))


if __name__ == "__main__":
    main()
