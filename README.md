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
    "build_project_name_prefix": "awesome-api-staging"
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
