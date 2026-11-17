require "test_helper"
require "putpaws/provision/config_writer"

class ConfigWriterTest < Putpaws::TestCase
  Preset = Struct.new(:task_definitions, :service_task_definition)
  Config = Struct.new(
    :service_name, :region, :cluster_name, :log_group, :build_log_group, :build_project_name,
    :path_prefix, :base, :settings, :roles, :preset, keyword_init: true
  ) do
    def task_definition_family(suffix)
      "#{service_name}-#{suffix}"
    end
  end
  State = Struct.new(:resources)

  def config(suffixes: %w[app extract seed])
    Config.new(
      service_name: ENVIRONMENT, region: REGION, cluster_name: ENVIRONMENT,
      log_group: "/ecs/#{ENVIRONMENT}", build_log_group: "/aws/codebuild/#{ENVIRONMENT}",
      build_project_name: ENVIRONMENT, path_prefix: root,
      base: {subnets: %w[subnet-a subnet-b]}, settings: {},
      roles: {scheduler_role_arn: "arn:aws:iam::#{ACCOUNT}:role/#{ENVIRONMENT}-scheduler"},
      preset: Preset.new(suffixes.map{|s| {suffix: s, container_name: 'app'}}, 'app'),
    )
  end

  def writer(prompt: Putpaws::FakePrompt.new, **opts)
    @io = StringIO.new
    state = State.new({security_group_ids: %w[sg-1], cluster_arn: cluster_arn})
    Putpaws::Provision::ConfigWriter.new(config: config(**opts), state: state, prompt: prompt, io: @io)
  end

  def test_generates_the_environment_from_nothing
    writer.apply!

    assert_equal [ENVIRONMENT], Putpaws::ApplicationConfig.names
    assert_equal JSON.parse(JSON.generate(application_data)), read_json("#{ENVIRONMENT}/application.json")

    infra = read_json('infra.json')
    assert_equal [ENVIRONMENT], infra['network'].keys
    assert_equal %w[minaone-production-app minaone-production-extract minaone-production-seed], infra['target'].keys
    assert_equal cluster_arn, infra['target']['minaone-production-app']['cluster']

    assert_equal({
      'app' => {'target' => 'minaone-production-app', 'network' => ENVIRONMENT},
      'extract' => {'target' => 'minaone-production-extract', 'network' => ENVIRONMENT},
      'seed' => {'target' => 'minaone-production-seed', 'network' => ENVIRONMENT},
    }, read_json("#{ENVIRONMENT}/launch.json"))
    refute File.exist?(File.join(root, ENVIRONMENT, 'schedule.json'))
  end

  def test_what_it_generates_can_be_started
    writer.apply!
    launch = Putpaws::LaunchResolver.resolve(
      application: application, launch: Putpaws::LaunchConfig.find!(application, 'extract')
    )
    assert_equal 'minaone-production-extract', launch.task_definition
    assert_equal %w[subnet-a subnet-b], launch.network.subnets
  end

  def test_second_run_changes_and_asks_nothing
    writer.apply!
    prompt = Putpaws::FakePrompt.new
    writer(prompt: prompt).apply!
    assert_empty prompt.questions
    assert_empty @io.string
  end

  def test_existing_launches_are_never_rewritten
    write_json("#{ENVIRONMENT}/launch.json", {
      seed: {target: 'minaone-production-seed', network: 'minaone-production-public', cpu: 4096},
      migrate: {target: 'minaone-production-app', network: ENVIRONMENT, command: 'bin/rails db:migrate'},
    })
    prompt = Putpaws::FakePrompt.new
    writer(prompt: prompt).apply!

    launches = read_json("#{ENVIRONMENT}/launch.json")
    assert_equal %w[seed migrate app extract], launches.keys
    assert_equal({'target' => 'minaone-production-seed', 'network' => 'minaone-production-public', 'cpu' => 4096}, launches['seed'])
    assert_equal 'bin/rails db:migrate', launches['migrate']['command']
    assert_match(/Added launch `app`, `extract`/, @io.string)
    refute(prompt.questions.any?{|q| q.include?('launch.json')})
  end

  def test_parts_added_by_the_user_are_kept
    write_json('infra.json', {
      network: {"#{ENVIRONMENT}-public" => {subnets: %w[subnet-p], security_groups: %w[sg-1], assign_public_ip: 'ENABLED'}},
      target: {"custom" => target_part('custom')},
    })
    writer.apply!
    infra = read_json('infra.json')
    assert_equal ["#{ENVIRONMENT}-public", ENVIRONMENT], infra['network'].keys
    assert_equal %w[subnet-p], infra['network']["#{ENVIRONMENT}-public"]['subnets']
    assert_includes infra['target'].keys, 'custom'
  end

  def test_keys_added_by_hand_to_application_json_survive
    write_json("#{ENVIRONMENT}/application.json", application_data.merge(log_region: 'us-east-1'))
    prompt = Putpaws::FakePrompt.new
    writer(prompt: prompt).apply!
    refute(prompt.questions.any?{|q| q.include?('application.json')})
    assert_equal 'us-east-1', read_json("#{ENVIRONMENT}/application.json")['log_region']
  end

  def test_application_json_is_updated_only_after_confirmation
    write_json("#{ENVIRONMENT}/application.json", application_data.merge(cluster: 'old', log_region: 'us-east-1'))

    declined = Putpaws::FakePrompt.new(yes: false)
    writer(prompt: declined).apply!
    assert_equal 'old', read_json("#{ENVIRONMENT}/application.json")['cluster']
    assert(declined.questions.any?{|q| q.include?('application.json')})

    writer(prompt: Putpaws::FakePrompt.new(yes: true)).apply!
    data = read_json("#{ENVIRONMENT}/application.json")
    assert_equal ENVIRONMENT, data['cluster']
    assert_equal 'us-east-1', data['log_region']
  end

  def test_schedule_json_is_not_touched
    schedule = {nightly: {launch: 'seed', schedule_expression: 'rate(1 day)'}}
    path = write_json("#{ENVIRONMENT}/schedule.json", schedule)
    before = File.read(path)
    writer.apply!
    assert_equal before, File.read(path)
  end

  def test_legacy_files_are_left_alone_and_reported
    legacy_app = write_json('application.json', {"minaone-production-app" => application_data.merge(network: 'x')})
    legacy_schedule = write_json('schedule.json', {old: {}})
    before = [File.read(legacy_app), File.read(legacy_schedule)]

    w = writer
    w.apply!
    w.notify_legacy

    assert_equal before, [File.read(legacy_app), File.read(legacy_schedule)]
    assert_match(/#{Regexp.escape(legacy_app)} is a legacy/, @io.string)
    assert_match(/#{Regexp.escape(legacy_schedule)} is a legacy/, @io.string)
    assert File.exist?(File.join(root, ENVIRONMENT, 'application.json'))
  end
end
