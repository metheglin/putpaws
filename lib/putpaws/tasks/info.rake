desc "Show the settings of the environment with its launches and schedules. No AWS access."
task :info do
  app = fetch(:app)
  row = ->(key, value){ puts format("%-26s %s", "#{key}:", value) unless value.nil? }

  row.call('environment', app.name)
  row.call('region', app.region)
  row.call('cluster', app.cluster)
  row.call('service', app.service)
  row.call('task_name_prefix', app.task_name_prefix)
  row.call('ecs_region', app.ecs_region)
  row.call('log_group_prefix', app.log_group_prefix)
  row.call('log_region', app.log_region)
  row.call('build_project_name_prefix', app.build_project_name_prefix)
  row.call('build_log_group_prefix', app.build_log_group_prefix)
  row.call('build_region', app.build_region)

  launches = app.launches
  unless launches.empty?
    puts "launches:"
    launches.each do |launch|
      row.call("  #{launch.name}", "target=#{launch.target} network=#{launch.network}")
    end
  end

  schedules = app.schedules
  unless schedules.empty?
    puts "schedules:"
    schedules.each do |schedule|
      row.call("  #{schedule.name}", "launch=#{schedule.launch} #{schedule.args[:schedule_expression]}".strip)
    end
  end
end
