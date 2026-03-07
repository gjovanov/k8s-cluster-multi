#!/bin/bash
# Docker Image Cleanup Script
# Keeps only the last KEEP_COUNT tagged images per repository.
# Removes all dangling (untagged) images.
#
# Usage: docker-image-cleanup.sh [KEEP_COUNT]
#   KEEP_COUNT: number of most recent tags to keep per repo (default: 3)

set -euo pipefail

KEEP_COUNT="${1:-3}"
LOG_PREFIX="[docker-cleanup]"

echo "$LOG_PREFIX $(date '+%Y-%m-%d %H:%M:%S') Starting cleanup (keeping last $KEEP_COUNT tags per repo)"

# 1. Remove dangling images
dangling=$(docker images -f "dangling=true" -q | wc -l)
if [ "$dangling" -gt 0 ]; then
    echo "$LOG_PREFIX Removing $dangling dangling image(s)..."
    docker image prune -f
else
    echo "$LOG_PREFIX No dangling images found."
fi

# 2. For each repository, remove old tags beyond KEEP_COUNT
# Get unique repositories (excluding <none>)
repos=$(docker images --format '{{.Repository}}' | grep -v '<none>' | sort -u)

for repo in $repos; do
    # Get all tags for this repo sorted by creation date (newest first)
    tags=$(docker images --format '{{.CreatedAt}}\t{{.Repository}}:{{.Tag}}' --filter "reference=${repo}" \
        | sort -r \
        | awk '{print $NF}')

    count=0
    for image in $tags; do
        count=$((count + 1))
        if [ "$count" -gt "$KEEP_COUNT" ]; then
            # Check if image is used by a running container
            if docker ps -q --filter "ancestor=${image}" | grep -q .; then
                echo "$LOG_PREFIX SKIP $image (in use by running container)"
            else
                echo "$LOG_PREFIX REMOVE $image"
                docker rmi "$image" 2>/dev/null || echo "$LOG_PREFIX WARN: could not remove $image (may be referenced by another tag)"
            fi
        fi
    done
done

# 3. Prune build cache older than 7 days
echo "$LOG_PREFIX Pruning build cache older than 7 days..."
docker builder prune -f --filter "until=168h" 2>/dev/null || true

# 4. Prune unused volumes
echo "$LOG_PREFIX Pruning unused volumes..."
docker volume prune -f 2>/dev/null || true

# 5. Final prune to clean up any layers left behind
docker image prune -f > /dev/null 2>&1

# Report
echo "$LOG_PREFIX Cleanup complete. Current disk usage:"
docker system df
echo "$LOG_PREFIX $(date '+%Y-%m-%d %H:%M:%S') Done."
