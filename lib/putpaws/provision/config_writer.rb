require 'json'
require 'fileutils'
require 'pathname'
require 'putpaws/provision/util'

module Putpaws
  module Provision
    # Reflects provisioned resources into .putpaws/application.json and
    # .putpaws/infra.json. Only the keys of the target service are touched.
    # Shows a diff and asks for confirmation before writing.
    #
    # One application entry and one infra.target entry are written per task
    # definition of the preset, keyed by the task definition family
    # (`<service_name>-<suffix>`). The entry whose suffix is the preset's
    # `service_task_definition` carries `service` so that ecs:deploy /
    # ecs:attach address the long-running service; the others are for
    # one-off tasks (ecs:run / ecs:shell / scheduler) and have `service: null`.
    # infra.network is written once per service as it does not depend on the
    # task definition.
    class ConfigWriter
      attr_reader :config, :state, :prompt, :io
      def initialize(config:, state:, prompt:, io: $stdout)
        @config = config
        @state = state
        @prompt = prompt
        @io = io
      end

      def application_entry(entry)
        family = config.task_definition_family(entry[:suffix])
        {
          region: config.region,
          cluster: config.cluster_name,
          service: service_entry?(entry) ? config.service_name : nil,
          task_name_prefix: family,
          log_group_prefix: config.log_group,
          build_log_group_prefix: config.build_log_group,
          build_project_name_prefix: config.build_project_name,
          network: config.service_name,
          target: family,
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

      def apply!
        write_key(path('infra.json'), [:network, config.service_name.to_sym], network_entry)
        config.preset.task_definitions.each do |entry|
          key = config.task_definition_family(entry[:suffix]).to_sym
          write_key(path('application.json'), [key], application_entry(entry))
          write_key(path('infra.json'), [:target, key], target_entry(entry))
        end
      end

      private

      def service_entry?(entry)
        entry[:suffix] == config.preset.service_task_definition
      end

      def path(basename)
        Pathname.new(config.path_prefix).join(basename)
      end

      def write_key(file, keys, entry)
        data = file.exist? ? JSON.parse(File.read(file), symbolize_names: true) : {}
        current = keys.reduce(data){|d, k| d.is_a?(Hash) ? d[k] : nil}
        return if current == entry

        io.puts "=== #{file} : #{keys.join('.')} ==="
        io.puts "--- before"
        io.puts current ? JSON.pretty_generate(current) : "(none)"
        io.puts "+++ after"
        io.puts JSON.pretty_generate(entry)
        unless prompt.yes?("Update #{file}?")
          io.puts "Skipped updating #{file}"
          return
        end

        FileUtils.cp(file, "#{file}.bak") if file.exist?
        parent = keys[0..-2].reduce(data){|d, k| d[k] ||= {}}
        parent[keys.last] = entry
        Util.write_json(file, data)
        io.puts "Updated #{file}"
      end
    end
  end
end
