require "json"
require "putpaws/prompt"
require "putpaws/schedule_config"
require "putpaws/scheduler/schedule_command"

namespace :scheduler do
  desc "Select Schedule to Manage. (Ex) schedule=nightly-seed"
  task :set_schedule_config do
    app = fetch(:app)
    schedule_config = if ENV['schedule'] && !ENV['schedule'].strip.empty?
      Putpaws::ScheduleConfig.find!(app, ENV['schedule'].strip)
    else
      schedules = app.schedules
      if schedules.empty?
        raise "No schedule is defined in #{Putpaws::ScheduleConfig.path(app)}"
      end
      prompt = Putpaws::Prompt.safe
      selected = prompt.select("Choose a schedule you're going to operate", schedules.map(&:name))
      schedules.find{|x| x.name == selected}
    end

    set :schedule_config, schedule_config
  end

  desc "List the schedules of the environment (.putpaws/<environment>/schedule.json). No AWS access."
  task :list do
    app = fetch(:app)
    schedules = app.schedules
    if schedules.empty?
      puts "No schedule is defined in #{Putpaws::ScheduleConfig.path(app)}"
      next
    end
    schedules.each do |schedule|
      puts format("%-24s launch: %-16s %s", schedule.name, schedule.launch, schedule.args[:schedule_expression])
    end
  end

  desc "Deploy a schedule to EventBridge Scheduler as <environment>-<schedule>. (Ex) schedule=nightly-seed dry=true"
  task deploy: :set_schedule_config do
    schedule_config = fetch(:schedule_config)
    aws = Putpaws::Scheduler::ScheduleCommand.new(schedule_config)
    if ENV['dry'] && !ENV['dry'].strip.empty?
      puts JSON.pretty_generate(aws.params)
      next
    end
    result = aws.deploy!
    puts "Schedule #{result}: #{schedule_config.aws_name}"
  end
end
