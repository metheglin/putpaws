require "test_helper"

class LaunchConfigTest < Putpaws::TestCase
  def test_reads_named_launches
    app = write_project
    seed = Putpaws::LaunchConfig.find(app, 'seed')
    assert_equal "#{ENVIRONMENT}-seed", seed.target
    assert_equal "#{ENVIRONMENT}-public", seed.network
    assert_equal({'RAILS_LOG_LEVEL' => 'info', 'BATCH' => '100'}, seed.env)
    assert_nil Putpaws::LaunchConfig.find(app, 'unknown')
    error = assert_raises(Putpaws::ConfigError){ Putpaws::LaunchConfig.find!(app, 'unknown') }
    assert_match(/Available: app, migrate, seed/, error.message)
  end

  def test_non_ascii_values_round_trip_whatever_the_locale
    app = write_project
    command = "bin/rails runner 'puts \"\u65E5\u6B21\u30D0\u30C3\u30C1\"'"
    Putpaws::LaunchConfig.save!(app, "nichiji", {target: "#{ENVIRONMENT}-app", network: ENVIRONMENT, command: command})
    assert_equal command, Putpaws::LaunchConfig.find(app, "nichiji").command
  end

  def test_unknown_field_is_an_error
    app = write_project(launches: {app: {target: 'a', network: 'b', image: 'nginx'}})
    error = assert_raises(Putpaws::ConfigError){ Putpaws::LaunchConfig.all(app) }
    assert_match(/Unknown field `image`/, error.message)
    assert_match(/launch `app`/, error.message)
  end

  def test_target_and_network_are_required
    app = write_project(launches: {app: {target: "#{ENVIRONMENT}-app"}})
    error = assert_raises(Putpaws::ConfigError){ Putpaws::LaunchConfig.find(app, 'app') }
    assert_match(/needs `network`/, error.message)
  end

  def test_normalizes_values
    attrs = Putpaws::LaunchConfig.normalize(
      {'cpu' => '4096', memory: 16384, ephemeral_storage: '50', env: {A: 1}, capacity_provider: 'fargate_spot', container: ''},
      context: 'test'
    )
    assert_equal({cpu: 4096, memory: 16384, ephemeral_storage: 50, env: {'A' => '1'}, capacity_provider: 'FARGATE_SPOT'}, attrs)
  end

  def test_rejects_invalid_values
    assert_raises(Putpaws::ConfigError){ Putpaws::LaunchConfig.normalize({cpu: 'big'}, context: 'test') }
    assert_raises(Putpaws::ConfigError){ Putpaws::LaunchConfig.normalize({capacity_provider: 'EC2'}, context: 'test') }
    assert_raises(Putpaws::ConfigError){ Putpaws::LaunchConfig.normalize({command: [1, 2]}, context: 'test') }
    assert_raises(Putpaws::ConfigError){ Putpaws::LaunchConfig.normalize({env: 'A=1'}, context: 'test') }
  end

  def test_save_writes_into_the_environment_and_keeps_other_launches
    app = write_project
    file = Putpaws::LaunchConfig.save!(app, 'seed-small', {target: "#{ENVIRONMENT}-seed", network: ENVIRONMENT, cpu: '4096'})
    assert_equal File.join(root, ENVIRONMENT, 'launch.json'), file.to_s
    data = read_json("#{ENVIRONMENT}/launch.json")
    assert_equal %w[app migrate seed seed-small], data.keys
    assert_equal({'target' => "#{ENVIRONMENT}-seed", 'network' => ENVIRONMENT, 'cpu' => 4096}, data['seed-small'])
  end

  def test_save_rejects_incomplete_or_badly_named_launches
    app = write_project
    assert_raises(Putpaws::ConfigError){ Putpaws::LaunchConfig.save!(app, 'x', {target: 'only'}) }
    assert_raises(Putpaws::ConfigError){ Putpaws::LaunchConfig.save!(app, 'bad name', {target: 'a', network: 'b'}) }
  end
end
