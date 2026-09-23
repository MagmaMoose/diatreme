# Publishing a public Helm chart

<!-- sources: action.yml, scripts/publish-package.sh -->

`package-ecosystem: helm` packages a chart and pushes it to an OCI registry in the same
run that tags the release and promotes its image, so the chart and the image it points at
come from one commit. Four opt-in extras turn that into a chart strangers can find and
trust: a lint gate, a cosign signature, Artifact Hub's repository metadata, and the
Artifact Hub listing itself.

```yaml
jobs:
  release:
    runs-on: ubuntu-latest
    permissions:
      contents: write
      id-token: write     # the Diatreme App token, and keyless cosign
      packages: write     # push the chart to GHCR
    steps:
      - uses: actions/checkout@v5
        with: { fetch-depth: 0, fetch-tags: true }
      - uses: MagmaMoose/diatreme@v2
        with:
          publish-package: 'true'
          package-ecosystem: helm
          package-path: charts/my-app
          helm-app-version: tag
          helm-lint: 'true'
          helm-sign: 'true'
          artifacthub-repo-file: artifacthub-repo.yml
          artifacthub-api-key-id: ${{ secrets.ARTIFACTHUB_API_KEY_ID }}
          artifacthub-api-key-secret: ${{ secrets.ARTIFACTHUB_API_KEY_SECRET }}
```

The chart lands at `oci://ghcr.io/<owner>/charts/<chart name>:<version>`; `package-name`
changes the `<owner>/charts` part.

!!! warning "The default appVersion is not the image tag"

    The chart's `version` and `appVersion` are both the released version, `1.4.0`. Image
    promotion pushes the release **tag**, `v1.4.0` with the default `tag-prefix`. A chart
    that defaults its image tag to `.Chart.AppVersion`, which is the Helm convention,
    then points at a tag nobody pushed, and nothing fails until a pod cannot pull it.
    `helm-app-version: tag` sets appVersion to the tag instead. Use
    `helm-app-version: chart` for a chart that ships an image this repository does not
    build, to keep the appVersion committed in `Chart.yaml`.

## What each extra does

| Input | Effect |
| --- | --- |
| `helm-lint` | `helm lint` before packaging. A failure publishes nothing. |
| `helm-sign` | A keyless cosign signature on the pushed digest, which Artifact Hub shows as a signed chart. A re-run that finds the version already published signs the digest the registry holds, so a run that failed after pushing can be re-run into a signed chart. |
| `artifacthub-repo-file` | Pushes `artifacthub-repo.yml` as the chart repository's `artifacthub.io` tag, which is where Artifact Hub looks for Verified Publisher and ownership claims. |
| `artifacthub-api-key-id` + `-secret` | Lists the chart on Artifact Hub when it is not listed yet, and reports its repository ID in the `artifacthub-repository-id` output and the job summary. |

Every extra is checked before anything is pushed, so a missing file, a lone API key or a
name Artifact Hub would refuse fails the run with nothing published.

## A first public release, in order

1. **Make the package public.** A new GHCR package is private, and Artifact Hub reads
   charts anonymously: a private one is listed with nothing in it. The run warns when it
   cannot pull the chart anonymously. The switch is in the package's settings on GitHub,
   under Danger Zone.
2. **Create an Artifact Hub API key** (Control Panel, Settings, API keys) and store its
   ID and secret as repository or organization secrets. Set `artifacthub-org` to list
   the chart under an Artifact Hub organization rather than under the key's user.
3. **Release.** The job summary shows the new repository's ID.
4. **Commit `artifacthub-repo.yml`** with that ID. The next release pushes it, and
   Artifact Hub marks the publisher verified on its next scan:

    ```yaml
    repositoryID: 5f1e6a2b-0000-0000-0000-000000000000
    owners:
      - name: Platform team
        email: platform@example.com
    ```

Artifact Hub lists one repository per OCI chart; it cannot list a whole registry. Its
repository names are unique across Artifact Hub and appear in package URLs, so set
`artifacthub-repository-name` when the chart's own name is taken.

## Annotations

Artifact Hub reads `artifacthub.io/*` annotations from `Chart.yaml`: `license`, `links`,
`maintainers`, `images` (the images its security report scans), `changes` and
`prerelease`, among others. They ship inside the chart, so they are the chart's business,
not the action's; Artifact Hub's control panel reports the ones it cannot parse.

## When something fails

Artifact Hub is a sink. When it is down, or refuses the listing, the run warns and the
release stands, because the chart is already published by then. Signing and the metadata
push go to the same registry as the chart, so their failures fail the step; re-run the
job, and the already-published chart is signed and described without being pushed again.
