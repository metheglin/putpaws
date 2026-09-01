# Put your paws up!!

## Provisioning

Build service infra (security group / ECS cluster / task definitions / service / log groups / CodeBuild) idempotently.
Deletion is out of scope on purpose: putpaws only creates and updates.

```
# Interview basic infra (existing VPC / ECR / SES / S3 / SSM parameter prefix)
# and generate provision.json + IAM role drafts
bundle exec putpaws ready

# After reviewing/editing the drafts under policies/, create the IAM roles
# from them as-is and fill their ARNs into provision.json. Idempotent:
# edit a draft and run again to update the role.
bundle exec putpaws steady

# Dry-run: show what would be created / updated / skipped
bundle exec putpaws ahead

# Build the rest as far as possible. `up` stops with instructions where a manual
# step is required. Fix things by hand, then just run `up` again. Safe to re-run any time.
bundle exec putpaws up
```

Running `steady` is your explicit confirmation of the drafts: `up` never touches IAM
and stops until the role ARNs are filled. Filling in an existing role ARN in
provision.json instead makes `steady` leave that role alone
(useful when IAM is managed by another team).

Files live under `.putpaws/provisioning/`:

- `provisioning/{service_name}/provision.json` ... inputs (edit by hand; `steady` fills the role ARNs)
- `provisioning/{service_name}/state.json` ... created resource info (written by putpaws)
- `provisioning/{service_name}/policies/` ... IAM role drafts to review, applied as-is by `putpaws steady`
- `provisioning/presets/{preset}/` ... defaults and task definition templates (copied here on `ready`, edit freely)

Presets are searched in this order: project local (`.putpaws/provisioning/presets/`),
user global (directories in `PUTPAWS_PRESETS_PATH`, then `~/.putpaws/presets/`), and the ones bundled in the gem.
Whichever you pick on `ready` is copied into the project so the project owns its snapshot.

Security groups are either specified (one or more existing ones; putpaws never touches their rules)
or a new one is created for the service when left empty on `ready`.

When the service step completes, the new service is reflected into
`.putpaws/application.json` and `.putpaws/infra.json` (diff is shown and confirmed),
so `ecs:attach`, `ecs:shell`, `ecs:run` and `log:*` work immediately.
Secrets are handled by reference only: task definitions point to existing
SSM parameters (Ex: `/{service_name}/RAILS_MASTER_KEY`) and putpaws never touches the values.

A scheduler role is always created too, and the `target` entry of infra.json carries it,
so `scheduler:deploy` works any time by just writing `.putpaws/schedule.json`.

CodeBuild is created as CI: builds run inside the VPC with the same subnets and
security group as the service, so `db:migrate` against RDS works from the build.
Note that the private subnets need a NAT gateway (or VPC endpoints) so that
builds can reach GitHub / ECR / CloudWatch Logs.

## Operator permissions

Declare named operator profiles in `.putpaws/operators.json` (generated with examples on first run),
then resolve them into managed policies per service, idempotently
(CREATE / UPDATE as a new policy version / SKIP — re-running never piles up policies):

```
bundle exec putpaws awesome-api-staging iam:grant profile=developer
```

```
{
  "developer": { "groups": ["attach", "shell", "deploy", "logs", "codebuild"] },
  "viewer": { "groups": ["logs"] }
}
```

Groups map to putpaws command namespaces: `attach` (ecs:attach/forward), `shell` (ecs:shell/run —
note this implies reading all secrets of the service), `deploy` (ecs:deploy), `logs` (log:*),
`codebuild` (code_build:build), `scheduler` (scheduler:deploy).
`extra_statements` on a profile appends raw IAM statements.
The policy is named `{service}-operator-{profile}`. Attaching it to users/groups is left to your admin
(an attach command example is printed).

## Example

### ECS

Attach to staging specific container

```
bundle exec putpaws awesome-api-staging ecs:attach container=app
```

Run port forwarding session through specific container

```
bundle exec putpaws awesome-api-staging ecs:forward container=app remote=example-rds-host:3306 local=:1050
# local=:1050 is optional by the way, then random number is selected.
# Please check standard output in your shell for the auto-generated local port.

# You can access specified remote host with subsequent command in another shell like:
mysql -u awesome_user -p --port 1050 -h 127.0.0.1
```

Redeploy the service (update-service with force new deployment).
With a mutable image tag like `latest`, this rolls out the newly pushed image.

```
bundle exec putpaws awesome-api-staging ecs:deploy

# Optionally change desired count / task definition, and wait until stable
bundle exec putpaws awesome-api-staging ecs:deploy desired=2 taskdef=awesome-api-staging-web wait=true
```

Run a command on a temporary task. The task terminates itself when the command finishes.

```
bundle exec putpaws awesome-api-staging ecs:run cmd='bundle exec rake db:migrate'

# Pass wait=true to wait until the task stops and check the exit code
bundle exec putpaws awesome-api-staging ecs:run cmd='bundle exec rake db:migrate' wait=true
```

Launch a temporary task for operation and attach to it (like SSH-ing into the environment).
The task is launched with its command overridden by `sleep <ttl>`, so it always terminates itself when ttl passes even if your shell is gone.

```
# ttl is 30 minutes by default
bundle exec putpaws awesome-api-staging ecs:shell

# Specify ttl: "45" and "45m" mean 45 minutes, "90s" and "2h" also work
bundle exec putpaws awesome-api-staging ecs:shell ttl=45m

# The task is stopped immediately when you exit the shell.
# Pass keep=true to keep it running until ttl passes.
bundle exec putpaws awesome-api-staging ecs:shell keep=true
```

Temporary tasks are launched with `group` / `started_by` set to `putpaws-run` or `putpaws-shell`,
so you can identify them on the AWS console and on the task list of `ecs:attach` / `ecs:forward`.

`ecs:run` and `ecs:shell` require `network` and `target` in `.putpaws/application.json`,
which refer to the `network` / `target` sections of `.putpaws/infra.json` (the same ones used by scheduler).

### CloudWatch Logs

`tail -f`

```
bundle exec putpaws awesome-api-staging log:tailf
```

Find logs between specific date range using time symbol

- `s`: second
- `m`: minute
- `h`: hour
- `d`: day
- `w`: week

```
# Find logs since 2 hours ago
bundle exec putpaws awesome-api-staging log:tailf since=2h

# Find logs since 1 day ago for 3 hours
bundle exec putpaws awesome-api-staging log:tail since=1d for=3h
```

## Set up

```
gem 'putpaws'
```

## Setting Example

`.putpaws/application.json`

```
{
  "awesome-api-staging": {
    "region": "ap-northeast-1",
    "cluster": "cluster-staging",
    "service": null,
    "task_name_prefix": "awesome-api",
    "log_group_prefix": "/ecs/awesome/awesome-api-staging",
    "log_region": null,
    "build_log_group_prefix": "/aws/codebuild/awesome-api-staging",
    "build_project_name_prefix": "awesome-api-staging",
    "network": "awesome-private-staging",
    "target": "awesome-staging"
  },
  "awesome-api-production": {
    "region": "ap-northeast-1",
    "cluster": "cluster-production",
    "service": null,
    "task_name_prefix": "awesome-api",
    "log_group_prefix": "/ecs/awesome/awesome-api-production",
    "log_region": null
  }
}
```
