---
status: current
---

# Git remotes

New hosted projects use their primary host, normally GitHub, plus a private
SourceHut repository. Ordinary pushes update both hosts; fetches and pulls
use the primary host. Honor explicit choices for other hosting arrangements.
Adoption records this project's actual URLs in the commands below in place of
the `your-account/your-project` placeholders. Preserve existing custom
settings. Prefer SSH URLs for GitHub: HTTPS pushes that change workflow files
need a token with the `workflow` scope.

## Create the private SourceHut repository

Set up the primary repository as `origin` using the requested visibility.
Complete the initial commit and required checks before publishing it.
Infer the SourceHut account from known remotes or account information; do not
assume it matches the GitHub username. Ask if the account cannot be established.

For a new repository with no `sourcehut` remote, run:

```sh
git remote add sourcehut git@git.sr.ht:~jubi/radio
git push --atomic -o visibility=private sourcehut 'refs/heads/*:refs/heads/*' 'refs/tags/*:refs/tags/*'
```

SourceHut creates the repository on its first push. Explicitly set
`visibility=private` on that push, including when the primary repository is
public. The command copies committed local branches and tags. It does not
commit uncommitted files or copy remote-tracking branches.

If the SourceHut repository already exists, confirm its identity and private
visibility through its authenticated settings or API before uploading. Set
it private there when needed: an up-to-date push may not run the hook that
applies a visibility option. Do not force-push over existing history.
If creation or upload fails, report the error and repair it before enabling
dual pushes. Do not fall back to public visibility.

## Configure ordinary pushes

Inspect the current settings first:

```sh
git remote -v
git remote get-url --push --all origin
git config --get remote.pushDefault
git config --get-regexp 'branch\..*\.push[Rr]emote'
```

A missing optional setting can return a nonzero status. Preserve the primary
push URL, including its existing SSH or HTTPS form. For a new project with one
primary destination and no explicit push URLs, run the following, using the
primary URL exactly as `git remote get-url --push origin` prints it:

```sh
git remote set-url --add --push origin git@github.com:jubishop/radio.git
git remote set-url --add --push origin git@git.sr.ht:~jubi/radio
git config --local remote.pushDefault origin
git config --local push.autoSetupRemote true
```

Add only missing URLs when repeating setup. Preserve existing destinations and
resolve conflicting branch-specific `pushRemote` settings deliberately.
Keep `remote.origin.url` unchanged so fetches and pulls still use the primary
host. Keep the named `sourcehut` remote for targeted operations.

Do not save `visibility=private` in `push.pushOption`: ordinary dual pushes
would also send that SourceHut option to the primary host, which may reject it.
The repository retains its private setting after creation; ordinary pushes
do not need the option.

## Verify and use

```sh
git remote get-url origin
git remote get-url --push --all origin
git for-each-ref --format='%(objectname) %(refname)' refs/heads refs/tags
git ls-remote --refs sourcehut 'refs/heads/*' 'refs/tags/*'
git push --dry-run
```

Check that fetching uses the primary URL, pushing lists both URLs, and the
SourceHut branch and tag revisions match those uploaded. Confirm private
visibility in the authenticated repository settings or API. An anonymous
request must not expose the repository. A 404 alone does not prove privacy:
also confirm that the authenticated repository exists.

The dry run must contact both hosts successfully. Then use `git push` to
publish the selected branch to both. New branches establish their upstream
automatically; `git push --tags` sends tags to both destinations. A normal
push does not copy every branch or synchronize changes made directly on a host.

The two pushes are separate operations. A failure does not undo the push to
the other host. Inspect the output, fix the error, and retry. Use
`git push sourcehut <branch>` for a SourceHut-only retry.

SourceHut requests at most one Git network operation per minute for bulk
automation. Space bulk uploads and their Git verification calls accordingly.
See its [push options and automation guidance](https://man.sr.ht/git.sr.ht/)
and Git's [multiple push URL documentation](https://git-scm.com/docs/git-push#REMOTES).

## Fresh clones

Additional remotes, push URLs, and local Git settings are not copied by
`git clone`. Use this project's recorded URLs to add `sourcehut` and repeat
the local configuration above. Verify both destinations with a dry run.
The repositories already exist, so cloning does not require another creation
push or a visibility change. Routine `bin/setup` stays local.
