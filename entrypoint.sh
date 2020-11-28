#!/bin/bash

set -Eeo pipefail

. /lib.sh

check_event_env
check_input github_token commit_message target_branch

gpg_key_id=$(import_gpg_key "${INPUT_GPG_KEY}" "${INPUT_GPG_KEY_ID}")
import_ssh_key "${INPUT_SSH_KEY}"
configure_git "${gpg_key_id}"

branch="${INPUT_TARGET_BRANCH}"
message="${INPUT_COMMIT_MESSAGE}"
workdir="${INPUT_WORKDIR:-.}"

cd "${workdir}"

if git diff --quiet --exit-code; then
    echo "No changes."
    exit 0
fi

git add .
git commit -m "${message}"
git push --follow-tags origin HEAD:"${branch}"
