require 'json'
require 'fileutils'
require 'pathname'
require 'putpaws/provision/util'

module Putpaws
  module Provision
    # Reflects provisioned resources into .putpaws/application.json and
    # .putpaws/infra.json. Only the keys of the target service are touched.
    # Shows a diff and asks for confirmation before writing.
    class ConfigWriter
      attr_reader :config, :state, :prompt, :io
      def initialize(config:, state:, prompt:, io: $stdout)
        @config = config
        @state = state
        @prompt = prompt
        @io = io
      end

      def application_entry
        {
          region: config.region,
          cluster: config.cluster_name,
          service: config.service_name,
          task_name_prefix: config.service_name,
          log_group_prefix: config.log_group,
          build_log_group_prefix: config.build_log_group,
          build_project_name_prefix: config.build_project_name,
          network: config.service_name,
          target: config.service_name,
        }
      end

      def network_entry
        {
          subnets: config.base[:subnets],
          security_groups: state.resources[:security_group_ids] || [],
          assign_public_ip: config.settings[:assign_public_ip] || 'DISABLED',
        }
      end

      def target_entry
        {
          # Used by EventBridge Scheduler (scheduler:deploy).
          scheduler_role: config.roles[:scheduler_role_arn],
          cluster: state.resources[:cluster_arn],
          # Revision-less on purpose: always run the latest ACTIVE revision.
          task_definition: config.service_task_definition_family,
          container_name: config.service_container_name,
        }
      end

      def apply!
        write_key(path('application.json'), [config.service_name.to_sym], application_entry)
        write_key(path('infra.json'), [:network, config.service_name.to_sym], network_entry)
        write_key(path('infra.json'), [:target, config.service_name.to_sym], target_entry)
      end

      private

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
