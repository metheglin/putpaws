require 'fileutils'
require 'putpaws/version'

module Putpaws
  module Ai
    # `putpaws away`: put paws away — take your paws off and let AI take over.
    # Installs a guide for AI agents (Claude Code etc.) into the host project:
    # a skill file plus a pointer block in CLAUDE.md / AGENTS.md.
    # Re-runnable: everything is regenerated in place.
    class Guide
      SKILL_PATH = File.join('.claude', 'skills', 'putpaws', 'SKILL.md')
      BEGIN_MARK = '<!-- putpaws:begin -->'
      END_MARK = '<!-- putpaws:end -->'

      def self.install!(root: '.', services: nil)
        services ||= Putpaws::ApplicationConfig.names
        skill_path = File.join(root, SKILL_PATH)
        FileUtils.mkdir_p(File.dirname(skill_path))
        File.write(skill_path, skill_content(services: services), encoding: 'UTF-8')
        pointer_path = pointer_target(root)
        update_pointer!(pointer_path)
        [skill_path, pointer_path]
      end

      # Prefer an existing CLAUDE.md; otherwise use AGENTS.md (created if absent).
      def self.pointer_target(root)
        claude = File.join(root, 'CLAUDE.md')
        return claude if File.exist?(claude)
        File.join(root, 'AGENTS.md')
      end

      def self.update_pointer!(path)
        block = pointer_block
        content = File.exist?(path) ? File.read(path, encoding: 'UTF-8') : ''
        if content.include?(BEGIN_MARK)
          content = content.sub(/#{Regexp.escape(BEGIN_MARK)}.*#{Regexp.escape(END_MARK)}/m, block.strip)
        else
          content = content.empty? ? block : content.rstrip + "\n\n" + block
        end
        File.write(path, content, encoding: 'UTF-8')
      end

      def self.pointer_block
        <<~MD
          #{BEGIN_MARK}
          ## putpaws (AWS operations)

          This project uses the putpaws gem for AWS/ECS operations (logs, deploy, migrations, one-off tasks).
          Read `.claude/skills/putpaws/SKILL.md` for commands and safety notes before running AWS operations.
          Quick reference: environments are the folders under `.putpaws/` that hold `application.json`;
          `bundle exec putpaws <environment> info` shows the settings, launches and schedules without touching AWS.
          #{END_MARK}
        MD
      end

      def self.skill_content(services: [])
        services_line = services.empty? ? '(none configured yet — check .putpaws/<environment>/application.json)' : services.join(', ')
        <<~MD
          ---
          name: putpaws
          description: AWS operations for this project (CloudWatch logs, ECS deploy, db:migrate and one-off tasks on Fargate, CodeBuild CI) via the putpaws CLI. Use when asked to investigate logs, deploy, run rake tasks on AWS, or inspect ECS services.
          ---

          # putpaws

          Capistrano-style AWS operation commands. General form:

              bundle exec putpaws <environment> <command> key=value

          The first argument is always the environment.
          Environments in this project: #{services_line}
          (environments are the folders under `.putpaws/` that hold `application.json`)

          Discover commands with `bundle exec putpaws -T` (or `-D` for full descriptions).

          Starting a task always goes through a *launch*: a named combination of task definition,
          network and overrides saved in `.putpaws/<environment>/launch.json`.
          `launch=<name>` picks one; `cpu=` / `memory=` / `cmd=` / `env=` / `network=` override it for one run.

          ## Read-only commands (safe to run without asking)

          - `bundle exec putpaws <environment> info` — settings, launches and schedules, no AWS access
          - `bundle exec putpaws <environment> launch:list` — launches with every field, no AWS access
          - `bundle exec putpaws <environment> ecs:run launch=<name> dry=true` — show what would be started, starts nothing
          - `bundle exec putpaws <environment> scheduler:deploy schedule=<name> dry=true` — show the schedule that would be deployed
          - `bundle exec putpaws <environment> log:tail since=2h` — CloudWatch logs (units: s/m/h/d/w, add `for=1h` to bound the range)
          - `bundle exec putpaws <environment> log:tailf` — follow logs (long-running; prefer `log:tail` in automation)
          - `bundle exec putpaws ahead` — dry-run of provisioning (CREATE/UPDATE/SKIP)

          ## Mutating commands (confirm with the user before running)

          - `bundle exec putpaws <environment> ecs:run launch=app cmd='bundle exec rake db:migrate' wait=true`
            — runs a one-off command on a temporary Fargate task and exits non-zero on failure.
            The best choice for migrations and rake tasks. Non-interactive as long as `launch=` is given.
            A launch that saves its own `command` needs no `cmd=`.
          - `bundle exec putpaws <environment> ecs:deploy wait=true` — redeploy the service (force new deployment)
          - `bundle exec putpaws <environment> code_build:build branch=main` — start the CI build (build + push + deploy per buildspec)
          - `bundle exec putpaws <environment> scheduler:deploy schedule=<name>` — deploy a schedule to EventBridge Scheduler
          - `save=<name>` on `ecs:run` writes the resolved launch into `launch.json`

          ## Interactive commands (avoid in non-TTY sessions; meant for humans)

          - `ecs:attach`, `ecs:shell`, `ecs:forward` — open live sessions into containers
          - `ecs:run` without `launch=` / `target=` and `scheduler:deploy` without `schedule=` — ask which one to use
          - `ready`, `steady`, `up`, `iam:grant` — provisioning flows with confirmation prompts

          ## Config files (source of truth, safe to read)

          - `.putpaws/<environment>/application.json` — region / cluster and the prefixes that find tasks, logs and builds
          - `.putpaws/<environment>/launch.json` — named launches (`target` / `network` + overrides)
          - `.putpaws/<environment>/schedule.json` — schedules (a launch name + when to run)
          - `.putpaws/infra.json` — parts shared by all environments: network (subnets/security groups) and target (cluster/taskdef)
          - `.putpaws/operators.json` — operator permission profiles
          - `.putpaws/provisioning/<service>/` — provisioning inputs (provision.json), state, IAM role drafts

          ## Suggested permission allowlist (.claude/settings.json)

              "permissions": {
                "allow": [
                  "Bash(bundle exec putpaws -T*)",
                  "Bash(bundle exec putpaws * info)",
                  "Bash(bundle exec putpaws * launch:list)",
                  "Bash(bundle exec putpaws * log:*)"
                ]
              }

          ---
          Generated by putpaws #{Putpaws::VERSION}. Refresh with `bundle exec putpaws away` after updating the gem.
        MD
      end
    end
  end
end
