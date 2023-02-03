require "tty-prompt"
require "putpaws/schedule_config"
require "putpaws/scheduler/schedule_command"

namespace :scheduler do
  desc "Select Schedule to Manage."
  task :set_schedule_config do
    app = fetch(:app)
    schedules = (app.schedules && !app.schedules.empty?) ? app.schedules : []
    if schedules.empty?
      schedule_options = Putpaws::ScheduleConfig.all.map(&:name)
      raise "Please set `schedules` at .putpaws/schedule.json\nFollowing schedules available:\n#{schedule_options.to_json}\n"
    end

    prompt = TTY::Prompt.new
    selected = prompt.select("Choose a task you're going to operate", schedules.map(&:name))
    schedule_config = schedules.find{|x| x.name == selected}

    set :schedule_config, schedule_config
  end

  desc "Deploy schedule."
  task deploy: :set_schedule_config do
    schedule_config = fetch(:schedule_config)
    # pp schedule_config
    aws = Putpaws::Scheduler::ScheduleCommand.new(schedule_config)
    aws.deploy!
  end
end
