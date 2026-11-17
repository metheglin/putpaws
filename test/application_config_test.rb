require "test_helper"

class ApplicationConfigTest < Putpaws::TestCase
  def test_environments_are_folders_holding_application_json
    write_project
    write_json("minaone-staging/application.json", application_data.merge(cluster: 'minaone-staging'))
    write_json("notes/launch.json", {})                                  # no application.json
    write_json("provisioning/minaone-production/provision.json", {service_name: ENVIRONMENT})
    write_json("provisioning/application.json", application_data)        # never an environment

    assert_equal %w[minaone-production minaone-staging], Putpaws::ApplicationConfig.names
    assert_equal %w[minaone-production minaone-staging], Putpaws::ApplicationConfig.all.map(&:name)
  end

  def test_name_is_the_folder_name
    write_project
    app = Putpaws::ApplicationConfig.find(ENVIRONMENT)
    assert_equal ENVIRONMENT, app.name
    assert_equal REGION, app.region
    assert_equal ENVIRONMENT, app.cluster
    assert_equal File.join(root, ENVIRONMENT), app.dir.to_s
    assert_nil Putpaws::ApplicationConfig.find('unknown')
  end

  def test_launches_and_schedules_of_the_environment
    write_project(schedules: {nightly: {launch: 'seed', schedule_expression: 'cron(0 18 * * ? *)'}})
    app = application
    assert_equal %w[app migrate seed], app.launches.map(&:name)
    assert_equal %w[nightly], app.schedules.map(&:name)
  end

  def test_removed_keys_are_rejected
    write_project
    write_json("#{ENVIRONMENT}/application.json", application_data.merge(network: 'x', target: 'y'))
    error = assert_raises(Putpaws::ConfigError){ Putpaws::ApplicationConfig.find(ENVIRONMENT) }
    assert_match(/`network`, `target`/, error.message)
    assert_match(/launch\.json/, error.message)
  end

  def test_legacy_application_json_stops_with_a_hint
    write_project
    legacy = write_json('application.json', {"minaone-production-app" => application_data})

    assert_equal [ENVIRONMENT], Putpaws::ApplicationConfig.names
    [->{ Putpaws::ApplicationConfig.all }, ->{ Putpaws::ApplicationConfig.find(ENVIRONMENT) }].each do |call|
      error = assert_raises(Putpaws::LegacyConfigError, &call)
      assert_includes error.message, legacy
      assert_match(/Legacy config/, error.message)
    end
  end

  def test_legacy_schedule_json_stops_too
    write_project
    write_json('schedule.json', {})
    assert_raises(Putpaws::LegacyConfigError){ Putpaws::ApplicationConfig.all }
  end
end
