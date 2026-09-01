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
        services ||= Putpaws::ApplicationConfig.all.map(&:name)
        skill_path = File.join(root, SKILL_PATH)
        FileUtils.mkdir_p(File.dirname(skill_path))
        File.write(skill_path, skill_content(services: services))
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
        content = File.exist?(path) ? File.read(path) : ''
        if content.include?(BEGIN_MARK)
          content = content.sub(/#{Regexp.escape(BEGIN_MARK)}.*#{Regexp.escape(END_MARK)}/m, block.strip)
        else
          content = content.empty? ? block : content.rstrip + "\n\n" + block
        end
        File.write(path, content)
      end

      def self.pointer_block
        <<~MD
          #{BEGIN_MARK}
          ## putpaws (AWS operations)

          This project uses the putpaws gem for AWS/ECS operations (logs, deploy, migrations, one-off tasks).
          Read `.claude/skills/putpaws/SKILL.md` for commands and safety notes before running AWS operations.
          Quick reference: services are the top-level keys of `.putpaws/application.json`;
          `bundle exec putpaws <service> info` shows resolved settings without touching AWS.
          #{END_MARK}
        MD
      end

      def self.skill_content(services: [])
        services_line = services.empty? ? '(none configured yet — check .putpaws/application.json)' : services.join(', ')
        <<~MD
          ---
          name: putpaws
          description: AWS operations for this project (CloudWatch logs, ECS deploy, db:migrate and one-off tasks on Fargate, CodeBuild CI) via the putpaws CLI. Use when asked to investigate logs, deploy, run rake tasks on AWS, or inspect ECS services.
          ---

          # putpaws

          Capistrano-style AWS operation commands. General form:

              bundle exec putpaws <service> <command> key=value

          Services in this project: #{services_line}
          (services are the top-level keys of `.putpaws/application.json`)

          Discover commands with `bundle exec putpaws -T` (or `-D` for full descriptions).

          ## Read-only commands (safe to run without asking)

          - `bundle exec putpaws <service> info` — resolved settings, no AWS access
          - `bundle exec putpaws <service> log:tail since=2h` — CloudWatch logs (units: s/m/h/d/w, add `for=1h` to bound the range)
          - `bundle exec putpaws <service> log:tailf` — follow logs (long-running; prefer `log:tail` in automation)
          - `bundle exec putpaws ahead` — dry-run of provisioning (CREATE/UPDATE/SKIP)

          ## Mutating commands (confirm with the user before running)

          - `bundle exec putpaws <service> ecs:run cmd='bundle exec rake db:migrate' wait=true`
            — runs a one-off command on a temporary Fargate task and exits non-zero on failure.
            The best choice for migrations and rake tasks. Fully non-interactive.
          - `bundle exec putpaws <service> ecs:deploy wait=true` — redeploy the service (force new deployment)
          - `bundle exec putpaws <service> code_build:build branch=main` — start the CI build (build + push + deploy per buildspec)
          - `bundle exec putpaws <service> scheduler:deploy` — deploy schedules from `.putpaws/schedule.json`

          ## Interactive commands (avoid in non-TTY sessions; meant for humans)

          - `ecs:attach`, `ecs:shell`, `ecs:forward` — open live sessions into containers
          - `ready`, `steady`, `up`, `iam:grant` — provisioning flows with confirmation prompts

          ## Config files (source of truth, safe to read)

          - `.putpaws/application.json` — services and their cluster/log/build settings
          - `.putpaws/infra.json` — network (subnets/security groups) and target (cluster/taskdef) definitions
          - `.putpaws/schedule.json` — named schedules, `.putpaws/operators.json` — operator permission profiles
          - `.putpaws/provisioning/<service>/` — provisioning inputs (provision.json), state, IAM role drafts

          ## Suggested permission allowlist (.claude/settings.json)

              "permissions": {
                "allow": [
                  "Bash(bundle exec putpaws -T*)",
                  "Bash(bundle exec putpaws * info)",
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
