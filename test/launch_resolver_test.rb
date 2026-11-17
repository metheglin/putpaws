require "test_helper"

class LaunchResolverTest < Putpaws::TestCase
  def resolve(launch: nil, overrides: [])
    app = application
    config = launch && Putpaws::LaunchConfig.find!(app, launch)
    Putpaws::LaunchResolver.resolve(application: app, launch: config, overrides: overrides)
  end

  def test_saved_launch_as_it_is
    write_project
    launch = resolve(launch: 'seed')
    assert_equal "#{ENVIRONMENT}-seed", launch.target.name
    assert_equal "#{ENVIRONMENT}-public", launch.network.name
    assert_equal %w[subnet-p], launch.network.subnets
    assert_equal REGION, launch.region
    assert_equal cluster_arn, launch.cluster
    assert_equal 'app', launch.container_name
  end

  def test_later_layers_win_field_by_field
    write_project
    launch = resolve(launch: 'seed', overrides: [
      {cpu: 2048, memory: 4096, command: 'first'},
      {network: ENVIRONMENT, cpu: '8192', command: 'second'},
    ])
    assert_equal ENVIRONMENT, launch.network.name
    assert_equal 8192, launch.cpu
    assert_equal 4096, launch.memory
    assert_equal 'second', launch.command
    assert_equal "#{ENVIRONMENT}-seed", launch.target.name
  end

  def test_only_env_is_merged_name_by_name
    write_project
    launch = resolve(launch: 'seed', overrides: [{env: {'BATCH' => '500', 'EXTRA' => '1'}}])
    assert_equal({'RAILS_LOG_LEVEL' => 'info', 'BATCH' => '500', 'EXTRA' => '1'}, launch.env)
  end

  def test_assembled_on_the_spot_without_a_saved_launch
    write_project
    launch = resolve(overrides: {target: "#{ENVIRONMENT}-app", network: ENVIRONMENT, command: 'ls'})
    assert_equal({target: "#{ENVIRONMENT}-app", network: ENVIRONMENT, command: 'ls'}, launch.to_h)
  end

  def test_target_and_network_must_both_be_resolved
    write_project
    error = assert_raises(Putpaws::ConfigError){ resolve(overrides: {target: "#{ENVIRONMENT}-app"}) }
    assert_match(/no `network`/, error.message)
    error = assert_raises(Putpaws::ConfigError){ resolve(overrides: {command: 'ls'}) }
    assert_match(/no `target` and `network`/, error.message)
  end

  def test_names_missing_from_infra_json_are_an_error
    write_project
    error = assert_raises(Putpaws::ConfigError){ resolve(launch: 'app', overrides: {target: 'nowhere'}) }
    assert_match(/target `nowhere` is not defined/, error.message)
    error = assert_raises(Putpaws::ConfigError){ resolve(launch: 'app', overrides: {network: 'nowhere'}) }
    assert_match(/network `nowhere` is not defined/, error.message)
  end

  def test_unknown_override_is_an_error
    write_project
    assert_raises(Putpaws::ConfigError){ resolve(launch: 'app', overrides: {image: 'nginx'}) }
  end

  def test_target_of_another_cluster_is_stopped
    write_project
    error = assert_raises(Putpaws::ConfigError){ resolve(launch: 'app', overrides: {target: 'other-staging-app'}) }
    assert_match(/does not belong to environment `#{ENVIRONMENT}`/, error.message)
  end

  def test_target_of_another_region_is_stopped
    write_project
    error = assert_raises(Putpaws::ConfigError){ resolve(launch: 'app', overrides: {target: 'other-region-app'}) }
    assert_match(/does not belong to environment/, error.message)
    assert_match(/us-east-1/, error.message)
  end

  def test_ecs_region_of_the_environment_is_used
    write_project
    write_json("#{ENVIRONMENT}/application.json", application_data.merge(region: 'us-west-2', ecs_region: 'us-east-1'))
    launch = resolve(launch: 'app', overrides: {target: 'other-region-app'})
    assert_equal 'us-east-1', launch.region
  end

  def test_string_command_goes_through_the_shell_and_array_is_passed_as_it_is
    write_project
    assert_equal ['/bin/sh', '-c', 'bin/rails db:migrate'], resolve(launch: 'migrate').command_array
    assert_equal %w[bin/rails db:migrate], resolve(launch: 'app', overrides: {command: %w[bin/rails db:migrate]}).command_array
    assert_nil resolve(launch: 'app').command_array
  end

  def test_task_overrides
    write_project
    launch = resolve(launch: 'seed', overrides: {
      cpu: 4096, memory: 16384, ephemeral_storage: 50,
      task_role: 'arn:aws:iam::123456789012:role/seed', container: 'worker',
    })
    assert_equal({
      container_overrides: [{
        name: 'worker',
        command: ['/bin/sh', '-c', "bin/rails runner 'p Seed.new.perform'"],
        environment: [{name: 'RAILS_LOG_LEVEL', value: 'info'}, {name: 'BATCH', value: '100'}],
      }],
      cpu: '4096',
      memory: '16384',
      task_role_arn: 'arn:aws:iam::123456789012:role/seed',
      ephemeral_storage: {size_in_gi_b: 50},
    }, launch.task_overrides)
  end

  def test_nothing_is_overridden_for_a_bare_launch
    write_project
    assert_equal({}, resolve(launch: 'app').task_overrides)
  end

  def test_placement
    write_project
    assert_equal({launch_type: 'FARGATE'}, resolve(launch: 'app').placement)
    assert_equal({launch_type: 'FARGATE'}, resolve(launch: 'app', overrides: {capacity_provider: 'FARGATE'}).placement)
    assert_equal(
      {capacity_provider_strategy: [{capacity_provider: 'FARGATE_SPOT', weight: 1}]},
      resolve(launch: 'app', overrides: {capacity_provider: 'FARGATE_SPOT'}).placement
    )
  end

  def test_with_replaces_only_what_is_given
    write_project
    shell = resolve(launch: 'seed', overrides: {cpu: 1024}).with(command: 'sleep 600')
    assert_equal 'sleep 600', shell.command
    assert_equal 1024, shell.cpu
    assert_equal "#{ENVIRONMENT}-public", shell.network.name
    assert_equal({'RAILS_LOG_LEVEL' => 'info', 'BATCH' => '100'}, shell.env)
  end
end
