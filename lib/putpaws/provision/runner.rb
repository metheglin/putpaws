require 'json'
require 'fileutils'
require 'putpaws/provision/util'
require 'putpaws/provision/state'
require 'putpaws/provision/aws_clients'
require 'putpaws/provision/policy_generator'
require 'putpaws/provision/config_writer'
require 'putpaws/provision/resources/base'
require 'putpaws/provision/resources/iam_role'
require 'putpaws/provision/resources/security_group'
require 'putpaws/provision/resources/cluster'
require 'putpaws/provision/resources/log_group'
require 'putpaws/provision/resources/task_definition'
require 'putpaws/provision/resources/service'
require 'putpaws/provision/resources/codebuild_project'

module Putpaws
  module Provision
    # Orchestrates the provisioning commands:
    #   ready  (provision:init)  ... interview + drafts
    #   steady (provision:roles) ... create IAM roles from the reviewed drafts
    #   ahead  (provision:plan)  ... dry-run
    #   up     (provision:up)    ... build the rest, idempotent
    #
    # Running `steady` IS the user's explicit confirmation of the drafts:
    # `up` never touches IAM and stops until the role ARNs are filled.
    class Runner
      ROLE_KEYS = [:task_execution_role_arn, :task_role_arn, :codebuild_role_arn, :scheduler_role_arn]
      ROLE_DRAFTS = {
        task_execution_role_arn: 'role-task-execution.json',
        task_role_arn: 'role-task.json',
        codebuild_role_arn: 'role-codebuild.json',
        scheduler_role_arn: 'role-scheduler.json',
      }

      attr_reader :config, :state, :clients, :prompt, :io
      def initialize(config:, state: nil, clients: nil, prompt: nil, io: $stdout)
        @config = config
        @state = state || State.load(config)
        @clients = clients || AwsClients.new(region: config.region)
        @prompt = prompt
        @io = io
      end

      def blank_role_keys
        ROLE_KEYS.select{|k| Util.blank?(config.roles[k])}
      end

      # A role is managed by `steady` when its ARN is blank (to be created) or
      # when the filled ARN points at the draft's own role name (created by a
      # previous `steady`; kept updatable). An ARN with a different role name
      # is treated as external (org-managed) and never touched.
      def steady_role_entries
        args = {config: config, state: state, clients: clients}
        ROLE_KEYS.map do |key|
          resource = Resources::IamRole.new(roles_key: key, draft_file: ROLE_DRAFTS[key], **args)
          arn = config.roles[key]
          external = !Util.blank?(arn) && arn.split('/').last != resource.name
          {key: key, resource: resource, external: external}
        end
      end

      def service_resources
        args = {config: config, state: state, clients: clients}
        [
          Resources::SecurityGroup.new(**args),
          Resources::LogGroup.new(log_group_name: config.log_group, output_key: :log_group, **args),
          Resources::Cluster.new(**args),
          *config.preset.task_definitions.map{|entry| Resources::TaskDefinition.new(entry: entry, **args)},
          Resources::Service.new(**args),
        ]
      end

      def devops_resources
        args = {config: config, state: state, clients: clients}
        [
          Resources::LogGroup.new(log_group_name: config.build_log_group, output_key: :build_log_group, **args),
          Resources::CodebuildProject.new(**args),
        ]
      end

      def missing_devops_requirements
        missing = []
        missing << 'devops.source_repository (provision.json)' if Util.blank?(config.devops_settings[:source_repository])
        missing
      end

      # `putpaws steady`: show each draft inline, confirm one by one, then
      # apply it as-is and fill the ARN into provision.json.
      # Idempotent: re-run after editing drafts to update.
      def steady!
        io.puts "Applying IAM roles from drafts in #{config.policies_dir}/"
        filled = {}
        steady_role_entries.each do |entry|
          if entry[:external]
            print_action('SKIP', 'IamRole', "#{config.roles[entry[:key]]} (external)")
            next
          end
          resource = entry[:resource]
          action = resource.plan[:action]

          if action == :skip
            print_action('SKIP', 'IamRole', resource.name)
          else
            io.puts ""
            io.puts "=== #{resource.draft_file} -> #{action.to_s.upcase} role: #{resource.name} ==="
            io.puts JSON.pretty_generate(resource.draft)
            unless prompt.yes?("Apply this content as role #{resource.name}?")
              io.puts "Skipped #{resource.name}"
              next
            end
            print_action(action.to_s.upcase, 'IamRole', resource.name)
          end

          outputs = resource.ensure!
          state.merge_resources!(outputs)
          filled[entry[:key]] = outputs[entry[:key]]
        end
        write_roles_to_provision_json!(filled)
        io.puts "Next: check with `putpaws ahead`, then build with `putpaws up`."
      end

      def plan
        io.puts "Service: #{config.service_name} (region: #{config.region}, account: #{config.account_id})"
        io.puts ""
        resources = steady_role_entries.reject{|e| e[:external]}.map{|e| e[:resource]}
        resources += service_resources
        resources += devops_resources if missing_devops_requirements.empty?
        resources.each do |r|
          p = r.plan
          print_action(p[:action].to_s.upcase, p[:kind], p[:name])
        end
        if blank_role_keys.any?
          io.puts "[stop point] IAM roles are not created yet. Review the drafts, then run `putpaws steady`."
        end
        if missing_devops_requirements.any?
          io.puts "[stop point] Devops step is blocked. Fill in: #{missing_devops_requirements.join(', ')}"
        end
        check_ssm_parameters
      end

      def up!
        if blank_role_keys.any?
          io.puts "[stop point] IAM roles are not ready: #{blank_role_keys.join(', ')}"
          io.puts "1. Review and edit the drafts in #{config.policies_dir}/"
          io.puts "2. Run `putpaws steady` to create the roles and fill their ARNs."
          io.puts "   (or fill in existing role ARNs in provision.json yourself)"
          return
        end

        io.puts "Applying service step for #{config.service_name} (account: #{config.account_id}, region: #{config.region})"
        apply_resources(service_resources)
        state.mark_step!(:service, 'done')

        ConfigWriter.new(config: config, state: state, prompt: prompt, io: io).apply!

        if missing_devops_requirements.any?
          io.puts "[stop point] Devops step is not ready. Fill in: #{missing_devops_requirements.join(', ')}"
          io.puts "Then run `putpaws up` again."
          return
        end

        io.puts "Applying devops step"
        apply_resources(devops_resources)
        state.mark_step!(:devops, 'done')
        ConfigWriter.new(config: config, state: state, prompt: prompt, io: io).apply!

        io.puts "All steps completed."
        io.puts "Verify with: bundle exec putpaws #{config.service_name} ecs:run cmd='echo ok' wait=true"
      end

      private

      def print_action(action, kind, name)
        io.puts format("%-8s %-18s %s", action, kind, name)
      end

      def write_roles_to_provision_json!(filled)
        return if filled.empty?
        path = config.dir.join('provision.json')
        data = JSON.parse(File.read(path), symbolize_names: true)
        data[:roles] ||= {}
        changed = filled.reject{|k, arn| data[:roles][k] == arn}
        return if changed.empty?
        FileUtils.cp(path, "#{path}.bak")
        changed.each{|k, arn| data[:roles][k] = arn}
        Util.write_json(path, data)
        config.data[:roles] = data[:roles]
        io.puts "Filled role ARNs into #{path}:"
        changed.each{|k, arn| io.puts "  #{k}: #{arn}"}
      end

      def apply_resources(resources)
        resources.each do |r|
          print_action(r.plan[:action].to_s.upcase, r.kind, r.name)
          outputs = r.ensure!
          state.merge_resources!(outputs)
        end
      end

      def check_ssm_parameters
        paths = config.resolved_secrets.values
        return if paths.empty?
        res = clients.ssm.describe_parameters(
          parameter_filters: [{key: 'Name', option: 'Equals', values: paths}]
        )
        existing = res.parameters.map(&:name)
        missing = paths - existing
        if missing.any?
          io.puts "[warning] Missing SSM parameters (register them yourself, putpaws never touches values):"
          missing.each{|p| io.puts "  aws ssm put-parameter --type SecureString --name #{p} --value '...'"}
        end
      rescue StandardError => e
        io.puts "(ssm parameter check skipped: #{e.class})"
      end
    end
  end
end
