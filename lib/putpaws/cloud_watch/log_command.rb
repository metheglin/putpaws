require 'aws-sdk-cloudwatchlogs'

module Putpaws::CloudWatch
  class LogCommand
    SECONDS = {
      's' => 1,
      'm' => 60,
      'h' => 60 * 60,
      'd' => 60 * 60 * 24,
      'w' => 60 * 60 * 24 * 7,
    }

    def self.config(config, type: "default")
      if type == "build"
        new(config.build_log_command_params)
      else
        new(config.log_command_params)
      end
    end

    def self.parse_unit_time(ut)
      return nil unless ut
      matched, number, unit = ut.match(/\A(\d+)([smhdw])\z/).to_a
      return nil unless matched
      number.to_i * SECONDS[unit]
    end

    def self.filter_args(since: nil, since_for: nil)
      since_sec = parse_unit_time(since)
      since_for_sec = parse_unit_time(since_for)
      start_time = Time.now - (since_sec || (60*1))
      end_time = if since_sec
        since_for_sec && (start_time + since_for_sec)
      else
        nil
      end
      args = {
        start_time: start_time.to_f * 1000,
        end_time: end_time && (end_time.to_f * 1000),
      }
      args.select{|k,v| v}
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
