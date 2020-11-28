#!/bin/bash


die() {
  echo ::error::${@}
  exit 1
}

# Check if given required input variables
# are specified, and abort if not.
check_input() {
  local varnames="${@}"
  local input_varname
  local env_varname

  if [ -n "${varnames}" ]; then
    for input_varname in ${varnames}; do
      env_varname="INPUT_${input_varname^^}"
      if [ -z "${!env_varname}" ]; then
        die "The required '${input_varname}' input variable is not specified."
      fi
    done
  fi
}

# Check if given required environment variables
# are specified, and abort if not.
check_event_env() {
  local env_varname

  for env_varname in GITHUB_REF GITHUB_EVENT_PATH; do
    if [ -z "${env_varname}" ]; then
      die "The required '${env_varname}' env variable is not specified."
    fi
  done
}

# Make a GET request to Github API v3
# Args:
#    $1: The API path to request, e.g "/user"
# Environment:
#    INPUT_GITHUB_TOKEN: GitHub token with appropriate scope
get() {
  curl -sSL -X GET \
    -H "Authorization: token ${INPUT_GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github.v3+json" \
    -H "Accept: application/vnd.github.antiope-preview+json" \
    "https://api.github.com${1}"
}

# Make a POST request to Github API v3
# Args:
#    $1: The API path to request, e.g "/user"
# Stdin:
#    POST request body.
# Environment:
#    INPUT_GITHUB_TOKEN: GitHub token with appropriate scope
# Returns:
#    HTTP response with numeric status on the last line.
post() {
  curl -sSL -v -w "%{http_code}" \
    -H "Authorization: token ${INPUT_GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github.v3+json" \
    -H "Accept: application/vnd.github.antiope-preview+json" \
    -d @- \
    "https://api.github.com${1}"
}

_prepare_graphql_query() {
  # Fold newlines and escape the quotes.
  echo "${1}" \
    | sed -e ':a' -e 'N' -e '$!ba' -e 's/\n/ /g' \
    | sed -e 's/"/\\"/g'
}

# Make a request to Github GraphQL API
# Args:
#    $1: GraphQL query.
gql() {
  local auth_header="Authorization: bearer ${INPUT_GITHUB_TOKEN}"
  echo {\"query\": \"$(_prepare_graphql_query "${1}")\"} \
    | curl -sSL -H "${auth_header}" -d @- "https://api.github.com/graphql"
}

# jq wrapper with raw output by default.
jqr() {
  jq --raw-output "${@}"
}

# Run a jq operation on Github event JSON
# Args:
#    $@: Arguments to jq.
jqevent() {
  jqr "${@}" "${GITHUB_EVENT_PATH}"
}

# Wrapper around GPG to make it behave in non-interactive mode.
# Args:
#    $@: Arguments to gpg.
gpgb() {
  /gpg-wrapper --batch --no-tty "${@}"
}

# Check if the specified user is a maintainer of a given repository.
# Args:
#    $1: Github username.
#    $2: Organization name.
#    $3: Repository name.
is_maintainer() {
  local perm
  local request
  local user="${1}"
  local org="${2}"
  local repo="${3}"

  read -r -d '' request <<EOF
    {
      organization(login: "${org}") {
        teams(first: 100, userLogins: ["${user}"]) {
          edges {
            node {
              name
              repositories(first: 100, query: "${repo}") {
                edges {
                  node {
                    name
                  }
                  permission
                }
              }
            }
          }
        }
      }
    }
EOF
  perm=$(gql "${request}" \
          | jqr ".data.organization.teams.edges[]?
                 | .node.repositories.edges[]
                 | select(.node.name == \"${repo}\")
                 | .permission")

  [[ "${perm}" = *MAINTAIN* || "${perm}" = *ADMIN* ]]
}

# Import the given GPG private key into the local keychain.
# Args:
#    $1: GPG private key (suitable for gpg --import)
#    $2: Optional key id to use for signatures.  If not specified,
#        and the input key contains only one signing subkey, that subkey
#        is used.
# Returns:
#    The id of the signing key.
import_gpg_key() {
  local gpg_key="${1}"
  local gpg_key_id="${2}"

  if [ -n "${gpg_key}" ]; then
    if [ -z "${gpg_key_id}" ]; then
      gpg_key_id=$(echo "${gpg_key}" \
                   | gpgb --import --import-options show-only --with-colons \
                   | grep '^sec:' \
                   | cut -f 5 -d':')

      if [[ $(echo "${gpg_key_id}" | wc -l) -gt 1 ]]; then
        die "Multiple keys found in INPUT_GPG_KEY, please specify " \
            "the key id via INPUT_GPG_KEY_ID".
      fi
    fi

    echo "${gpg_key}" \
      | gpgb --import
  fi

  echo "${gpg_key_id}"
}

# Import the given SSH private key for the current user.
# Args:
#    $1: SSH private key.
import_ssh_key() {
  local ssh_key="${1}"

  if [ -n "${ssh_key}" ]; then
    mkdir -p "${HOME}/.ssh"
    echo "${ssh_key}" > "${HOME}/.ssh/id_rsa"
    chmod 600 "${HOME}/.ssh/id_rsa"
  fi
}

# Configure git using the information about the current Github user.
# Args:
#    $1: Optional GPG key id to use for git object signing.
# Environment:
#    INPUT_GITHUB_TOKEN: the token of a Github user to use for git operations.
configure_git() {
  local gpg_key_id="${1}"
  local user=$(get /user)
  local login=$(echo "${user}" | jqr .login)
  local username=$(echo "${user}" | jqr .name)
  local email=$(echo "${user}" | jqr .email)

  git config --global user.name "${username}"
  git config --global user.email "${email}"
  git config --global gpg.program "/gpg-wrapper"
  git config --global credential.helper "store --file=${HOME}/.git-credentials"
  git config --global "credential.https://github.com.username" "${login}"

  echo "https://${login}:${INPUT_GITHUB_TOKEN}@github.com" \
    >> "${HOME}/.git-credentials"

  chmod 600 "${HOME}/.git-credentials"

  if [ -n "${gpg_key_id}" ]; then
    git config --global commit.gpgsign true
    git config --global user.signingkey "${gpg_key_id}"
  fi
}