require "tty-prompt"
require "putpaws/cloud_watch/log_command"

namespace :log do
  desc "Set Log Group."
  task :set_log_group do
    aws = Putpaws::CloudWatch::LogCommand.config(fetch(:app))
    log_groups = aws.list_log_groups.map{|a| 
      [a.log_group_name, a]
    }.to_h
    raise "Log group not found on your permission" if log_groups.empty?

    log_group = if log_groups.length == 1
      log_groups.first
    else
      prompt = TTY::Prompt.new
      selected = prompt.select("Choose a log_group you're going to operate", log_groups.keys)
       log_groups[selected]
    end

    set :log_group, log_group
  end

  # Check: https://github.com/aws/aws-cli/blob/v2/awscli/customizations/logs/tail.py
  desc "Tail log with follow."
  task tailf: :set_log_group do
    log_group = fetch(:log_group)
    aws = Putpaws::CloudWatch::LogCommand.config(fetch(:app))
    aws.log_group = log_group.log_group_name
    log_event_args = {start_time: (Time.now - (60*5)).to_f * 1000}
    loop do
      # pp log_event_args
      events, next_args = aws.tail_log_events(**log_event_args)
      events.each do |a|
        time = Time.at(0, a.timestamp, :millisecond)
        puts [time.strftime("%FT%T%:z"), a.message].join(" ")
      end
      log_event_args = next_args
      sleep 5 unless log_event_args[:next_token]
    rescue Interrupt
      exit
    end
  end
end
