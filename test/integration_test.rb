require "test_helper"
require "putpaws/provision/all"
require "putpaws/iam/grant_command"
require "putpaws/ai/guide"

# Pieces around the settings which have to keep following them.
class IntegrationTest < Putpaws::TestCase
  State = Struct.new(:resources)

  def provision_config
    write_json("provisioning/#{ENVIRONMENT}/provision.json", {
      service_name: ENVIRONMENT,
      region: REGION,
      preset: 'rails',
      base: {
        vpc_id: 'vpc-1', subnets: %w[subnet-a subnet-b], security_group_ids: %w[sg-1],
        ecr_repository_arn: "arn:aws:ecr:#{REGION}:#{ACCOUNT}:repository/minaone",
        ssm_parameter_prefix: "/#{ENVIRONMENT}",
      },
      roles: {scheduler_role_arn: "arn:aws:iam::#{ACCOUNT}:role/#{ENVIRONMENT}-scheduler"},
      overrides: {},
      devops: {},
    })
    Putpaws::Provision::ProvisionConfig.load(ENVIRONMENT, path_prefix: root)
  end

  # `putpaws up` with a real provision.json and the bundled preset.
  def test_up_reflects_the_bundled_preset_into_the_environment
    io = StringIO.new
    state = State.new({security_group_ids: %w[sg-1], cluster_arn: cluster_arn})
    Putpaws::Provision::ConfigWriter.new(
      config: provision_config, state: state, prompt: Putpaws::FakePrompt.new, io: io
    ).apply!

    assert_equal [ENVIRONMENT], Putpaws::ApplicationConfig.names
    app = application
    assert_equal ENVIRONMENT, app.cluster
    assert_equal ENVIRONMENT, app.task_name_prefix
    assert_equal %w[app], app.launches.map(&:name)

    launch = Putpaws::LaunchResolver.resolve(application: app, launch: app.launches.first, overrides: {command: 'echo ok'})
    assert_equal "#{ENVIRONMENT}-app", launch.task_definition
    assert_equal ['/bin/sh', '-c', 'echo ok'], launch.command_array
  end

  def test_scheduler_group_passes_the_roles_of_the_launch_targets
    app = write_project
    grant = Putpaws::Iam::GrantCommand.new(app: app, account_id: ACCOUNT)
    profile = Putpaws::Iam::OperatorConfig.new(name: 'ops', groups: %w[scheduler shell], extra_statements: [])
    statements = grant.build_policy_document(profile)[:Statement]

    pass_role = statements.detect{|s| s[:Sid] == 'SchedulePassRole'}
    assert_equal "arn:aws:iam::#{ACCOUNT}:role/#{ENVIRONMENT}-scheduler", pass_role[:Resource]
    manage = statements.detect{|s| s[:Sid] == 'ScheduleManage'}
    assert_equal "arn:aws:scheduler:#{REGION}:#{ACCOUNT}:schedule/default/#{ENVIRONMENT}-*", manage[:Resource]
    run_task = statements.detect{|s| s[:Sid] == 'ShellRunTask'}
    assert_includes run_task[:Resource], "arn:aws:ecs:#{REGION}:#{ACCOUNT}:task-definition/#{ENVIRONMENT}*"
  end

  def test_scheduler_group_without_launches_falls_back_to_the_role_pattern
    app = write_project(launches: {})
    grant = Putpaws::Iam::GrantCommand.new(app: app, account_id: ACCOUNT)
    profile = Putpaws::Iam::OperatorConfig.new(name: 'ops', groups: %w[scheduler], extra_statements: [])
    pass_role = grant.build_policy_document(profile)[:Statement].detect{|s| s[:Sid] == 'SchedulePassRole'}
    assert_equal "arn:aws:iam::#{ACCOUNT}:role/#{ENVIRONMENT}-*", pass_role[:Resource]
  end

  def test_ai_guide_names_the_environments
    write_project
    skill, pointer = Putpaws::Ai::Guide.install!(root: project_dir)
    content = File.read(skill, encoding: 'UTF-8')
    assert_match(/Environments in this project: minaone-production$/, content)
    assert_match(/ecs:run launch=app cmd='bundle exec rake db:migrate' wait=true/, content)
    assert_match(%r{\.putpaws/<environment>/launch\.json}, content)
    refute_match(/#\{/, content)
    assert_match(/environments are the folders under `\.putpaws\/`/, File.read(pointer, encoding: 'UTF-8'))
  end
end
