require "test_helper"
require "putpaws/ecs/launch_request"
require "putpaws/ecs/run_command"

class LaunchRequestTest < Putpaws::TestCase
  def request(params, prompt: Putpaws::FakePrompt.new, io: StringIO.new)
    @io = io
    Putpaws::Ecs::LaunchRequest.new(application: application, params: params, prompt: prompt, io: io)
  end

  def test_command_line_parameters_become_overrides
    overrides = Putpaws::Ecs::LaunchRequest.overrides(
      'launch' => 'seed', 'cmd' => 'ls -la', 'cpu' => '8192', 'memory' => '', 'wait' => 'true',
      'env' => 'A=1 B=x=y', 'capacity_provider' => 'FARGATE_SPOT', 'ttl' => '10m',
    )
    assert_equal({command: 'ls -la', cpu: '8192', env: {'A' => '1', 'B' => 'x=y'}, capacity_provider: 'FARGATE_SPOT'}, overrides)
  end

  def test_malformed_env_is_an_error
    assert_raises(Putpaws::ConfigError){ Putpaws::Ecs::LaunchRequest.parse_env('A') }
  end

  def test_saved_launch_partly_overridden
    write_project
    launch = request({'launch' => 'seed', 'network' => ENVIRONMENT, 'cpu' => '8192', 'memory' => '32768'}).resolve
    assert_equal "#{ENVIRONMENT}-seed", launch.target.name
    assert_equal ENVIRONMENT, launch.network.name
    assert_equal 8192, launch.cpu
    assert_equal "bin/rails runner 'p Seed.new.perform'", launch.command
  end

  def test_unknown_launch_name_is_an_error
    write_project
    assert_raises(Putpaws::ConfigError){ request({'launch' => 'nope'}).resolve }
  end

  def test_assembled_on_the_spot_never_asks
    write_project
    prompt = Putpaws::FakePrompt.new
    launch = request({'target' => "#{ENVIRONMENT}-app", 'network' => ENVIRONMENT, 'cmd' => 'ls'}, prompt: prompt).resolve
    assert_equal 'ls', launch.command
    assert_empty prompt.questions
  end

  def test_without_launch_or_parts_the_launches_are_offered
    write_project
    prompt = Putpaws::FakePrompt.new(select: 'migrate')
    launch = request({'cmd' => ''}, prompt: prompt).resolve
    assert_equal ['Choose a launch'], prompt.questions
    assert_equal 'bin/rails db:migrate', launch.command
  end

  def test_no_launches_to_offer_is_an_error
    write_project(launches: {})
    error = assert_raises(Putpaws::ConfigError){ request({}).resolve }
    assert_match(/No launch is defined/, error.message)
  end

  def test_save_writes_a_new_name_into_the_environment
    write_project
    prompt = Putpaws::FakePrompt.new
    req = request({'launch' => 'seed', 'cpu' => '4096', 'memory' => '16384', 'save' => 'seed-small'}, prompt: prompt)
    assert req.save!(req.resolve)
    assert_empty prompt.questions
    saved = read_json("#{ENVIRONMENT}/launch.json")['seed-small']
    assert_equal 4096, saved['cpu']
    assert_equal 16384, saved['memory']
    assert_equal "#{ENVIRONMENT}-seed", saved['target']
    assert_equal({'RAILS_LOG_LEVEL' => 'info', 'BATCH' => '100'}, saved['env'])
    # The source launch is left as it was.
    assert_nil read_json("#{ENVIRONMENT}/launch.json")['seed']['cpu']
  end

  def test_save_never_overwrites_an_existing_name_silently
    write_project
    before = read_json("#{ENVIRONMENT}/launch.json")
    prompt = Putpaws::FakePrompt.new(yes: false)
    req = request({'launch' => 'seed', 'cpu' => '4096', 'save' => 'app'}, prompt: prompt)
    refute req.save!(req.resolve)
    assert_equal 1, prompt.questions.size
    assert_match(/already exists/, prompt.questions.first)
    assert_match(/--- before.*\+\+\+ after/m, @io.string)
    assert_equal before, read_json("#{ENVIRONMENT}/launch.json")
  end

  def test_save_overwrites_after_confirmation
    write_project
    req = request({'launch' => 'seed', 'cpu' => '4096', 'save' => 'app'}, prompt: Putpaws::FakePrompt.new(yes: true))
    assert req.save!(req.resolve)
    assert_equal 4096, read_json("#{ENVIRONMENT}/launch.json")['app']['cpu']
  end

  def test_saving_the_same_content_asks_nothing
    write_project
    prompt = Putpaws::FakePrompt.new(yes: false)
    req = request({'launch' => 'seed', 'save' => 'seed'}, prompt: prompt)
    assert req.save!(req.resolve)
    assert_empty prompt.questions
  end

  def test_run_task_params
    write_project
    launch = request({'launch' => 'seed', 'cpu' => '8192', 'capacity_provider' => 'FARGATE_SPOT'}).resolve
    params = Putpaws::Ecs::RunCommand.new(launch).run_task_params(started_by: 'putpaws-run', group: 'putpaws-run')
    assert_equal cluster_arn, params[:cluster]
    assert_equal "#{ENVIRONMENT}-seed", params[:task_definition]
    assert_equal %w[subnet-p], params[:network_configuration][:awsvpc_configuration][:subnets]
    assert_equal 'ENABLED', params[:network_configuration][:awsvpc_configuration][:assign_public_ip]
    refute params.key?(:launch_type)
    assert_equal [{capacity_provider: 'FARGATE_SPOT', weight: 1}], params[:capacity_provider_strategy]
    assert_equal '8192', params[:overrides][:cpu]
    assert_equal 'putpaws-run', params[:group]
    assert params[:enable_execute_command]
  end

  # The stubbed client validates the parameters against the ECS API shape.
  def test_every_override_is_accepted_by_the_ecs_api
    write_project
    launch = request({
      "launch" => "seed", "cpu" => "4096", "memory" => "16384", "ephemeral_storage" => "50",
      "task_role" => "arn:aws:iam::123456789012:role/seed", "capacity_provider" => "FARGATE_SPOT",
      "container" => "app", "env" => "A=1",
    }).resolve
    client = Aws::ECS::Client.new(region: REGION, stub_responses: true)
    Putpaws::Ecs::RunCommand.new(launch, ecs_client: client).run_ecs_task(started_by: "putpaws-run", group: "putpaws-run")
    sent = client.api_requests.first
    assert_equal :run_task, sent[:operation_name]
    assert_equal({size_in_gi_b: 50}, sent[:params][:overrides][:ephemeral_storage])
    assert_equal "arn:aws:iam::123456789012:role/seed", sent[:params][:overrides][:task_role_arn]
  end

  def test_run_task_params_of_a_bare_launch_override_nothing
    write_project
    launch = request({'launch' => 'app'}).resolve
    params = Putpaws::Ecs::RunCommand.new(launch).run_task_params(started_by: 'x', group: 'x')
    assert_equal 'FARGATE', params[:launch_type]
    refute params.key?(:overrides)
  end
end
