desc "Show resolved settings for the service. No AWS access."
task :info do
  app = fetch(:app)
  row = ->(key, value){ puts format("%-26s %s", "#{key}:", value) unless value.nil? }

  row.call('name', app.name)
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

  if (network = app.network)
    row.call('network', network.name)
    row.call('  subnets', network.subnets && network.subnets.join(', '))
    row.call('  security_groups', network.security_groups && network.security_groups.join(', '))
    row.call('  assign_public_ip', network.assign_public_ip)
  end

  if (target = app.target)
    row.call('target', target.name)
    row.call('  cluster', target.cluster)
    row.call('  task_definition', target.task_definition)
    row.call('  container_name', target.container_name)
    row.call('  scheduler_role', target.scheduler_role)
  end

  schedules = app.schedules
  row.call('schedules', schedules.map(&:name).join(', ')) unless schedules.empty?
end
