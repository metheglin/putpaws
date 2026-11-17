require "test_helper"
require "putpaws/ecs/run_command"
require "putpaws/scheduler/schedule_command"

class ScheduleTest < Putpaws::TestCase
  SCHEDULES = {
    'nightly-seed' => {
      launch: 'seed',
      schedule_expression: 'cron(0 18 * * ? *)',
      schedule_expression_timezone: 'Asia/Tokyo',
    },
    'weekly-report' => {
      launch: 'app',
      command: "bin/rails runner 'Report.deliver_weekly'",
      cpu: 2048,
      memory: 4096,
      env: {REPORT: 'weekly'},
      schedule_expression: 'cron(0 9 ? * MON *)',
      state: 'ENABLED',
      target: nil,
    }.compact,
  }

  def schedule(name)
    Putpaws::ScheduleConfig.find!(application, name)
  end

  def command(name)
    Putpaws::Scheduler::ScheduleCommand.new(schedule(name))
  end

  def test_schedule_holds_a_launch_name_overrides_and_scheduler_args
    write_project(schedules: SCHEDULES)
    weekly = schedule('weekly-report')
    assert_equal 'app', weekly.launch
    assert_equal({command: "bin/rails runner 'Report.deliver_weekly'", env: {'REPORT' => 'weekly'}, cpu: 2048, memory: 4096}, weekly.overrides)
    assert_equal({schedule_expression: 'cron(0 9 ? * MON *)', state: 'ENABLED'}, weekly.args)
    assert_equal %w[nightly-seed weekly-report], Putpaws::ScheduleConfig.all(application).map(&:name)
  end

  def test_aws_name_is_prefixed_with_the_environment
    write_project(schedules: SCHEDULES)
    assert_equal 'minaone-production-nightly-seed', schedule('nightly-seed').aws_name
    assert_equal 'minaone-production-nightly-seed', command('nightly-seed').params[:name]
  end

  def test_overrides_of_the_schedule_apply_on_top_of_the_launch
    write_project(schedules: SCHEDULES)
    launch = schedule('weekly-report').resolve
    assert_equal "#{ENVIRONMENT}-app", launch.target.name
    assert_equal 2048, launch.cpu
    assert_equal "bin/rails runner 'Report.deliver_weekly'", launch.command
  end

  def test_params_for_eventbridge_scheduler
    write_project(schedules: SCHEDULES)
    params = command('nightly-seed').params
    target = params[:target]
    assert_equal cluster_arn, target[:arn]
    assert_equal "arn:aws:iam::#{ACCOUNT}:role/#{ENVIRONMENT}-scheduler", target[:role_arn]
    assert_equal "#{ENVIRONMENT}-seed", target[:ecs_parameters][:task_definition_arn]
    assert_equal 'FARGATE', target[:ecs_parameters][:launch_type]
    assert_equal %w[subnet-p], target[:ecs_parameters][:network_configuration][:awsvpc_configuration][:subnets]
    assert_equal 'cron(0 18 * * ? *)', params[:schedule_expression]
    assert_equal 'Asia/Tokyo', params[:schedule_expression_timezone]
    assert_equal({mode: 'OFF'}, params[:flexible_time_window])
  end

  # A manual run and a schedule of the same launch start the same thing,
  # including how the command is wrapped.
  def test_same_overrides_as_ecs_run
    write_project(schedules: SCHEDULES.merge('all' => {
      launch: 'seed', cpu: 4096, memory: 16384, ephemeral_storage: 50,
      task_role: 'arn:aws:iam::123456789012:role/seed', schedule_expression: 'rate(1 day)',
    }))
    %w[nightly-seed weekly-report all].each do |name|
      launch = schedule(name).resolve
      run = Putpaws::Ecs::RunCommand.new(launch).run_task_params(started_by: 'x', group: 'x')
      input = JSON.parse(command(name).params[:target][:input])
      expected = JSON.parse(JSON.generate(run[:overrides]))

      # Same content, in the key style each API expects.
      assert_equal(
        {
          "containerOverrides" => expected["container_overrides"],
          "cpu" => expected["cpu"],
          "memory" => expected["memory"],
          "taskRoleArn" => expected["task_role_arn"],
          "ephemeralStorage" => expected["ephemeral_storage"] && {"sizeInGiB" => expected["ephemeral_storage"]["size_in_gi_b"]},
        }.compact,
        input, name
      )
      assert_equal ['/bin/sh', '-c'], input['containerOverrides'][0]['command'][0, 2], name
    end
  end

  def test_no_input_when_nothing_is_overridden
    write_project(schedules: {plain: {launch: 'app', schedule_expression: 'rate(1 hour)'}})
    refute command('plain').params[:target].key?(:input)
  end

  def test_capacity_provider_replaces_launch_type
    write_project(schedules: {spot: {launch: 'app', capacity_provider: 'FARGATE_SPOT', schedule_expression: 'rate(1 hour)'}})
    ecs = command('spot').params[:target][:ecs_parameters]
    refute ecs.key?(:launch_type)
    assert_equal [{capacity_provider: 'FARGATE_SPOT', weight: 1}], ecs[:capacity_provider_strategy]
  end

  def test_scheduler_args_are_merged_deeply
    write_project(schedules: {retry: {
      launch: 'app', schedule_expression: 'rate(1 hour)',
      target: nil, flexible_time_window: {mode: 'FLEXIBLE', maximum_window_in_minutes: 15},
    }.compact})
    params = command('retry').params
    assert_equal({mode: 'FLEXIBLE', maximum_window_in_minutes: 15}, params[:flexible_time_window])
    assert_equal cluster_arn, params[:target][:arn]
  end

  def test_launch_is_required
    write_project(schedules: {bad: {schedule_expression: 'rate(1 hour)'}})
    error = assert_raises(Putpaws::ConfigError){ schedule('bad') }
    assert_match(/needs `launch`/, error.message)
  end

  def test_unknown_launch_is_an_error
    write_project(schedules: {bad: {launch: 'nope', schedule_expression: 'rate(1 hour)'}})
    assert_raises(Putpaws::ConfigError){ schedule('bad').resolve }
  end

  def test_fields_of_the_old_format_are_rejected
    write_project(schedules: {old: {
      region: REGION, network: ENVIRONMENT, target: "#{ENVIRONMENT}-app",
      command: %w[bin/rails runner x], schedule_expression: 'rate(1 hour)',
    }})
    error = assert_raises(Putpaws::ConfigError){ schedule('old') }
    assert_match(/`region`, `network`, `target`|`target`, `network`, `region`/, error.message)
    assert_match(/"launch"/, error.message)
  end

  # The stubbed client validates the parameters against the Scheduler API shape.
  def test_every_override_is_accepted_by_the_scheduler_api
    write_project(schedules: {all: {
      launch: "seed", cpu: 4096, memory: 16384, ephemeral_storage: 50, capacity_provider: "FARGATE_SPOT",
      task_role: "arn:aws:iam::123456789012:role/seed", schedule_expression: "rate(1 day)", state: "DISABLED",
    }})
    client = Aws::Scheduler::Client.new(region: REGION, stub_responses: true)
    client.stub_responses(:get_schedule, "ResourceNotFoundException")
    assert_equal :created, Putpaws::Scheduler::ScheduleCommand.new(schedule("all"), client: client).deploy!
    sent = client.api_requests.last[:params]
    assert_equal "DISABLED", sent[:state]
    assert_equal [{capacity_provider: "FARGATE_SPOT", weight: 1}], sent[:target][:ecs_parameters][:capacity_provider_strategy]
  end

  def test_deploy_creates_or_updates
    write_project(schedules: SCHEDULES)
    client = Aws::Scheduler::Client.new(region: REGION, stub_responses: true)
    assert_equal :updated, Putpaws::Scheduler::ScheduleCommand.new(schedule('nightly-seed'), client: client).deploy!
    client.stub_responses(:get_schedule, 'ResourceNotFoundException')
    assert_equal :created, Putpaws::Scheduler::ScheduleCommand.new(schedule('nightly-seed'), client: client).deploy!
    names = client.api_requests.map{|r| [r[:operation_name], r[:params][:name]]}
    assert_equal [
      [:get_schedule, 'minaone-production-nightly-seed'],
      [:update_schedule, 'minaone-production-nightly-seed'],
      [:get_schedule, 'minaone-production-nightly-seed'],
      [:create_schedule, 'minaone-production-nightly-seed'],
    ], names
  end
end
