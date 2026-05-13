#!/usr/bin/env bats

@test "docker promotion retag uses pull/tag/push flow" {
  run grep -F 'docker pull "${SOURCE}" || RETAG_OK=false' action.yml
  [ "$status" -eq 0 ]

  run grep -F 'docker tag "${SOURCE}" "${NEW_TAG}" || RETAG_OK=false' action.yml
  [ "$status" -eq 0 ]

  run grep -F 'docker push "${NEW_TAG}" || RETAG_OK=false' action.yml
  [ "$status" -eq 0 ]
}

@test "docker promotion no longer uses imagetools create for retag" {
  run grep -F 'docker buildx imagetools create' action.yml
  [ "$status" -ne 0 ]
}
