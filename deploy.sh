#!/bin/bash
set -euo pipefail

# 1) CONFIGURE THIS
image_name="open-webui"
registry="ghcr.io/jordanallen87"      # or your Docker Hub org: docker.io/username
tag="latest"
full_image="$registry/$image_name:$tag"

# 2) BUILD your local image
docker build -t "$image_name" .

# 3) TAG the image for your registry
docker tag "$image_name" "$full_image"

# 4) PUSH it up so Render can consume it
#    (make sure you've `docker login`ed to ghcr.io or docker.io)
docker push "$full_image"

# 5) (optional) save a tarball if you need an explicit file
#docker save "$full_image" -o "${image_name}-${tag}.tar"

echo "✅ Built and pushed $full_image"