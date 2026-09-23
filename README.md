# affine Helm chart repository

Public Helm repository for the `affine` chart (self-hosted AFFI-NE).

```bash
helm repo add affine https://wussh.github.io/affine-helm-chart/
helm repo update
helm search repo affine/affine --versions
```

Published versions: `0.2.1`, `0.2.2`, `0.2.3`.

Artifact Hub: register this repository with the URL above
(<https://artifacthub.io/docs/topics/repositories/helm-charts/>). To claim
ownership, add `artifacthub-repo.yml` with the `repositoryID` shown by Artifact
Hub after the repository is added.

The chart source is developed in a private organisation repository; this
repository mirrors the released packages.
