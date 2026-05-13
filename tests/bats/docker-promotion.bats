#!/usr/bin/env bats

# Behaviour-level assertions for the image-promotion retag flow. Loose
# patterns (not full-line greps) so refactors that preserve semantics
# don't break the test.

@test "imagetools create is the primary retag path (preserves multi-arch)" {
  grep -Eq 'docker buildx imagetools create.*--tag.*NEW_TAG.*SOURCE' action.yml
}

@test "stable promotion also tags :latest via imagetools create" {
  grep -Eq 'docker buildx imagetools create.*--tag.*NEW_TAG.*--tag.*IMAGE.*:latest.*SOURCE' action.yml
}

@test "pull/tag/push fallback is gated on the referrers-index parse error" {
  grep -Eq 'failed to decode referrers index' action.yml
}

@test "pull/tag/push fallback runs all four steps for prerelease retag" {
  grep -Eq 'docker pull "?\$\{?SOURCE' action.yml
  grep -Eq 'docker tag "?\$\{?SOURCE.*\$\{?NEW_TAG' action.yml
  grep -Eq 'docker push "?\$\{?NEW_TAG' action.yml
}

@test "pull/tag/push fallback handles :latest for stable retag" {
  grep -Eq 'docker tag "?\$\{?SOURCE.*\$\{?IMAGE.*:latest' action.yml
  grep -Eq 'docker push "?\$\{?IMAGE.*:latest' action.yml
}

@test "pull/tag/push fallback warns about losing multi-arch" {
  grep -Eq 'multi-arch' action.yml
}
