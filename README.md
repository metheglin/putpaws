# Put your paws up!!

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
