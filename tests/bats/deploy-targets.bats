#!/usr/bin/env bats

# deploy-targets.sh: what the deploy-pr-targets input may say, and how the
# overlays in it are looked up.

SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/deploy-targets.sh"

setup() {
  export DEPLOY_PR_TARGETS='{"prod": ["k8s/overlays/acc", "k8s/overlays/prd"], "staging": ["./k8s/overlays/tst/"]}'
  export ENVIRONMENTS='["dev", "staging", "prod"]'
}

@test "accepts the documented shape" {
  run "${SCRIPT}" validate
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "first is the head of the environment's list, normalised" {
  run "${SCRIPT}" first prod
  [ "$output" = "k8s/overlays/acc" ]
  run "${SCRIPT}" first staging
  [ "$output" = "k8s/overlays/tst" ]
}

@test "an environment with no list has no first overlay" {
  run "${SCRIPT}" first dev
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "next follows the list and stops at its end" {
  run "${SCRIPT}" next acc
  [ "$output" = "k8s/overlays/prd" ]
  run "${SCRIPT}" next prd
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "next never crosses into another environment's list" {
  export DEPLOY_PR_TARGETS='{"staging": ["o/tst"], "prod": ["o/acc", "o/prd"]}'
  run "${SCRIPT}" next tst
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "path looks an overlay up by name" {
  run "${SCRIPT}" path prd
  [ "$output" = "k8s/overlays/prd" ]
  run "${SCRIPT}" path nope
  [ -z "$output" ]
}

@test "paths lists every overlay" {
  run "${SCRIPT}" paths
  [ "${lines[0]}" = "k8s/overlays/acc" ]
  [ "${lines[1]}" = "k8s/overlays/prd" ]
  [ "${lines[2]}" = "k8s/overlays/tst" ]
}

@test "refuses what is not an object" {
  DEPLOY_PR_TARGETS='["k8s/overlays/acc"]' run "${SCRIPT}" validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be a JSON object"* ]]
  DEPLOY_PR_TARGETS='not json' run "${SCRIPT}" validate
  [ "$status" -eq 1 ]
}

@test "refuses an empty list and a non-string entry" {
  DEPLOY_PR_TARGETS='{"prod": []}' run "${SCRIPT}" validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"'prod' must be a non-empty list"* ]]
  DEPLOY_PR_TARGETS='{"prod": ["a", 3]}' run "${SCRIPT}" validate
  [ "$status" -eq 1 ]
}

@test "refuses an environment that is not in environments" {
  DEPLOY_PR_TARGETS='{"production": ["k8s/overlays/prd"]}' run "${SCRIPT}" validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"not in environments: production"* ]]
}

@test "without environments, any key is taken" {
  unset ENVIRONMENTS
  DEPLOY_PR_TARGETS='{"production": ["k8s/overlays/prd"]}' run "${SCRIPT}" validate
  [ "$status" -eq 0 ]
}

@test "refuses absolute paths and dot segments" {
  DEPLOY_PR_TARGETS='{"prod": ["/k8s/overlays/prd"]}' run "${SCRIPT}" validate
  [ "$status" -eq 1 ]
  DEPLOY_PR_TARGETS='{"prod": ["k8s/../prd"]}' run "${SCRIPT}" validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"'.' or '..'"* ]]
}

@test "refuses the same overlay twice, and two overlays with one name" {
  DEPLOY_PR_TARGETS='{"prod": ["k8s/overlays/acc", "k8s/overlays/acc/"]}' run "${SCRIPT}" validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"listed twice"* ]]
  DEPLOY_PR_TARGETS='{"staging": ["a/overlays/prd"], "prod": ["b/overlays/prd"]}' run "${SCRIPT}" validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"more than one overlay is called 'prd'"* ]]
}

@test "every lookup validates first" {
  DEPLOY_PR_TARGETS='{"prod": []}' run "${SCRIPT}" first prod
  [ "$status" -eq 1 ]
}
