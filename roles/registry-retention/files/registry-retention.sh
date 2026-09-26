#!/bin/bash
# Retention: keep the N most recent tags per repo in registry.roomler.ai.
# Usage: ./registry-retention.sh [N]            (default N=2)
#        DRY_RUN=1 ./registry-retention.sh [N]  print the plan only — no DELETE, no GC, no restart
#
# Strategy: for each repo, fetch each tag's manifest (returns Docker-Content-Digest),
# fetch each tag's config.created timestamp from the image config blob, sort descending,
# delete tags past the Nth. Always preserves `latest` if present.
#
# Also never deleted, however old (added 2026-09-25):
#  - anything the cluster runs or is declared to run: every image of this registry that a pod
#    (any phase) or a Deployment / StatefulSet / DaemonSet / CronJob / scaled-up ReplicaSet
#    names, by tag or by digest. Age is not disuse: the 2026-09-20 run deleted the July tag
#    lgr-qa was running, and the pod's next restart (an OOM kill, 2026-09-25) could not pull
#    it and sat in ImagePullBackOff. If the cluster cannot be read, nothing is deleted.
#  - a digest that a kept tag also points at. A manifest DELETE is by digest and untags EVERY
#    tag on that digest, so deleting one of two twins took the other with it — and the twin's
#    HEAD then 404'd and `set -e` killed the run. Both runs before this fix (09-13, 09-20)
#    died that way, before reaching the later repos or the garbage-collect below.
# And no garbage-collect while an image the cluster uses is missing from the registry (below).
#
# The registry runs with REGISTRY_STORAGE_DELETE_ENABLED=true so DELETE actually works.
# After this script, run `docker exec roomler-registry registry garbage-collect /etc/docker/registry/config.yml`
# to reclaim disk (requires registry restart).
set -euo pipefail

KEEP="${1:-2}"
DRY_RUN="${DRY_RUN:-0}"
REG="registry.roomler.ai"
AUTH_FILE="/gjovanov/registry/auth/.password.gjovanov"
USER="gjovanov"
PW="$(sudo cat "$AUTH_FILE")"
V2='application/vnd.docker.distribution.manifest.v2+json'

CURL() { curl -sS -u "$USER:$PW" "$@"; }

echo "### $(date -Is) keep=$KEEP dry_run=$DRY_RUN"

# One "<repo> <tag|digest>" line per image of this registry the cluster references.
IN_USE="$(mktemp)"
trap 'rm -f "$IN_USE"' EXIT
kubectl get pods,deployments,statefulsets,daemonsets,replicasets,cronjobs -A -o json | python3 -c '
import json, sys
prefix = sys.argv[1] + "/"
refs = set()
for it in json.load(sys.stdin)["items"]:
    kind, spec = it["kind"], it.get("spec", {})
    if kind == "ReplicaSet" and not spec.get("replicas"):
        continue  # revision history: runs nothing
    if kind == "Pod":
        pod = spec
    elif kind == "CronJob":
        pod = spec["jobTemplate"]["spec"]["template"]["spec"]
    else:
        pod = spec["template"]["spec"]
    images = [c.get("image", "") for k in ("initContainers", "containers", "ephemeralContainers")
              for c in pod.get(k) or []]
    if kind == "Pod":  # the digest each container actually resolved to
        status = it.get("status", {})
        images += [c.get("imageID", "") for k in ("initContainerStatuses", "containerStatuses", "ephemeralContainerStatuses")
                   for c in status.get(k) or []]
    for image in images:
        image = image.split("://", 1)[-1]  # docker-pullable://…
        if not image.startswith(prefix):
            continue
        ref, _, digest = image[len(prefix):].partition("@")
        repo, _, tag = ref.partition(":")
        if tag or not digest:
            refs.add((repo, tag or "latest"))
        if digest:
            refs.add((repo, digest))
for repo, ref in sorted(refs):
    print(repo, ref)
' "$REG" > "$IN_USE"
[ -s "$IN_USE" ] || { echo "the cluster reports no $REG image in use — refusing to delete anything" >&2; exit 1; }
echo "in use: $(wc -l < "$IN_USE") references"

repos=$(CURL "https://$REG/v2/_catalog" | python3 -c 'import sys,json; [print(r) for r in json.load(sys.stdin).get("repositories",[])]')

for repo in $repos; do
  echo "=== $repo ==="
  tags=$(CURL "https://$REG/v2/$repo/tags/list" | python3 -c 'import sys,json; d=json.load(sys.stdin); [print(t) for t in (d.get("tags") or [])]')
  [ -z "$tags" ] && { echo "  no tags"; continue; }

  # Collect (created, tag, digest) triples, pulling image config.created
  entries=""
  for tag in $tags; do
    manifest=$(CURL -H "Accept: $V2" "https://$REG/v2/$repo/manifests/$tag")
    digest=$(CURL -I -H "Accept: $V2" "https://$REG/v2/$repo/manifests/$tag" | awk 'tolower($1) == "docker-content-digest:" { print $2 }' | tr -d '\r\n')
    config_digest=$(echo "$manifest" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("config",{}).get("digest","") or "")' 2>/dev/null || echo "")
    if [ -z "$config_digest" ]; then
      echo "  skip $tag (no config digest)"
      # Never deleted itself, so nothing that shares its digest may be deleted either.
      [ -n "$digest" ] && echo "$repo $digest" >> "$IN_USE"
      continue
    fi
    created=$(CURL "https://$REG/v2/$repo/blobs/$config_digest" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("created","1970-01-01T00:00:00Z"))' 2>/dev/null || echo "1970-01-01T00:00:00Z")
    entries="$entries$created|$tag|$digest"$'\n'
  done

  # Sort by creation time desc; keep `latest`, the top N and anything in use; keep any tag whose
  # digest a kept tag shares; delete each remaining digest once.
  printf '%s' "$entries" | python3 -c '
import sys
keep, repo = int(sys.argv[1]), sys.argv[2]
in_use = {ref for line in open(sys.argv[3]) for r, ref in [line.split()] if r == repo}
rows = sorted((l.split("|") for l in sys.stdin.read().splitlines() if l),
              key=lambda r: r[0] + "|" + r[1], reverse=True)
plan, kept = [], 0
for created, tag, digest in rows:
    if tag == "latest":
        why = "latest"
    elif kept < keep:
        kept += 1
        why = "newest"
    elif tag in in_use or digest in in_use:
        why = "in-use"
    else:
        why = ""
    plan.append((created, tag, digest, why))
protected = {d for _, _, d, why in plan if why} | in_use
deleted = set()
for created, tag, digest, why in plan:
    if why:
        action = "KEEP"
    elif not digest:
        action, why = "KEEP", "no-digest"
    elif digest in protected:
        action, why = "KEEP", "shares-digest"
    elif digest in deleted:
        action, why = "GONE", "-"
    else:
        deleted.add(digest)
        action, why = "DELETE", "-"
    print(action, tag, created, digest or "-", why)
' "$KEEP" "$repo" "$IN_USE" | while read -r action tag created digest why; do
      case "$action/$why" in
        KEEP/in-use)        echo "  KEEP $tag ($created) — in use by the cluster" ;;
        KEEP/shares-digest) echo "  KEEP $tag ($created) — its digest is also a kept tag's" ;;
        KEEP/no-digest)     echo "  KEEP $tag ($created) — no digest to delete by" ;;
        GONE/*)             echo "  GONE $tag ($created) — same digest as a tag deleted above" ;;
        *)                  echo "  $action $tag ($created)" ;;
      esac
      if [ "$action" = DELETE ]; then
        if [ "$DRY_RUN" = 1 ]; then
          echo "    would delete $tag (digest=$digest)"
        else
          CURL -X DELETE "https://$REG/v2/$repo/manifests/$digest" > /dev/null
          echo "    deleted $tag (digest=$digest)"
        fi
      fi
    done
done

# A deleted manifest keeps its layers on disk until a garbage-collect, and while they are there
# the image can be restored by re-pushing its manifest from a node that still has it (how lgr-qa
# came back on 2026-09-25). So collect nothing while something the cluster uses is missing.
ACCEPT_ANY='application/vnd.docker.distribution.manifest.v2+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.oci.image.index.v1+json'
missing=""
while read -r repo ref; do
  code=$(CURL -o /dev/null -w '%{http_code}' -I -H "Accept: $ACCEPT_ANY" "https://$REG/v2/$repo/manifests/$ref")
  case "$ref" in sha256:*) sep=@ ;; *) sep=: ;; esac
  [ "$code" = 200 ] || missing="$missing $repo$sep$ref"
done < "$IN_USE"
[ -n "$missing" ] && echo "=== in use but missing from the registry:$missing"

if [ "$DRY_RUN" = 1 ]; then
  echo "dry run: no garbage-collect, no registry restart."
  exit 0
fi
if [ -n "$missing" ]; then
  echo "=== NOT running garbage-collect: it would delete the only layers those images can be restored from. Restore or re-pin them first."
  exit 0
fi
echo "=== running garbage-collect to reclaim disk ==="
docker exec roomler-registry registry garbage-collect /etc/docker/registry/config.yml 2>&1 | tail -5 || true
echo "=== restart registry container to pick up GC'd state ==="
docker restart roomler-registry > /dev/null
echo "done."
