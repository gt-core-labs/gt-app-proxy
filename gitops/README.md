# GitOps for the gt-core platform — replaces watchtower

Bead **hq-talos-migration.6**. This directory is the continuous-delivery layer of
the Talos migration: a GitOps controller (**Argo CD** as primary, **Flux** as a
documented alternative) reconciles the cluster to the Helm chart at
[`../chart/gt`](../chart/gt). Git is the source of truth; every deploy is an
auditable change to git.

```
gitops/
├── README.md                      ← this file
├── argocd/
│   └── application.yaml           ← Argo CD Application (PRIMARY): source=chart/gt,
│                                     automated sync + selfHeal + prune, pins image tags
└── flux/
    └── helmrelease.yaml           ← Flux GitRepository + HelmRelease (ALTERNATIVE)
```

## Why this replaces watchtower (the .9 incident)

Today the compose stack runs **watchtower**: it watches the `:embeddings` /
`:latest` tags, and the moment CI re-pushes that moving tag it pulls the new image
and **recreates the container blind** — no probe gate, no review, no record of
*which* image is live. On 2026-06-10 bead `.9` published a boot-broken
`:embeddings`; watchtower pulled it and crash-looped prod, requiring a manual
rollback.

GitOps removes every part of that failure mode:

| | watchtower (retiring) | GitOps (this dir) |
| --- | --- | --- |
| What triggers a deploy | a moving tag (`:embeddings`) is re-pushed | a **PR merged to `main`** bumps an immutable tag |
| Auditability | none — you can't tell which build is live | the live tag is a line in git history |
| Rollout safety | blind container recreate | probe-gated rolling update (`maxUnavailable: 0`); a pod that never goes Ready never replaces a healthy one |
| Rollback | manual `docker` surgery | `git revert` the bump PR |
| Drift | n/a | controller self-heals out-of-band `kubectl` edits |

> **Watchtower must be REMOVED from the compose stack once GitOps is live.** That
> cutover is **bead .8** — do **not** delete it from `docker-compose.yml` here.
> Running watchtower and a GitOps controller at the same time is undefined
> (watchtower could still recreate a container the cluster no longer owns).

## The immutable-tag flow (and the follow-up it needs)

GitOps deploys an **immutable** image reference — a tag that points at exactly one
build forever, ideally a release `:<sha>` (or a `@sha256:` digest). That is what
makes "bump the tag in git" both auditable and reversible: the tag in
`application.yaml` *is* the deployed build.

**Gap today:** the `gt-core` and `gt-web` `docker-publish` workflows push only
**moving** tags — `codecsrayo/gt-core-mcp-server:embeddings`, `:latest`,
`codecsrayo/gt-web:latest`, `codecsrayo/gt-docs:latest`. Those are exactly the
tags watchtower chased; pinning the Argo Application to them gives auditable
*intent* but not an immutable *target* (the tag can still be re-pushed under us).

**Follow-up required (cannot be done from this repo):** add a per-commit immutable
tag to each docker-publish workflow, in addition to the moving tag —

- `gt-core` CI → also `docker push codecsrayo/gt-core-mcp-server:${GITHUB_SHA}`
  (and `:sha-<short>`), keep `:embeddings` for the transition.
- `gt-web` CI → also `codecsrayo/gt-web:${GITHUB_SHA}` and
  `codecsrayo/gt-docs:${GITHUB_SHA}`.

File this as a `deploy.compose` / CI bead against gt-core and gt-web. Until it
lands, the Application's `tag:` values track the moving tags (still an improvement:
the deploy is now a reviewable git change), but flip them to `:<sha>` the moment
per-sha tags exist — that is the point at which the model is fully immutable.

## Bootstrap — install Argo CD on Talos and apply the Application

> Talos is API-driven (no shell/SSH); you drive the cluster with `talosctl` +
> `kubectl` from your workstation. Do **not** run these against a cluster as part
> of *authoring* this config — there is no cluster yet. This is the runbook for
> when one exists.

```sh
# 0. Have a kubeconfig for the Talos cluster (talosctl kubeconfig).

# 1. Install Argo CD into its own namespace.
kubectl create namespace argocd
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
# (or: helm repo add argo https://argoproj.github.io/argo-helm
#      helm install argocd argo/argo-cd -n argocd --create-namespace)

# 2. Manage the platform secrets out-of-band (the chart is installed with
#    secrets.create=false). E.g. sealed-secrets:
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/latest/download/controller.yaml
#    then seal the keys from chart/gt/values-secret.yaml.example into a Secret
#    named `gt-gt-secrets` in namespace `gt`.

# 3. Register this repo + apply the Application (bootstrap is the ONLY kubectl
#    apply; everything after is git).
kubectl apply -f gitops/argocd/application.yaml

# 4. Argo now reconciles namespace `gt` to chart/gt. Watch it:
kubectl -n argocd get applications gt-platform -w
# or the UI: kubectl -n argocd port-forward svc/argocd-server 8080:443
```

If the repo is private, register credentials first (`argocd repo add ... --username
... --password <PAT>` or a `repo-creds` Secret) before step 3.

### Flux alternative

Use `gitops/flux/helmrelease.yaml` instead of the Argo Application. Apply EITHER
Argo OR Flux — never both (they fight over the same objects).

```sh
flux install
kubectl apply -f gitops/flux/helmrelease.yaml
```

## Deploy workflow (steady state)

A deploy is a one-line tag bump, reviewed and recorded:

1. CI builds and pushes the new image as an immutable `:<sha>` (see follow-up above).
2. Open a PR editing `gitops/argocd/application.yaml`:

   ```yaml
   helm:
     valuesObject:
       mcpServer:
         image:
           tag: <new-sha>     # was <old-sha>
   ```

   (and `daemons.image.tag` for the same gt-core image; `web` / `docs` similarly).
3. Merge to `main`. Argo detects the change and syncs.
4. **Probes gate it.** The chart's rolling update is `maxUnavailable: 0`: Argo
   brings up a new pod, and only if it passes readiness does it retire an old one.
   A boot-broken image never goes Ready → the Application sits `Progressing` /
   `Degraded`, the old pods keep serving, **prod stays up** (the `.9` failure mode
   is structurally gone). Roll back per below.

## Rollback

```sh
# Preferred — auditable, same path as deploy:
git revert <bump-commit> && git push        # PR; Argo syncs back to the old tag.

# Fast operator override (then reconcile back to git):
argocd app rollback gt-platform <history-id>
# Flux: flux suspend hr/gt; (edit values back); flux resume hr/gt
#       — HelmRelease auto-rollback also fires on a failed upgrade (rollback.enable).
```

Because the deployed tag lives in git, "what changed and when" is `git log` on this
directory, and undoing a bad deploy is a revert — no manual container surgery, no
guessing which build is live.

## The Application at a glance

| field | value | meaning |
| --- | --- | --- |
| `source.repoURL` | this repo | where the desired state lives |
| `source.path` | `chart/gt` | the Helm chart Argo renders |
| `source.targetRevision` | `main` | the branch reconciled (deploy = merge to main) |
| `helm.valuesObject.*.image.tag` | image tags | **the field a deploy PR bumps** (pin to `:<sha>`) |
| `destination.namespace` | `gt` | where the platform runs |
| `syncPolicy.automated.selfHeal` | `true` | revert out-of-band edits back to git |
| `syncPolicy.automated.prune` | `true` | GC objects removed from the chart |
| `syncOptions: CreateNamespace=true` | — | Argo creates `gt` if absent |
