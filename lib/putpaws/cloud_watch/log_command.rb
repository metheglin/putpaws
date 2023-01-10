require 'aws-sdk-cloudwatchlogs'

module Putpaws::CloudWatch
  class LogCommand
    def self.config(config)
      new(config.log_command_params)
    end

    attr_reader :client
    attr_reader :region, :log_group_prefix
    attr_accessor :log_group
    def initialize(region:, log_group_prefix: nil)
      @client = Aws::CloudWatchLogs::Client.new({region: region})
      @log_group_prefix = log_group_prefix
      @log_group = nil
    end

    def list_log_groups
      res = client.describe_log_groups(log_group_name_prefix: log_group_prefix)
      res.log_groups
    end

    def log_events(**args)
      raise "Log group Not Set" unless log_group
      res = client.filter_log_events({
        log_group_name: log_group,
        **args
      })
    end

    def tail_log_events(**args)
      res = log_events(**args)
      nt = newest_timestamp([args[:start_time], *res.events.map(&:timestamp)].compact.max)
      events = filter_same_moment_events(res.events, args[:start_time])
      next_args = if res.next_token
        args.merge(next_token: res.next_token)
      else
        args.merge(
          next_token: nil, 
          start_time: nt,
        )
      end
      [events, next_args]
    end

    def newest_timestamp(newest)
      newest = newest.to_i
      if @newest_timestamp
        @newest_timestamp = [@newest_timestamp, newest].max
      else
        @newest_timestamp = newest
      end
      @newest_timestamp
    end

    def filter_same_moment_events(events, timestamp)
      @event_ids_already_shown ||= []
      filtered_events = events.reject{|e| @event_ids_already_shown.include?(e.event_id)}
      event_ids = events.map(&:event_id).uniq
      unless event_ids.empty?
        @event_ids_already_shown = event_ids
      end
      # pp @event_ids_already_shown
      filtered_events
    end
  end
end
