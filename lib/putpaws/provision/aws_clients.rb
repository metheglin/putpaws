module Putpaws
  module Provision
    # Lazy client factory. Clients can be injected for testing.
    class AwsClients
      attr_reader :region
      def initialize(region:, ec2: nil, ecs: nil, logs: nil, codebuild: nil, ssm: nil, iam: nil)
        @region = region
        @ec2 = ec2
        @ecs = ecs
        @logs = logs
        @codebuild = codebuild
        @ssm = ssm
        @iam = iam
      end

      def iam
        @iam ||= begin
          require 'aws-sdk-iam'
          Aws::IAM::Client.new(region: region)
        end
      end

      def ec2
        @ec2 ||= begin
          require 'aws-sdk-ec2'
          Aws::EC2::Client.new(region: region)
        end
      end

      def ecs
        @ecs ||= begin
          require 'aws-sdk-ecs'
          Aws::ECS::Client.new(region: region)
        end
      end

      def logs
        @logs ||= begin
          require 'aws-sdk-cloudwatchlogs'
          Aws::CloudWatchLogs::Client.new(region: region)
        end
      end

      def codebuild
        @codebuild ||= begin
          require 'aws-sdk-codebuild'
          Aws::CodeBuild::Client.new(region: region)
        end
      end

      def ssm
        @ssm ||= begin
          require 'aws-sdk-ssm'
          Aws::SSM::Client.new(region: region)
        end
      end
    end
  end
end
