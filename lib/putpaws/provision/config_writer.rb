require 'json'
require 'fileutils'
require 'pathname'
require 'putpaws/config_file'
require 'putpaws/application_config'
require 'putpaws/launch_config'
require 'putpaws/provision/util'

module Putpaws
  module Provision
    # Reflects provisioned resources into the operation settings under
    # .putpaws/. The service name is the environment name.
    #
    # `up` writes only what it knows the right answer for, and never overrides
    # a choice made by the user:
    #
    #   <service_name>/application.json   generated / updated (the keys putpaws knows; others are kept)
    #   infra.json network.<service_name> generated / updated
    #   infra.json target.<family>        generated / updated, one per task definition of the preset
    #   <service_name>/launch.json        a launch per task definition is ADDED when its name is absent;
    #                                     existing launches are never rewritten
    #   <service_name>/schedule.json      never touched
    #
    # Updates show a diff and ask for confirmation before writing.
    class ConfigWriter
      attr_reader :config, :state, :prompt, :io
      def initialize(config:, state:, prompt:, io: $stdout)
        @config = config
        @state = state
        @prompt = prompt
        @io = io
      end

      # Operating what is running: one set per environment. Prefixes are the
      # service name so that tasks of every task definition (-app / -web ...) are found.
      def application_entry
        {
          region: config.region,
          cluster: config.cluster_name,
          service: config.service_name,
          task_name_prefix: config.service_name,
          log_group_prefix: config.log_group,
          build_project_name_prefix: config.build_project_name,
          build_log_group_prefix: config.build_log_group,
        }
      end

      def network_entry
        {
          subnets: config.base[:subnets],
          security_groups: state.resources[:security_group_ids] || [],
          assign_public_ip: config.settings[:assign_public_ip] || 'DISABLED',
        }
      end

      def target_entry(entry)
        {
          # Used by EventBridge Scheduler (scheduler:deploy).
          scheduler_role: config.roles[:scheduler_role_arn],
          cluster: state.resources[:cluster_arn],
          # Revision-less on purpose: always run the latest ACTIVE revision.
          task_definition: config.task_definition_family(entry[:suffix]),
          container_name: entry[:container_name] || 'app',
        }
      end

      # The default launch of a task definition, named after its suffix.
      def launch_entry(entry)
        {
          target: config.task_definition_family(entry[:suffix]),
          network: config.service_name,
        }
      end

      def apply!
        write_application
        write_key(path('infra.json'), [:network, config.service_name.to_sym], network_entry)
        config.preset.task_definitions.each do |entry|
          key = config.task_definition_family(entry[:suffix]).to_sym
          write_key(path('infra.json'), [:target, key], target_entry(entry))
        end
        add_missing_launches
      end

      # Files of the 0.1.x layout are neither read nor deleted. Just say so.
      def notify_legacy
        ConfigFile.legacy_files(path_prefix: config.path_prefix).each do |file|
          io.puts "[notice] #{file} is a legacy (0.1.x) file and is no longer read. Please delete it."
        end
      end

      private

      def path(basename)
        Pathname.new(config.path_prefix).join(basename)
      end

      def environment_path(basename)
        ApplicationConfig.dir_for(config.service_name, path_prefix: config.path_prefix).join(basename)
      end

      # Only the keys putpaws knows are compared and written, so optional keys
      # added by hand (ecs_region / log_region / build_region) survive.
      def write_application
        file = environment_path(ApplicationConfig::FILENAME)
        current = ConfigFile.read(file)
        desired = current.merge(application_entry)
        return if current == desired

        show_diff(file, nil, current.empty? ? nil : current, desired)
        return unless confirm(file)
        backup(file)
        ConfigFile.write(file, desired)
        io.puts "Updated #{file}"
      end

      def write_key(file, keys, entry)
        data = ConfigFile.read(file)
        current = keys.reduce(data){|d, k| d.is_a?(Hash) ? d[k] : nil}
        return if current == entry

        show_diff(file, keys, current, entry)
        return unless confirm(file)
        backup(file)
        parent = keys[0..-2].reduce(data){|d, k| d[k] ||= {}}
        parent[keys.last] = entry
        ConfigFile.write(file, data)
        io.puts "Updated #{file}"
      end

      # Adding never overrides anything, so it is done without asking.
      def add_missing_launches
        file = environment_path(LaunchConfig::FILENAME)
        data = ConfigFile.read(file)
        added = []
        config.preset.task_definitions.each do |entry|
          name = entry[:suffix].to_sym
          next if data.key?(name)
          data[name] = launch_entry(entry)
          added << name
        end
        return if added.empty?
        ConfigFile.write(file, data)
        io.puts "Added launch #{added.map{|n| "`#{n}`"}.join(', ')} to #{file}"
      end

      def show_diff(file, keys, current, entry)
        io.puts keys ? "=== #{file} : #{keys.join('.')} ===" : "=== #{file} ==="
        io.puts "--- before"
        io.puts current ? JSON.pretty_generate(current) : "(none)"
        io.puts "+++ after"
        io.puts JSON.pretty_generate(entry)
      end

      def confirm(file)
        return true if prompt.yes?("Update #{file}?")
        io.puts "Skipped updating #{file}"
        false
      end

      def backup(file)
        FileUtils.cp(file, "#{file}.bak") if File.exist?(file)
      end
    end
  end
end
