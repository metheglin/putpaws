# Put your pAWS up!!

## Command names

The short commands follow a "put your paws ..." image:

- `putpaws ready` ... put paws ready: — place your paws and prepare
- `putpaws steady` ... put paws steady: — hold steady, right before the start
- `putpaws up` ... put paws up: — everything is ready, raise them up
- `putpaws ahead` ... put paws ahead: — reach ahead and probe (dry-run)
- `putpaws away` ... put paws away: — take your paws off and let AI take over

## How it is organized

Every command starts with the environment:

```
bundle exec putpaws <environment> <task> key=value ...
```

Settings live in one folder per environment. Inside an environment, what you need to
**operate** things that are already running is kept apart from what you need to **start** tasks.

```
.putpaws/
├── infra.json                  # parts (network / target). Shared by all environments
├── awesome-api-production/     # one folder per environment (folder name = first argument)
│   ├── application.json        # environment settings: region / cluster + prefixes to find tasks, logs, builds
│   ├── launch.json             # named launches: which task definition, on which network, with which overrides
│   └── schedule.json           # schedules: a launch + when to run it
├── awesome-api-staging/
│   └── ...
└── provisioning/               # provisioning inputs and state
```

| File | Role | Written by | `putpaws up` |
|---|---|---|---|
| `infra.json` | parts used to start tasks (`network` / `target`) | putpaws (you can add parts) | writes its own keys only |
| `<environment>/application.json` | operate what is running | putpaws | generates / updates the keys it knows |
| `<environment>/launch.json` | named launches | you | adds missing names only, never rewrites |
| `<environment>/schedule.json` | schedules | you | never touched |

- The environments are the folders right under `.putpaws/` that hold `application.json`.
- A **launch** is a named combination of task definition, network and overrides.
  `ecs:run`, `ecs:shell` and the scheduler all start tasks from the same launches,
  so something you ran by hand is exactly what the schedule runs.
- ECS takes the network (subnets, security groups, public IP) when a task is started, not from the
  task definition. That is why one task definition can be started on another network or in another
  size just by overriding a launch.

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

Bundled presets (ECS Fargate, `awsvpc`):

- `rails` (default) ... one `app` container on port 8080. Assumes the Rails 8 default Dockerfile,
  where [Thruster](https://github.com/basecamp/thruster) fronts Puma and does what an nginx sidecar used to
  (HTTP/2, asset caching / compression, X-Sendfile); TLS terminates at the ALB.
  Thruster listens on port 80 by default, but the Rails Dockerfile runs as a non-root user and
  Fargate does not let non-root processes bind ports below 1024 (unlike local Docker, which sets
  `net.ipv4.ip_unprivileged_port_start=0`), so the preset sets `HTTP_PORT=8080` and
  `container_port: 8080`; point the ALB target group at 8080. The Dockerfile needs no change
  (`EXPOSE 80` is metadata only). Older Rails apps work too by adding the `thruster` gem and
  starting with `bin/thrust bin/rails server`, or by setting `container_port` to the Puma port
  and dropping `HTTP_PORT`.
- `rails-nginx` ... same `app` task definition plus a `web` one with an nginx sidecar on port 80.
  The sidecar is a stock nginx image with no proxy config, so point `nginx_image` at your own image
  that proxies to `localhost:3000`. Keep this only when you need something Thruster does not do
  (maintenance pages, custom rewrites, proxy-level auth).

Need another task definition (Ex: a batch worker)? Add an entry to `task_definitions` of the
copied preset with its own template; `up` creates it, writes its `target` into `infra.json`
and adds a launch named after its suffix.

Security groups are either specified (one or more existing ones; putpaws never touches their rules)
or a new one is created for the service when left empty on `ready`.

When the service step completes, the new service is reflected into the operation settings
(`service_name` is the environment name), so `ecs:attach`, `ecs:shell`, `ecs:run` and `log:*`
work immediately. `up` writes only what it knows the right answer for and never overrides your choices:

| Target | What `up` does |
|---|---|
| `{service_name}/application.json` | generated / updated after showing the diff. Keys you added by hand (`log_region` ...) are kept |
| `infra.json` `network.{service_name}` | generated / updated after showing the diff |
| `infra.json` `target.{family}` | generated / updated, one per task definition of the preset (`{service_name}-{suffix}`) |
| `{service_name}/launch.json` | a launch named after each suffix (`app` ...) is added **when that name is absent**: `{"target": "{family}", "network": "{service_name}"}`. Existing launches are never rewritten |
| `{service_name}/schedule.json` | never touched |

Parts you added to `infra.json` (Ex: a public network) and launches you edited stay as they are.
Secrets are handled by reference only: task definitions point to existing
SSM parameters (Ex: `/{service_name}/RAILS_MASTER_KEY`) and putpaws never touches the values.

A scheduler role is always created too, and every `target` of infra.json carries it,
so `scheduler:deploy` works any time by just writing `{service_name}/schedule.json`.

The CPU architecture is declared once as `cpu_architecture` (`ARM64` / `X86_64`) in the preset
defaults (overridable per service via `overrides`), and applied consistently to both
task definitions (`runtimePlatform`) and CodeBuild (environment type and image).
The bundled presets default to `ARM64`; projects whose copied preset predates this setting
fall back to `X86_64` so nothing changes silently. When switching an existing service to ARM,
run the CI build right after `up` so an ARM image exists before tasks roll
(`devops.environment_type` / `environment_image` can override the derivation for staged migration).

CodeBuild is created as CI: builds run inside the VPC with the same subnets and
security group as the service, so `db:migrate` against RDS works from the build.
Note that the private subnets need a NAT gateway (or VPC endpoints) so that
builds can reach GitHub / ECR / CloudWatch Logs.

## Operator permissions

Declare named operator profiles in `.putpaws/operators.json` (generated with examples on first run),
then resolve them into managed policies per environment, idempotently
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
The policy is named `{environment}-operator-{profile}`. Attaching it to users/groups is left to your admin
(an attach command example is printed).

## AI setup

`putpaws away` installs a guide for AI agents (Claude Code etc.) into the project:
`.claude/skills/putpaws/SKILL.md` (commands, read-only vs mutating classification,
non-interactive recipes, suggested permission allowlist) and a pointer block in
`CLAUDE.md` (or `AGENTS.md` when there is no CLAUDE.md). Re-run it after updating putpaws.

```
bundle exec putpaws away
```

## Example

### Info

Show the settings of an environment with its launches and schedules, without touching AWS

```
bundle exec putpaws awesome-api-staging info
```

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
What gets started is a **launch** of the environment (`launch.json`).

```
# A saved launch as it is (the launch carries its own command)
bundle exec putpaws awesome-api-staging ecs:run launch=seed

# A saved launch with the command given on the spot.
# Pass wait=true to wait until the task stops and check the exit code
bundle exec putpaws awesome-api-staging ecs:run launch=app cmd='bundle exec rake db:migrate' wait=true

# Override part of a saved launch for this run only
bundle exec putpaws awesome-api-staging ecs:run launch=seed network=awesome-api-staging cpu=8192 memory=32768

# Assemble a launch on the spot without saving anything
bundle exec putpaws awesome-api-staging ecs:run target=awesome-api-staging-app network=awesome-api-staging cmd='bin/rails db:migrate:status'

# Save what you tried under another name, then run it
bundle exec putpaws awesome-api-staging ecs:run launch=seed cpu=4096 memory=16384 save=seed-small

# Show what would be started, and start nothing
bundle exec putpaws awesome-api-staging ecs:run launch=seed dry=true
```

| Parameter | Meaning |
|---|---|
| `launch=` | name of the launch to use. Without it, `target=` and `network=` are required |
| `target=` / `network=` | names in `infra.json` |
| `cmd=` | command (a string, run through `/bin/sh -c`) |
| `container=` / `cpu=` / `memory=` | container to override / task size (a valid Fargate combination) |
| `env='NAME=value NAME2=value2'` | environment variables (space separated, merged into those of the launch) |
| `capacity_provider=` / `task_role=` / `ephemeral_storage=` | `FARGATE` or `FARGATE_SPOT` / task role ARN / GiB |
| `save=name` | save the resolved launch into `launch.json` under that name. An existing name shows the diff and asks first |
| `dry=true` | show the resolved launch and start nothing |
| `wait=true` / `ttl=` / `keep=true` | how this run behaves; never saved into a launch |

With neither `launch=` nor `target=` / `network=`, the launches of the environment are listed to choose from.
`ecs:run` needs a command, either saved in the launch or given as `cmd=`.

Launch a temporary task for operation and attach to it (like SSH-ing into the environment).
The task follows the launch except that its command is replaced by `sleep <ttl>`,
so it always terminates itself when ttl passes even if your shell is gone.

```
# ttl is 30 minutes by default
bundle exec putpaws awesome-api-staging ecs:shell launch=app

# Specify ttl: "45" and "45m" mean 45 minutes, "90s" and "2h" also work
bundle exec putpaws awesome-api-staging ecs:shell launch=app ttl=45m

# The task is stopped immediately when you exit the shell.
# Pass keep=true to keep it running until ttl passes.
bundle exec putpaws awesome-api-staging ecs:shell launch=app keep=true
```

Temporary tasks are launched with `group` / `started_by` set to `putpaws-run` or `putpaws-shell`,
so you can identify them on the AWS console and on the task list of `ecs:attach` / `ecs:forward`.

### Launch

List the launches of an environment

```
bundle exec putpaws awesome-api-staging launch:list
```

A launch is resolved in this order every time; later ones win field by field:

1. defaults of the task definition (putpaws passes nothing)
2. the launch in `launch.json`
3. for a schedule: the overrides written in `schedule.json`
4. for a manual run: the command-line parameters

`env` is merged name by name; every other field is replaced as a whole.
Before anything starts, putpaws checks that `target` and `network` exist in `infra.json` and that the
cluster of the target is the cluster of the environment (`region` / `cluster` of `application.json`),
so a launch that points at the parts of another environment by mistake is stopped.

### Scheduler

Deploy a schedule of the environment to EventBridge Scheduler.
It is created (or updated) as `<environment>-<schedule>`, Ex: `awesome-api-staging-nightly-seed`.

```
bundle exec putpaws awesome-api-staging scheduler:deploy schedule=nightly-seed

# Show what would be deployed, and deploy nothing
bundle exec putpaws awesome-api-staging scheduler:deploy schedule=nightly-seed dry=true

bundle exec putpaws awesome-api-staging scheduler:list
```

Without `schedule=`, the schedules of the environment are listed to choose from.

### CodeBuild

Start the CI build. By default it is fire-and-forget; pass `wait=true` to wait
until the build completes (phases are printed) and exit non-zero on failure.

```
bundle exec putpaws awesome-api-staging code_build:build branch=main wait=true
```

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

## Settings

### `.putpaws/<environment>/application.json`

One per environment. The folder name is the environment name, so there is no name inside the file.

```
{
  "region": "ap-northeast-1",
  "cluster": "awesome-api-staging",
  "service": "awesome-api-staging",
  "task_name_prefix": "awesome-api-staging",
  "log_group_prefix": "/ecs/awesome-api-staging",
  "build_project_name_prefix": "awesome-api-staging",
  "build_log_group_prefix": "/aws/codebuild/awesome-api-staging"
}
```

- `region` / `cluster` are used both to operate and to start tasks.
- The prefixes find what is running (tasks, logs, builds). With the service name as
  `task_name_prefix`, tasks of `-app` / `-extract` / `-seed` are all found.
- `service` is the long-running service for `ecs:deploy`. When null, the services of the cluster are listed to choose from.
- Optional: `ecs_region` / `log_region` / `build_region`.
- `network` / `target` / `schedules` do not belong here (see `launch.json` / `schedule.json`).

### `.putpaws/infra.json`

Parts, each with a unique name. They do not belong to an environment.

```
{
  "network": {
    "awesome-api-staging": {
      "subnets": ["subnet-0aaa", "subnet-0bbb"],
      "security_groups": ["sg-0aaa"],
      "assign_public_ip": "DISABLED"
    },
    "awesome-api-staging-public": {
      "subnets": ["subnet-0ccc"],
      "security_groups": ["sg-0aaa"],
      "assign_public_ip": "ENABLED"
    }
  },
  "target": {
    "awesome-api-staging-app": {
      "scheduler_role": "arn:aws:iam::123456789012:role/awesome-api-staging-scheduler",
      "cluster": "arn:aws:ecs:ap-northeast-1:123456789012:cluster/awesome-api-staging",
      "task_definition": "awesome-api-staging-app",
      "container_name": "app"
    }
  }
}
```

### `.putpaws/<environment>/launch.json`

Named launches, unique within the environment.

```
{
  "app":     { "target": "awesome-api-staging-app", "network": "awesome-api-staging" },
  "migrate": {
    "target": "awesome-api-staging-app",
    "network": "awesome-api-staging",
    "command": "bin/rails db:migrate"
  },
  "seed-small": {
    "target": "awesome-api-staging-seed",
    "network": "awesome-api-staging-public",
    "cpu": 4096,
    "memory": 16384,
    "env": { "RAILS_LOG_LEVEL": "info" },
    "command": "bin/rails runner 'Seed.new.perform'"
  }
}
```

| Field | Required | Meaning | Where it goes on RunTask |
|---|---|---|---|
| `target` | yes | name of a `target` in `infra.json` | `cluster` / `task_definition` |
| `network` | yes | name of a `network` in `infra.json` | `network_configuration` |
| `command` | | a string is wrapped in `/bin/sh -c`; an array is passed as it is | `overrides.container_overrides[].command` |
| `container` | | container to override. Defaults to `container_name` of the target | `overrides.container_overrides[].name` |
| `env` | | `{ "NAME": "value" }` | `overrides.container_overrides[].environment` |
| `cpu` / `memory` | | task size (a valid Fargate combination) | `overrides.cpu` / `overrides.memory` |
| `ephemeral_storage` | | ephemeral storage in GiB | `overrides.ephemeral_storage` |
| `task_role` | | task role ARN | `overrides.task_role_arn` |
| `capacity_provider` | | `FARGATE` (default) / `FARGATE_SPOT` | `capacity_provider_strategy` instead of `launch_type` |

Only what ECS lets you decide when a task is started can be written. Image, sidecars and log
destination belong to the task definition. An unknown field is an error, so that a setting which
has no effect cannot go unnoticed. `FARGATE_SPOT` needs the capacity provider to be associated with the cluster.

### `.putpaws/<environment>/schedule.json`

A schedule is the name of a launch of the same environment plus when to run it.

```
{
  "nightly-seed": {
    "launch": "seed-small",
    "schedule_expression": "cron(0 18 * * ? *)",
    "schedule_expression_timezone": "Asia/Tokyo"
  },
  "weekly-report": {
    "launch": "app",
    "command": "bin/rails runner 'Report.deliver_weekly'",
    "cpu": 2048,
    "memory": 4096,
    "schedule_expression": "cron(0 9 ? * MON *)",
    "schedule_expression_timezone": "Asia/Tokyo",
    "state": "ENABLED"
  }
}
```

- `launch` is required. `network` / `target` / `region` come from the launch and the environment.
- Launch fields written here (`command` / `env` / `cpu` ...) override the launch for this schedule only.
- Everything else (`schedule_expression` ...) is passed to EventBridge Scheduler
  `create_schedule` / `update_schedule` as it is.

## Migrating from 0.1.x

1.0 does not read the 0.1.x layout. While `.putpaws/application.json` or `.putpaws/schedule.json`
exists, commands that take an environment stop and tell you so.

1. Run `bundle exec putpaws up`. It generates `.putpaws/{service_name}/application.json`,
   the default launches in `launch.json` and reports the legacy files (it never reads or deletes them).
   Without provisioning, write `application.json` by hand as shown above.
2. Move what you had per entry into `launch.json`: an old entry `awesome-api-staging-seed` with
   `network` / `target` becomes a launch `seed` with the same `network` / `target`.
3. Move schedules into `{environment}/schedule.json`: replace `network` / `target` / `region` with
   `"launch": "<name>"`. The schedule on AWS is now named `<environment>-<schedule>`, so a schedule
   deployed by 0.1.x under its bare name stays there until you delete it.
4. Delete `.putpaws/application.json` and `.putpaws/schedule.json`.
5. Rewrite your commands:

| 0.1.x | 1.0 |
|---|---|
| `putpaws awesome-api-staging-app log:tailf` | `putpaws awesome-api-staging log:tailf` |
| `putpaws awesome-api-staging-app ecs:deploy` | `putpaws awesome-api-staging ecs:deploy` |
| `putpaws awesome-api-staging-app ecs:run cmd='...'` | `putpaws awesome-api-staging ecs:run launch=app cmd='...'` |
| `putpaws awesome-api-staging-app ecs:shell` | `putpaws awesome-api-staging ecs:shell launch=app` |
| `putpaws awesome-api-staging scheduler:deploy` | `putpaws awesome-api-staging scheduler:deploy schedule=<name>` |

## Development

```
bundle exec rake test
```
