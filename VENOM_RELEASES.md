# Venom Releases

This file is the short operator/developer guide for how venom releases work in
the current Spiderweb + SpiderVenoms model.

## At a glance

- `SpiderVenoms` owns the published first-party capability bundles.
- `Spiderweb` pins a published `SpiderVenoms` release and verifies it before
  staging managed local venom metadata.
- The public runtime contract remains rooted at:
  - `/.spiderweb/catalog/*`
  - `/.spiderweb/venoms/*`

## Release flow

1. `SpiderVenoms` builds and publishes a signed managed bundle release.
2. The bundle includes:
   - `release.json`
   - signed package entries
   - signed manifest templates
   - staged executables/assets
3. `Spiderweb` pins the published release asset URL and checksum.
4. At install/package time, Spiderweb verifies the published asset checksum.
5. At runtime, Spiderweb verifies signed release and manifest metadata before:
   - staging executables
   - writing rendered manifests
   - starting the managed local node

## Trust model

- Bundle envelopes use signed digest verification.
- Trusted signing keys are policy-checked, not just cryptographically valid.
- Revoked keys and wrong-purpose keys are rejected.
- Unsigned bundles are rejected unless explicit local dev override is enabled.

## Control-plane lifecycle

Spiderweb now treats installed venom releases as a first-class lifecycle:

- `install`: add an installable release to the local registry
- `list`: show projected packages plus installed releases
- `get`: inspect either the projected package or a specific installed release
- `switch`: make a specific installed release active
- `rollback`: move back to a lower installed release when one exists
- `remove`: delete an installed release or package entry

Installed package JSON exposes:

- `release_version`
- `active_release_version`
- `active_release_id`
- `installed_release_count`
- `installed_release_versions`

## Ownership boundary

- `SpiderVenoms` owns first-party capability bundle content and release assets.
- `Spiderweb` owns control-plane projection, local staging, trust enforcement,
  and workspace/session compatibility surfaces.
- Runtime-local namespace adapters like terminal/git now live under
  `src/runtime/`, not `src/venoms/`.

## Practical operator takeaway

When debugging a managed venom issue, check in this order:

1. Is Spiderweb pinned to the expected `SpiderVenoms` release?
2. Did checksum verification pass when packaging/installing?
3. Did signature and trust-policy verification pass at runtime?
4. Which release is currently active for the package?
5. Is the failure in bundle trust/staging, or in the runtime/provider layer?
