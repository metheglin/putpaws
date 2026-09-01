require 'json'
require 'uri'
require 'putpaws/iam/operator_config'

module Putpaws
  module Iam
    # Resolves operator managed policies idempotently.
    # Policy names are derived from the profile name
    # ({service}-operator-{profile}), so re-running converges to
    # CREATE / UPDATE (new policy version) / SKIP instead of piling up policies.
    # The group -> IAM action mapping lives here in code: when putpaws commands
    # evolve, the next `iam:grant` surfaces the permission diff as an UPDATE.
    class GrantCommand
      GROUPS = %w[attach shell deploy logs codebuild scheduler]

      attr_reader :app
      def initialize(app:, account_id: nil, iam_client: nil, sts_client: nil)
        @app = app
        @account_id = account_id
        @iam_client = iam_client
        @sts_client = sts_client
      end

      def iam_client
        @iam_client ||= begin
          require 'aws-sdk-iam'
          Aws::IAM::Client.new(region: app.region)
        end
      end

      def sts_client
        @sts_client ||= Aws::STS::Client.new(region: app.region)
      end

      def account_id
        @account_id ||= sts_client.get_caller_identity.account
      end

      def region
        app.region
      end

      def cluster_arn
        "arn:aws:ecs:#{region}:#{account_id}:cluster/#{app.cluster}"
      end

      def policy_name(profile)
        "#{app.name}-operator-#{profile.name}"
      end

      def policy_arn(profile)
        "arn:aws:iam::#{account_id}:policy/#{policy_name(profile)}"
      end

      def build_policy_document(profile)
        statements = profile.groups.flat_map{|g| statements_for(g.to_s)}
        statements += (profile.extra_statements || [])
        {Version: '2012-10-17', Statement: statements}
      end

      def current_document(profile)
        policy = iam_client.get_policy(policy_arn: policy_arn(profile)).policy
        ver = iam_client.get_policy_version(
          policy_arn: policy_arn(profile),
          version_id: policy.default_version_id
        )
        JSON.parse(URI.decode_www_form_component(ver.policy_version.document))
      rescue Aws::IAM::Errors::NoSuchEntityException
        nil
      end

      def plan(profile)
        current = current_document(profile)
        return :create if current.nil?
        desired = JSON.parse(JSON.generate(build_policy_document(profile)))
        current == desired ? :skip : :update
      end

      def apply!(profile)
        doc = JSON.generate(build_policy_document(profile))
        if current_document(profile).nil?
          iam_client.create_policy(
            policy_name: policy_name(profile),
            policy_document: doc,
            description: "putpaws operator policy for #{app.name} (profile: #{profile.name})"
          )
        else
          prune_versions!(profile)
          iam_client.create_policy_version(
            policy_arn: policy_arn(profile),
            policy_document: doc,
            set_as_default: true
          )
        end
        policy_arn(profile)
      end

      # Managed policies keep at most 5 versions.
      def prune_versions!(profile)
        versions = iam_client.list_policy_versions(policy_arn: policy_arn(profile)).versions
        return if versions.size < 5
        oldest = versions.reject(&:is_default_version).min_by(&:create_date)
        return unless oldest
        iam_client.delete_policy_version(policy_arn: policy_arn(profile), version_id: oldest.version_id)
      end

      def statements_for(group)
        case group
        when 'attach'
          [
            {Sid: 'AttachListTasks', Effect: 'Allow',
             Action: %w[ecs:ListTasks ecs:DescribeTasks],
             Resource: '*',
             Condition: {ArnEquals: {'ecs:cluster' => cluster_arn}}},
            {Sid: 'AttachExec', Effect: 'Allow',
             Action: %w[ecs:ExecuteCommand],
             Resource: "arn:aws:ecs:#{region}:#{account_id}:task/#{app.cluster}/*"},
            {Sid: 'AttachPortForward', Effect: 'Allow',
             Action: %w[ssm:StartSession],
             Resource: [
               "arn:aws:ssm:#{region}::document/AWS-StartPortForwardingSessionToRemoteHost",
               "arn:aws:ecs:#{region}:#{account_id}:task/#{app.cluster}/*",
             ]},
          ]
        when 'shell'
          prefix = app.task_name_prefix || app.name
          [
            {Sid: 'ShellRunTask', Effect: 'Allow',
             Action: %w[ecs:RunTask ecs:StopTask],
             Resource: [
               "arn:aws:ecs:#{region}:#{account_id}:task-definition/#{prefix}*",
               "arn:aws:ecs:#{region}:#{account_id}:task-definition/#{prefix}*:*",
               "arn:aws:ecs:#{region}:#{account_id}:task/#{app.cluster}/*",
             ]},
            {Sid: 'ShellDescribeTasks', Effect: 'Allow',
             Action: %w[ecs:DescribeTasks],
             Resource: '*',
             Condition: {ArnEquals: {'ecs:cluster' => cluster_arn}}},
            {Sid: 'ShellExec', Effect: 'Allow',
             Action: %w[ecs:ExecuteCommand],
             Resource: "arn:aws:ecs:#{region}:#{account_id}:task/#{app.cluster}/*"},
            {Sid: 'ShellPassRole', Effect: 'Allow',
             Action: %w[iam:PassRole],
             Resource: "arn:aws:iam::#{account_id}:role/#{app.name}-*"},
          ]
        when 'deploy'
          [
            {Sid: 'DeployListServices', Effect: 'Allow',
             Action: %w[ecs:ListServices],
             Resource: '*',
             Condition: {ArnEquals: {'ecs:cluster' => cluster_arn}}},
            {Sid: 'DeployUpdateService', Effect: 'Allow',
             Action: %w[ecs:UpdateService ecs:DescribeServices],
             Resource: "arn:aws:ecs:#{region}:#{account_id}:service/#{app.cluster}/#{app.service || '*'}"},
          ]
        when 'logs'
          r = app.log_region || region
          [
            {Sid: 'LogsDescribeGroups', Effect: 'Allow',
             Action: %w[logs:DescribeLogGroups],
             Resource: "arn:aws:logs:#{r}:#{account_id}:log-group:*"},
            {Sid: 'LogsRead', Effect: 'Allow',
             Action: %w[logs:DescribeLogStreams logs:FilterLogEvents logs:GetLogEvents],
             Resource: [
               "arn:aws:logs:#{r}:#{account_id}:log-group:#{app.log_group_prefix}*",
               "arn:aws:logs:#{r}:#{account_id}:log-group:#{app.log_group_prefix}*:*",
             ]},
          ]
        when 'codebuild'
          r = app.build_region || region
          [
            {Sid: 'BuildList', Effect: 'Allow',
             Action: %w[codebuild:ListProjects],
             Resource: '*'},
            {Sid: 'BuildStart', Effect: 'Allow',
             Action: %w[codebuild:StartBuild codebuild:StopBuild codebuild:BatchGetBuilds codebuild:BatchGetProjects],
             Resource: "arn:aws:codebuild:#{r}:#{account_id}:project/#{app.build_project_name_prefix}*"},
            {Sid: 'BuildLogsRead', Effect: 'Allow',
             Action: %w[logs:DescribeLogStreams logs:FilterLogEvents logs:GetLogEvents],
             Resource: [
               "arn:aws:logs:#{r}:#{account_id}:log-group:#{app.build_log_group_prefix}*",
               "arn:aws:logs:#{r}:#{account_id}:log-group:#{app.build_log_group_prefix}*:*",
             ]},
          ]
        when 'scheduler'
          scheduler_role = (app.target && app.target.scheduler_role) ||
            "arn:aws:iam::#{account_id}:role/#{app.name}-*"
          [
            {Sid: 'ScheduleList', Effect: 'Allow',
             Action: %w[scheduler:ListSchedules],
             Resource: '*'},
            {Sid: 'ScheduleManage', Effect: 'Allow',
             Action: %w[scheduler:GetSchedule scheduler:CreateSchedule scheduler:UpdateSchedule],
             Resource: "arn:aws:scheduler:#{region}:#{account_id}:schedule/default/*"},
            {Sid: 'SchedulePassRole', Effect: 'Allow',
             Action: %w[iam:PassRole],
             Resource: scheduler_role},
          ]
        else
          raise "Unknown group: #{group} (available: #{GROUPS.join(', ')})"
        end
      end
    end
  end
end
