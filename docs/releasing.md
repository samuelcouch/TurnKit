# Releasing TurnKit

`.github/workflows/release.yml` publishes to RubyGems on a `v*` tag push. It checks
out the event's exact commit, verifies the tag equals `v#{TurnKit::VERSION}`, runs
the test suite including PostgreSQL-backed tests, then invokes
[`rubygems/release-gem`](https://github.com/rubygems/release-gem/tree/v1.4.1).
It uses Ruby 3.3.10, Bundler 2.5.22 and the committed `Gemfile.lock` with frozen
dependency resolution. No paid model-provider credentials are needed for these tests.

## One-time configuration

The maintainer reports the RubyGems Trusted Publisher is already configured for
owner `samuelcouch`, repository `TurnKit`, workflow `release.yml`, environment
`release`. Verify the repository name matches the GitHub repository identity
exactly if RubyGems rejects the identity (the repository URL is also commonly
written lowercase). Do not configure a long-lived RubyGems API key.

In GitHub **Settings → Environments**, create the environment named **release**:

- Optionally require a maintainer reviewer and prevent self-review if supported
  by the repository's plan. Approval gates the entire release job.
- Under deployment branches and tags, select specific rules and permit **tags**
  matching `v*`; do not accidentally configure only a branch rule.
- Optionally add a repository tag ruleset for `v*` restricting creation to release
  maintainers and preventing tag updates/deletions. Ensure it permits the release
  action's required Git operations. Never move a published version tag.

The job requests `id-token: write` for short-lived RubyGems OIDC credentials and
`contents: write` for the action's Bundler release/tag-push contract. Checkout
does not persist credentials. No external settings are created by committing
this workflow; a maintainer must configure them in GitHub.

## Prepare and release

1. Choose an unused gem version. Update `lib/turnkit/version.rb`, move the
   relevant `CHANGELOG.md` Unreleased entries into a dated version heading, and
   update migration/upgrade notes for breaking changes.
2. Run `bundle install` to refresh the local gem version in `Gemfile.lock`.
   Commit the lockfile; do not broadly update dependencies as an incidental
   release step. If Ruby/Bundler pins change, update the workflow consistently.
3. With a dedicated test database configured, run:

   ```sh
   TURNKIT_TEST_DATABASE_URL=postgresql:///turnkit_test bundle exec rake test
   gem build turnkit.gemspec --output /tmp/turnkit-release-check.gem
   ```

   The database tests rebuild their namespaced tables. Never use a production
   database. Inspect gem contents, especially new `lib/` files; examples and
   workflow files are intentionally not packaged by the gemspec.
4. Commit and review the release changes, including the workflow and lockfile.
   Push the approved release commit through the repository's normal process.
   Do not tag a dirty worktree or an unreviewed commit.
5. Only when ready to publish, run the explicit tag push below from that clean,
   approved commit. **The push triggers publication**, subject to environment
   approval. These commands are instructions, not an automatically executed step:

   ```sh
   test -z "$(git status --porcelain)" || exit 1
   version="$(ruby -Ilib -rturnkit/version -e 'print TurnKit::VERSION')"
   git tag -a "v$version" -m "Release $version"
   git push origin "refs/tags/v$version"
   ```

6. Approve the environment job if configured, inspect Actions results, and verify
   the version on RubyGems. The action runs `bundle exec rake release` and waits
   for RubyGems availability; it does **not** create a GitHub Release page.

If publication fails, inspect whether RubyGems already accepted the version
before retrying. Published gem versions cannot be overwritten. Never force-push
a tag to repair a release; prepare a new version when code must change.

Local workflow validation: run `actionlint .github/workflows/release.yml`.
Actual OIDC/environment authorization can only be verified by an authorized
GitHub run; local tests and gem builds do not validate that exchange.
