# Nix installation

## Darwin installation and Homebrew migration

The flake exports `darwinModules.default` and `homeModules.default`. Use one
installation owner. The Darwin module publishes the signed release through
`environment.systemPackages` into `/Applications/Nix Apps/Cochlea.app`:

```nix
programs.cochlea = {
  enable = true;
  # package = inputs.cochlea.packages.${pkgs.system}.default;
  migrateFromHomebrew = true; # Only for an existing app-only cask installation.
};
```

Remove this app's cask declaration from the same host change. Save work and quit
the installed app normally before activation. Other casks and Homebrew's policy
stay unchanged; Homebrew distribution remains supported.

An early activation check rejects an undeclared migration, unknown/orphan receipt,
uninstall hooks, or a running app before bundles are published. After publication,
the module rechecks the receipt and process, verifies the new bundle's signature
and contents against its package, then uninstalls only the exact cask without
`--zap`. Failure stops activation before normal Homebrew cleanup. Activation is
not atomic: a failure can leave both app bundles present for review. Never delete
application data, preferences or Keychain items to recover a packaging failure.

Keep the old signed release and receipt before migration. Roll back with an
explicit `package` override to that signed release after checking data-format
compatibility. An old Homebrew declaration can fetch the current tap version;
rolling back a Nix generation alone does not necessarily restore an old cask.
Native sign-in, enrollment and permission prompts stay app-managed user state.
A replacement machine enrolls through the app's normal interface.

Run `python3 scripts/test-nix-migration.py` for the isolated activation cases and
`nix flake check` for the package/module checks. The package's `version`, `url`
and `hash` inputs can pin another immutable signed release without rebuilding
or modifying the application.
