#!/bin/bash
set -xeo pipefail
shopt -s expand_aliases

docker_name=shesek/bwt
gh_repo=shesek/bwt
node_image=node:14 # for packaging nodejs-bwt-daemon

alias docker_run="docker run -it --rm -u `id -u` -v `pwd`:/usr/src/bwt -v ${CARGO_HOME:-$HOME/.cargo}:/usr/local/cargo"

if ! git diff-index --quiet HEAD; then
  echo git working directory is dirty
  exit 1
fi

version=`cat Cargo.toml | egrep '^version =' | cut -d'"' -f2`

if [[ "$1" == "patch" ]]; then
  # bump the patch version by one
  version=`node -p 'process.argv[1].replace(/\.(\d+)$/, (_, v) => "."+(+v+1))' $version`
  sed -i 's/^version =.*/version = "'$version'"/' Cargo.toml
elif [[ "$1" != "nobump" ]]; then
  echo invalid argument, use "patch" or "nobump"
  exit 1
fi

# Extract unreleased changelog & update version number
changelog="`sed -nr '/^## (Unreleased|'$version' )/{n;:a;n;/^## /q;p;ba}' CHANGELOG.md`"
grep '## Unreleased' CHANGELOG.md > /dev/null \
  && sed -i "s/^## Unreleased/## $version - `date +%Y-%m-%d`/" CHANGELOG.md

sed -i -r "s~bwt-[0-9a-z.-]+-x86_64-linux\.~bwt-$version-x86_64-linux.~g; s~/(download|tag)/v[0-9a-z.-]+~/\1/v$version~;" README.md

echo -e "Releasing bwt v$version\n================\n\n$changelog\n\n"

echo Running cargo check and fmt...
cargo fmt -- --check
./scripts/check.sh

if [ -z "$SKIP_BUILD" ]; then
  echo Building releases...

  mkdir -p dist
  rm -rf dist/*

  if [ -z "$BUILD_HOST" ]; then
    docker build -t bwt-builder - < scripts/builder.Dockerfile
    docker_run bwt-builder
    if [ -z "$SKIP_OSX" ]; then
      docker build -t bwt-builder-osx - < scripts/builder-osx.Dockerfile
      docker_run bwt-builder-osx
    fi
    docker_run -w /usr/src/bwt/contrib/nodejs-bwt-daemon $node_image npm run dist -- $version ../../dist
  else
    # macOS builds are disabled by default when building on the host.
    # to enable, set TARGETS=x86_64-osx,...
    ./scripts/build.sh
    (cd contrib/nodejs-bwt-daemon && npm run dist -- $version ../../dist)
  fi

  echo Making SHA256SUMS...
  (cd dist && sha256sum *) | sort | gpg --clearsign --digest-algo sha256 > SHA256SUMS.asc
fi


if [ -z "$SKIP_GIT" ]; then
  echo Tagging...
  git add Cargo.{toml,lock} CHANGELOG.md SHA256SUMS.asc README.md contrib/nodejs-bwt-daemon
  git commit -S -m v$version
  git tag --sign -m "$changelog" v$version
  git branch -f latest HEAD

  echo Pushing to github...
  git push gh master latest
  git push gh --tags
fi

if [ -z "$SKIP_CRATE" ]; then
  echo Publishing to crates.io...
  cargo publish
fi

if [ -z "$SKIP_PUBLISH_NPM_DAEMON" ]; then
  echo Publishing bwt-daemon to npm...
  npm publish file:dist/nodejs-bwt-daemon-$version.tgz
fi

if [[ -z "$SKIP_UPLOAD" && -n "$GH_TOKEN" ]]; then
  echo Uploading to github...
  gh_auth="Authorization: token $GH_TOKEN"
  gh_base=https://api.github.com/repos/$gh_repo

  travis_job=$(curl -s "https://api.travis-ci.org/v3/repo/${gh_repo/\//%2F}/branch/v$version" | jq -r .last_build.id || echo '')

  release_text="### Changelog"$'\n'$'\n'$changelog$'\n'$'\n'`cat scripts/release-footer.md | sed "s/VERSION/$version/g; s/TRAVIS_JOB/$travis_job/g;"`
  release_opt=`jq -n --arg version v$version --arg text "$release_text" \
    '{ tag_name: $version, name: $version, body: $text, draft:true }'`
  gh_release=`curl -sf -H "$gh_auth" $gh_base/releases/tags/v$version \
           || curl -sf -H "$gh_auth" -d "$release_opt" $gh_base/releases`
  gh_upload=`echo "$gh_release" | jq -r .upload_url | sed -e 's/{?name,label}//'`

  for file in SHA256SUMS.asc dist/*; do
    echo ">> Uploading $file"

    curl -f --progress-bar -H "$gh_auth" -H "Content-Type: application/octet-stream" \
         --data-binary @"$file" "$gh_upload?name=$(basename $file)" | (grep -v browser_download_url || true)
  done

  # make release public once everything is ready
  curl -sf -H "$gh_auth" -X PATCH $gh_base/releases/`echo "$gh_release" | jq -r .id` \
    -d '{"draft":false}' > /dev/null
fi

if [ -z "$SKIP_DOCKER" ]; then
  echo Releasing docker images...

  docker_tag=$docker_name:$version
  docker build -t $docker_tag .
  docker build -t $docker_tag-electrum --build-arg FEATURES=electrum .
  docker tag $docker_tag $docker_name:latest
  docker tag $docker_tag-electrum $docker_name:electrum
  docker push $docker_name
fi
