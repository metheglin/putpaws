require "minitest/autorun"
require "tmpdir"
require "json"
require "fileutils"
require "stringio"
require "open3"
require "rbconfig"

require "rake"
require "putpaws/version"
require "putpaws/config_file"
require "putpaws/application_config"
require "putpaws/launch_config"
require "putpaws/launch_resolver"
require "putpaws/schedule_config"

module Putpaws
  # Answers yes? / select with what the test prepared, and records what was asked.
  class FakePrompt
    attr_reader :questions
    def initialize(yes: true, select: nil)
      @yes = yes
      @select = select
      @questions = []
    end

    def yes?(question, **)
      @questions << question
      @yes
    end

    def select(question, choices, **)
      @questions << question
      @select || (choices.is_a?(Hash) ? choices.values.first : choices.first)
    end
  end

  class TestCase < Minitest::Test
    ACCOUNT = '123456789012'
    REGION = 'ap-northeast-1'
    ENVIRONMENT = 'minaone-production'

    attr_reader :root

    def setup
      @project = Dir.mktmpdir('putpaws-test')
      @root = File.join(@project, '.putpaws')
      FileUtils.mkdir_p(@root)
      Putpaws::ConfigFile.root = @root
    end

    def teardown
      Putpaws::ConfigFile.root = nil
      FileUtils.remove_entry(@project)
    end

    def project_dir
      @project
    end

    def write_json(relative, data)
      path = File.join(root, relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate(data) + "\n")
      path
    end

    def read_json(relative)
      JSON.parse(File.read(File.join(root, relative)))
    end

    def cluster_arn(name = ENVIRONMENT, region: REGION)
      "arn:aws:ecs:#{region}:#{ACCOUNT}:cluster/#{name}"
    end

    def target_part(family, cluster: cluster_arn)
      {
        scheduler_role: "arn:aws:iam::#{ACCOUNT}:role/#{ENVIRONMENT}-scheduler",
        cluster: cluster,
        task_definition: family,
        container_name: 'app',
      }
    end

    def application_data
      {
        region: REGION,
        cluster: ENVIRONMENT,
        service: ENVIRONMENT,
        task_name_prefix: ENVIRONMENT,
        log_group_prefix: "/ecs/#{ENVIRONMENT}",
        build_project_name_prefix: ENVIRONMENT,
        build_log_group_prefix: "/aws/codebuild/#{ENVIRONMENT}",
      }
    end

    # A project in the 1.0 layout with one environment.
    def write_project(launches: nil, schedules: nil)
      write_json('infra.json', {
        network: {
          ENVIRONMENT => {subnets: %w[subnet-a subnet-b], security_groups: %w[sg-1], assign_public_ip: 'DISABLED'},
          "#{ENVIRONMENT}-public" => {subnets: %w[subnet-p], security_groups: %w[sg-1], assign_public_ip: 'ENABLED'},
        },
        target: {
          "#{ENVIRONMENT}-app" => target_part("#{ENVIRONMENT}-app"),
          "#{ENVIRONMENT}-seed" => target_part("#{ENVIRONMENT}-seed"),
          "other-staging-app" => target_part("other-staging-app", cluster: cluster_arn('other-staging')),
          "other-region-app" => target_part("#{ENVIRONMENT}-app", cluster: cluster_arn(ENVIRONMENT, region: 'us-east-1')),
        },
      })
      write_json("#{ENVIRONMENT}/application.json", application_data)
      write_json("#{ENVIRONMENT}/launch.json", launches || default_launches)
      write_json("#{ENVIRONMENT}/schedule.json", schedules) if schedules
      application
    end

    def default_launches
      {
        app: {target: "#{ENVIRONMENT}-app", network: ENVIRONMENT},
        migrate: {target: "#{ENVIRONMENT}-app", network: ENVIRONMENT, command: 'bin/rails db:migrate'},
        seed: {
          target: "#{ENVIRONMENT}-seed",
          network: "#{ENVIRONMENT}-public",
          env: {RAILS_LOG_LEVEL: 'info', BATCH: '100'},
          command: "bin/rails runner 'p Seed.new.perform'",
        },
      }
    end

    def application
      Putpaws::ApplicationConfig.find(ENVIRONMENT)
    end

    # Run the real CLI in the test project. Returns [output, success?].
    def putpaws(*args)
      lib = File.expand_path('../lib', __dir__)
      bin = File.expand_path('../bin/putpaws', __dir__)
      out, status = Open3.capture2e(RbConfig.ruby, "-I#{lib}", bin, *args, chdir: project_dir)
      [out, status.success?]
    end
  end
end
