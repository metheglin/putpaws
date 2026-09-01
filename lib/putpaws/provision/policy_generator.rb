require 'fileutils'
require 'putpaws/provision/util'

module Putpaws
  module Provision
    # Generates drafts (たたき台) of IAM policies and roles.
    # These are starting points to review and edit by hand before creating.
    class PolicyGenerator
      ECS_TASKS_TRUST = {
        Version: '2012-10-17',
        Statement: [{Effect: 'Allow', Principal: {Service: 'ecs-tasks.amazonaws.com'}, Action: 'sts:AssumeRole'}]
      }
      CODEBUILD_TRUST = {
        Version: '2012-10-17',
        Statement: [{Effect: 'Allow', Principal: {Service: 'codebuild.amazonaws.com'}, Action: 'sts:AssumeRole'}]
      }

      def scheduler_trust
        {
          Version: '2012-10-17',
          Statement: [{
            Effect: 'Allow',
            Principal: {Service: 'scheduler.amazonaws.com'},
            Action: 'sts:AssumeRole',
            # confused deputy protection: only schedules in this account
            Condition: {StringEquals: {'aws:SourceAccount' => account_id}},
          }]
        }
      end

      attr_reader :config
      def initialize(config)
        @config = config
      end

      def service_name; config.service_name; end
      def region; config.region; end
      def account_id; config.account_id; end

      def write_step1_drafts!
        dir = config.policies_dir
        FileUtils.mkdir_p(dir)
        Util.write_json(dir.join('role-task-execution.json'), task_execution_role_draft)
        Util.write_json(dir.join('role-task.json'), task_role_draft)
        Util.write_json(dir.join('role-codebuild.json'), codebuild_role_draft)
        Util.write_json(dir.join('role-scheduler.json'), scheduler_role_draft)
        %w[role-task-execution.json role-task.json role-codebuild.json role-scheduler.json]
          .map{|f| dir.join(f).to_s}
      end

      def task_execution_role_draft
        statements = [
          {
            Sid: 'EcrAuth',
            Effect: 'Allow',
            Action: %w[ecr:GetAuthorizationToken],
            Resource: '*',
          },
          {
            Sid: 'EcrPull',
            Effect: 'Allow',
            Action: %w[ecr:BatchCheckLayerAvailability ecr:GetDownloadUrlForLayer ecr:BatchGetImage],
            Resource: config.base[:ecr_repository_arn],
          },
          {
            Sid: 'WriteLogs',
            Effect: 'Allow',
            Action: %w[logs:CreateLogStream logs:PutLogEvents],
            Resource: "arn:aws:logs:#{region}:#{account_id}:log-group:#{config.log_group}:*",
          },
        ]
        unless config.resolved_secrets.empty?
          statements << {
            Sid: 'ReadSecrets',
            Effect: 'Allow',
            Action: %w[ssm:GetParameters],
            Resource: "arn:aws:ssm:#{region}:#{account_id}:parameter#{config.ssm_parameter_prefix}/*",
          }
        end
        {
          SuggestedRoleName: "#{service_name}-task-execution",
          SuggestedPolicyName: "#{service_name}-task-execution-policy",
          AssumeRolePolicyDocument: ECS_TASKS_TRUST,
          PolicyDocument: {Version: '2012-10-17', Statement: statements},
        }
      end

      def task_role_draft
        statements = [
          {
            Sid: 'EcsExec',
            Effect: 'Allow',
            Action: %w[
              ssmmessages:CreateControlChannel ssmmessages:CreateDataChannel
              ssmmessages:OpenControlChannel ssmmessages:OpenDataChannel
            ],
            Resource: '*',
          },
        ]
        unless Util.blank?(config.base[:ses_identity_arn])
          statements << {
            Sid: 'SendMail',
            Effect: 'Allow',
            Action: %w[ses:SendEmail ses:SendRawEmail],
            Resource: config.base[:ses_identity_arn],
          }
        end
        unless Util.blank?(config.base[:s3_bucket_arn])
          statements << {
            Sid: 'UseBucket',
            Effect: 'Allow',
            Action: %w[s3:GetObject s3:PutObject s3:DeleteObject s3:ListBucket],
            Resource: [config.base[:s3_bucket_arn], "#{config.base[:s3_bucket_arn]}/*"],
          }
        end
        {
          SuggestedRoleName: "#{service_name}-task",
          SuggestedPolicyName: "#{service_name}-task-policy",
          AssumeRolePolicyDocument: ECS_TASKS_TRUST,
          PolicyDocument: {Version: '2012-10-17', Statement: statements},
        }
      end

      def codebuild_role_draft
        {
          SuggestedRoleName: "#{service_name}-codebuild",
          SuggestedPolicyName: "#{service_name}-codebuild-policy",
          AssumeRolePolicyDocument: CODEBUILD_TRUST,
          PolicyDocument: {
            Version: '2012-10-17',
            Statement: [
              {
                Sid: 'WriteBuildLogs',
                Effect: 'Allow',
                Action: %w[logs:CreateLogStream logs:PutLogEvents],
                Resource: "arn:aws:logs:#{region}:#{account_id}:log-group:#{config.build_log_group}:*",
              },
              {
                Sid: 'EcrAuth',
                Effect: 'Allow',
                Action: %w[ecr:GetAuthorizationToken],
                Resource: '*',
              },
              {
                Sid: 'EcrPushPull',
                Effect: 'Allow',
                Action: %w[
                  ecr:BatchCheckLayerAvailability ecr:GetDownloadUrlForLayer ecr:BatchGetImage
                  ecr:InitiateLayerUpload ecr:UploadLayerPart ecr:CompleteLayerUpload ecr:PutImage
                ],
                Resource: config.base[:ecr_repository_arn],
              },
              # Deploy at the end of the build:
              # aws ecs update-service --force-new-deployment (+ wait services-stable)
              {
                Sid: 'DeployService',
                Effect: 'Allow',
                Action: %w[ecs:UpdateService ecs:DescribeServices],
                Resource: "arn:aws:ecs:#{region}:#{account_id}:service/#{config.cluster_name}/#{service_name}",
              },
              # Required because builds run inside the VPC (vpc_config).
              {
                Sid: 'ManageBuildEni',
                Effect: 'Allow',
                Action: %w[
                  ec2:CreateNetworkInterface ec2:DescribeNetworkInterfaces ec2:DeleteNetworkInterface
                  ec2:DescribeSubnets ec2:DescribeSecurityGroups ec2:DescribeDhcpOptions ec2:DescribeVpcs
                ],
                Resource: '*',
              },
              {
                Sid: 'CreateBuildEniPermission',
                Effect: 'Allow',
                Action: %w[ec2:CreateNetworkInterfacePermission],
                Resource: "arn:aws:ec2:#{region}:#{account_id}:network-interface/*",
                Condition: {
                  StringEquals: {
                    'ec2:AuthorizedService' => 'codebuild.amazonaws.com',
                    'ec2:Subnet' => (config.base[:subnets] || []).map{|s|
                      "arn:aws:ec2:#{region}:#{account_id}:subnet/#{s}"
                    },
                  }
                },
              },
            ]
          },
        }
      end

      # Assumed by EventBridge Scheduler to launch tasks (scheduler:deploy).
      # Created for every service so that schedules can be added any time.
      def scheduler_role_draft
        {
          SuggestedRoleName: "#{service_name}-scheduler",
          SuggestedPolicyName: "#{service_name}-scheduler-policy",
          AssumeRolePolicyDocument: scheduler_trust,
          PolicyDocument: {
            Version: '2012-10-17',
            Statement: [
              {
                Sid: 'RunScheduledTask',
                Effect: 'Allow',
                Action: %w[ecs:RunTask],
                Resource: [
                  "arn:aws:ecs:#{region}:#{account_id}:task-definition/#{service_name}-*",
                  "arn:aws:ecs:#{region}:#{account_id}:task-definition/#{service_name}-*:*",
                ],
              },
              {
                Sid: 'PassRolesToTasks',
                Effect: 'Allow',
                Action: %w[iam:PassRole],
                Resource: "arn:aws:iam::#{account_id}:role/#{service_name}-*",
              },
            ]
          },
        }
      end
    end
  end
end
