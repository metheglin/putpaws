require 'json'
require 'putpaws/launch_config'
require 'putpaws/launch_resolver'

module Putpaws::Ecs
  # Turns the command-line parameters of `ecs:run` / `ecs:shell` into a
  # resolved launch:
  #
  #   launch=seed                          a saved launch as it is
  #   launch=seed cpu=8192 memory=32768    a saved launch, partly overridden
  #   target=... network=... cmd='...'     assembled on the spot, nothing saved
  #   save=seed-small                      save what was resolved under that name
  #   dry=true                             show what was resolved, start nothing
  class LaunchRequest
    # command-line parameter => launch field
    OVERRIDE_PARAMS = {
      'target' => :target,
      'network' => :network,
      'cmd' => :command,
      'container' => :container,
      'cpu' => :cpu,
      'memory' => :memory,
      'env' => :env,
      'ephemeral_storage' => :ephemeral_storage,
      'task_role' => :task_role,
      'capacity_provider' => :capacity_provider,
    }

    # env='NAME=value NAME2=value2' (space separated; values cannot contain spaces)
    def self.parse_env(str)
      str.to_s.split.map{|pair|
        name, value = pair.split('=', 2)
        if name.to_s.empty? || value.nil?
          raise Putpaws::ConfigError, "Invalid env: #{pair.inspect} (Ex) env='NAME=value NAME2=value2'"
        end
        [name, value]
      }.to_h
    end

    def self.overrides(params)
      OVERRIDE_PARAMS.each_with_object({}) do |(param, field), result|
        value = params[param]
        next if value.nil? || value.strip.empty?
        result[field] = field == :env ? parse_env(value) : value
      end
    end

    attr_reader :application, :params, :prompt, :io
    def initialize(application:, params: ENV, prompt: nil, io: $stdout)
      @application = application
      @params = params
      @prompt = prompt
      @io = io
    end

    def overrides
      self.class.overrides(params)
    end

    def dry?
      present?('dry')
    end

    def save_name
      present?('save') ? params['save'].strip : nil
    end

    def launch_config
      if present?('launch')
        return Putpaws::LaunchConfig.find!(application, params['launch'].strip)
      end
      # Assembled on the spot when target= / network= are given.
      return nil if overrides.key?(:target) || overrides.key?(:network)
      select_launch_config
    end

    def resolve
      Putpaws::LaunchResolver.resolve(
        application: application,
        launch: launch_config,
        overrides: [overrides],
      )
    end

    # Save the resolved launch into launch.json of the environment under
    # save=<name>. An existing name is never overwritten without showing the
    # difference and asking. Returns false when the user declined.
    def save!(resolved)
      name = save_name
      return true unless name
      attributes = resolved.to_h
      file = Putpaws::LaunchConfig.path(application)
      existing = Putpaws::LaunchConfig.load(application)[name.to_sym]
      if existing
        current = Putpaws::LaunchConfig.normalize(existing, context: "launch `#{name}` (#{file})")
        if current == attributes
          io.puts "Launch `#{name}` is already saved with the same content."
          return true
        end
        io.puts "=== #{file} : #{name} ==="
        io.puts "--- before"
        io.puts JSON.pretty_generate(current)
        io.puts "+++ after"
        io.puts JSON.pretty_generate(attributes)
        unless prompt.yes?("Launch `#{name}` already exists. Overwrite?", default: false)
          io.puts "Not saved."
          return false
        end
      end
      Putpaws::LaunchConfig.save!(application, name, attributes)
      io.puts "Saved launch `#{name}` to #{file}"
      true
    end

    private

    def present?(key)
      !params[key].to_s.strip.empty?
    end

    def select_launch_config
      launches = Putpaws::LaunchConfig.all(application)
      if launches.empty?
        raise Putpaws::ConfigError,
          "No launch is defined in #{Putpaws::LaunchConfig.path(application)}\n" +
          "Pass target=<name> network=<name> (names in infra.json), or add a launch (`putpaws up` adds the defaults)."
      end
      choices = launches.map{|l| [self.class.label(l), l.name]}.to_h
      selected = prompt.select("Choose a launch", choices)
      launches.detect{|l| l.name == selected}
    end

    def self.label(launch)
      label = "#{launch.name} (target: #{launch.target}, network: #{launch.network})"
      label += " #{summarize_command(launch.command)}" if launch.command
      label
    end

    def self.summarize_command(command)
      text = command.is_a?(Array) ? command.join(' ') : command
      text.length > 60 ? "#{text[0, 57]}..." : text
    end
  end
end
