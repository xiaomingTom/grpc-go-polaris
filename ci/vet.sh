#!/bin/bash

set -ex  # Exit on error; debugging enabled.
set -o pipefail  # Fail a pipe if any sub-command fails.

# not makes sure the command passed to it does not exit with a return code of 0.
not() {
  # This is required instead of the earlier (! $COMMAND) because subshells and
  # pipefail don't work the same on Darwin as in Linux.
  ! "$@"
}

die() {
  echo "$@" >&2
  exit 1
}

fail_on_output() {
  tee /dev/stderr | not read
}

# Check to make sure it's safe to modify the user's git repo.
git status --porcelain | fail_on_output

# Undo any edits made by this script.
cleanup() {
  git reset --hard HEAD
}
trap cleanup EXIT

PATH="${HOME}/go/bin:${GOROOT}/bin:${PATH}"
go version

if [[ "$1" = "-install" ]]; then
  # Install the pinned versions as defined in module tools.
  pushd ./test/tools
  go install \
    golang.org/x/lint/golint \
    golang.org/x/tools/cmd/goimports \
    honnef.co/go/tools/cmd/staticcheck \
    github.com/client9/misspell/cmd/misspell
  popd
  exit 0
elif [[ "$#" -ne 0 ]]; then
  die "Unknown argument(s): $*"
fi

# - Ensure all source files contain a copyright message.
not git grep -L "\(Copyright (C) [0-9]\{4,\} THL A29 Limited, a Tencent company. All rights reserved.\)\|DO NOT EDIT" -- '*.go'

# - Make sure all tests use leakcheck via Teardown.
not grep -r 'func Test[^(]' test/*.go

# - Do not import x/net/context.
git grep -l 'x/net/context' -- "*.go" | not grep -v ".pb.go"

# - Do not import math/rand for real library code.  Use internal/grpcrand for
#   thread safety.
git grep -l '"math/rand"' -- "*.go" 2>&1 | not grep -v 'scalable_rand.go\|scalable_rand_test.go\|^benchmark\|_suite.go'

misspell -error .

# - gofmt, goimports, golint (with exceptions for generated code), go vet,
# go mod tidy.
# Perform these checks on each module inside polaris-go.
for MOD_FILE in $(find . -name 'go.mod'); do
  MOD_DIR=$(dirname ${MOD_FILE})
  pushd ${MOD_DIR}
  go vet -all ./... | fail_on_output
  gofmt -s -d -l . 2>&1 | fail_on_output
  goimports -l . 2>&1 | not grep -vE "\.pb\.go"
  golint ./... 2>&1 | not grep -vE "\.pb\.go"

  go mod tidy
  git status --porcelain 2>&1 | fail_on_output || \
    (git status; git --no-pager diff; exit 1)
  popd
done

# - Collection of static analysis checks
#
SC_OUT="$(mktemp)"
staticcheck -go 1.9 -checks 'inherit,-ST1015' ./... > "${SC_OUT}" || true
# Error if anything other than deprecation warnings are printed.
not grep -v "is deprecated:.*SA1019" "${SC_OUT}"

# - special golint on package comments.
lint_package_comment_per_package() {
  # Number of files in this go package.
  fileCount=$(go list -f '{{len .GoFiles}}' $1)
  if [ ${fileCount} -eq 0 ]; then
    return 0
  fi
  # Number of package errors generated by golint.
  lintPackageCommentErrorsCount=$(golint --min_confidence 0 $1 | grep -c "should have a package comment")
  # golint complains about every file that's missing the package comment. If the
  # number of files for this package is greater than the number of errors, there's
  # at least one file with package comment, good. Otherwise, fail.
  if [ ${fileCount} -le ${lintPackageCommentErrorsCount} ]; then
    echo "Package $1 (with ${fileCount} files) is missing package comment"
    return 1
  fi
}
lint_package_comment() {
  set +ex

  count=0
  for i in $(go list ./...); do
    lint_package_comment_per_package "$i"
    ((count += $?))
  done

  set -ex
  return $count
}
lint_package_comment

echo SUCCESS