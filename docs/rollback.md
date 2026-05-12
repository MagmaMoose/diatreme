# Rolling Back a Release

Use this guide when a release was cut but must be removed so that the previous
version becomes the effective latest.

This procedure covers repositories that use Release Runner with FluxCD
`ImagePolicy` and `ImageUpdateAutomation` for Kubernetes deployments. If your
repository does not use FluxCD, skip the Flux steps.

## Prerequisites

Your `gh` CLI token must have the `delete:packages` scope. Check with:

```bash
gh auth status
```

If `delete:packages` is missing, add it:

```bash
gh auth refresh -h github.com -s delete:packages
```

You also need `flux` CLI access to the target cluster if you want to force
reconciliation rather than waiting up to 5 minutes for the automatic scan.

## Why Order Matters

The `ImagePolicy` selects the highest semver tag present in the container
registry. If you revert the kustomization manifest first but the image tag
still exists in GHCR, the `ImageUpdateAutomation` will overwrite your change
back within 5 minutes. Always remove the image from the registry before
touching any manifests.

## Procedure

### 1. Remove the image tag from GHCR

Find the internal version ID for the tag you want to remove:

```bash
gh api /orgs/<org>/packages/container/<image_name>/versions \
  --jq '.[] | select(.metadata.container.tags[] == "<tag>") | .id'
```

Then delete it:

```bash
gh api --method DELETE /orgs/<org>/packages/container/<image_name>/versions/<id>
```

### 2. Delete the GitHub Release

```bash
gh release delete <tag> --repo <org>/<repo> --yes
```

### 3. Delete the git tag

```bash
# Remote first, then local
git push origin --delete <tag>
git tag -d <tag>
```

### 4. Force Flux to re-scan

Without this step Flux waits up to 5 minutes before it notices the tag is
gone. Force it immediately:

```bash
flux reconcile image repository <imagerepository-name> -n flux-system
flux reconcile image policy <imagepolicy-name> -n flux-system
```

The `ImagePolicy` will now resolve to the previous highest tag. The
`ImageUpdateAutomation` will commit the updated tag into the configured
source repository branch on its next run (up to 5 minutes, or trigger it
manually):

```bash
flux reconcile image update <imageupdateautomation-name> -n flux-system
```

### 5. Verify

```bash
# Confirm the policy resolved to the expected tag
flux get image policy <imagepolicy-name> -n flux-system

# Confirm the automation committed the change
flux get image update <imageupdateautomation-name> -n flux-system
```

Check that the kustomization in the source repository now contains the
previous tag — for example `k8s/overlays/staging/kustomization.yaml` — and
that Flux has reconciled the workloads.

## What Not To Do

- Do not manually edit the kustomization before removing the image from GHCR.
  The automation will overwrite it.
- Do not delete the tag from the source repository only. As long as the image
  tag exists in GHCR, the `ImagePolicy` will keep selecting it.
