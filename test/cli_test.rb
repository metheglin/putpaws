require "test_helper"

# Runs the real `putpaws` command in a project folder. Nothing here reaches AWS.
class CliTest < Putpaws::TestCase
  def test_first_argument_selects_the_environment
    write_project(schedules: {nightly: {launch: 'seed', schedule_expression: 'rate(1 day)'}})
    out, ok = putpaws(ENVIRONMENT, 'info')
    assert ok, out
    assert_match(/^environment:\s+minaone-production$/, out)
    assert_match(/^  seed:\s+target=minaone-production-seed network=minaone-production-public$/, out)
    assert_match(/^  nightly:\s+launch=seed rate\(1 day\)$/, out)
  end

  def test_launch_list
    write_project
    out, ok = putpaws(ENVIRONMENT, 'launch:list')
    assert ok, out
    assert_match(/^migrate\n  target:\s+minaone-production-app\n  network:\s+minaone-production\n  command:\s+bin\/rails db:migrate$/, out)
  end

  def test_dry_run_shows_the_resolved_launch_and_starts_nothing
    write_project
    out, ok = putpaws(ENVIRONMENT, 'ecs:run', 'launch=seed', 'network=minaone-production', 'cpu=8192', 'memory=32768', 'dry=true')
    assert ok, out
    data = JSON.parse(out)
    assert_equal ENVIRONMENT, data['environment']
    assert_equal 8192, data['launch']['cpu']
    assert_equal ENVIRONMENT, data['network']['name']
    assert_equal 'minaone-production-seed', data['target']['task_definition']
  end

  def test_shell_replaces_only_the_command
    write_project
    out, ok = putpaws(ENVIRONMENT, 'ecs:shell', 'launch=seed', 'ttl=10m', 'dry=true')
    assert ok, out
    data = JSON.parse(out)
    assert_equal 'sleep 600', data['launch']['command']
    assert_equal 'minaone-production-public', data['network']['name']
    assert_equal({'RAILS_LOG_LEVEL' => 'info', 'BATCH' => '100'}, data['launch']['env'])
  end

  def test_save_then_dry
    write_project
    out, ok = putpaws(ENVIRONMENT, 'ecs:run', 'launch=seed', 'cpu=4096', 'memory=16384', 'save=seed-small', 'dry=true')
    assert ok, out
    assert_match(/Saved launch `seed-small`/, out)
    assert_equal 4096, read_json("#{ENVIRONMENT}/launch.json")['seed-small']['cpu']
  end

  def test_run_without_a_command_is_an_error
    write_project
    out, ok = putpaws(ENVIRONMENT, 'ecs:run', 'launch=app')
    refute ok
    assert_match(/Please specify a command/, out)
  end

  def test_scheduler_dry_run
    write_project(schedules: {nightly: {launch: 'seed', schedule_expression: 'rate(1 day)'}})
    out, ok = putpaws(ENVIRONMENT, 'scheduler:deploy', 'schedule=nightly', 'dry=true')
    assert ok, out
    assert_equal 'minaone-production-nightly', JSON.parse(out)['name']
  end

  def test_environment_cannot_be_omitted
    write_project
    out, ok = putpaws('ecs:run', 'launch=app', 'cmd=ls')
    refute ok
    assert_match(/Please specify the environment first/, out)
    assert_match(/Environments: minaone-production/, out)
  end

  def test_settings_errors_are_shown_without_a_backtrace
    write_project
    out, ok = putpaws(ENVIRONMENT, 'ecs:run', 'launch=app', 'target=other-staging-app', 'cmd=ls')
    refute ok
    assert_match(/does not belong to environment `minaone-production`/, out)
    refute_match(/launch_resolver\.rb/, out)
  end

  def test_legacy_files_stop_every_environment_command
    write_project
    write_json('application.json', {"minaone-production-app" => application_data})
    [[ENVIRONMENT, 'info'], ['minaone-production-app', 'info']].each do |args|
      out, ok = putpaws(*args)
      refute ok, out
      assert_match(/Legacy config found: .*application\.json/, out)
      assert_match(/delete the legacy files/, out)
    end
  end

  def test_commands_without_an_environment_still_load_beside_legacy_files
    write_json('application.json', {"minaone-production-app" => application_data})
    out, ok = putpaws('-T')
    assert ok, out
    assert_match(/putpaws up/, out)
  end
end
