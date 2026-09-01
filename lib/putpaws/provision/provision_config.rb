require 'json'
require 'pathname'
require 'putpaws/provision/util'
require 'putpaws/provision/preset'

module Putpaws
  module Provision
    class ProvisionConfig
      def self.dir_for(service_name, path_prefix: '.putpaws')
        Pathname.new(path_prefix).join('provisioning', service_name)
      end

      def self.services(path_prefix: '.putpaws')
        Dir.glob(Pathname.new(path_prefix).join('provisioning', '*', 'provision.json').to_s)
          .map{|p| File.basename(File.dirname(p))}
          .reject{|name| name == 'presets'}
          .sort
      end

      def self.load(service_name, path_prefix: '.putpaws')
        path = dir_for(service_name, path_prefix: path_prefix).join('provision.json')
        raise "provision.json not found for #{service_name}. Please run `putpaws ready` first." unless path.exist?
        data = JSON.parse(File.read(path), symbolize_names: true)
        new(data, path_prefix: path_prefix)
      end

      attr_reader :data, :path_prefix
      def initialize(data, path_prefix: '.putpaws')
        @data = data
        @path_prefix = path_prefix
      end

      def service_name
        data[:service_name]
      end

      def region
        data[:region]
      end

      def preset
        @preset ||= begin
          p = Preset.find(data[:preset], path_prefix: path_prefix)
          raise "Preset not found: #{data[:preset]}" unless p
          p
        end
      end

      def base
        data[:base] || {}
      end

      def roles
        data[:roles] || {}
      end

      def overrides
        data[:overrides] || {}
      end

      def devops
        data[:devops] || {}
      end

      def dir
        self.class.dir_for(service_name, path_prefix: path_prefix)
      end

      def policies_dir
        dir.join('policies')
      end

      # preset defaults <- provision.json overrides (nil values ignored).
      # env/secrets hashes are merged by key.
      def settings
        @settings ||= begin
          merged = preset.defaults.dup
          overrides.each do |k, v|
            next if v.nil?
            next if k == :cluster_name
            if v.is_a?(Hash) && merged[k].is_a?(Hash)
              merged[k] = merged[k].merge(v)
            else
              merged[k] = v
            end
          end
          merged
        end
      end

      def devops_settings
        preset.devops_defaults.merge(devops.reject{|_, v| v.nil?})
      end

      def account_id
        Util.arn_account_id(base[:ecr_repository_arn])
      end

      def ecr_image_uri(tag: nil)
        "#{Util.ecr_repository_uri(base[:ecr_repository_arn])}:#{tag || settings[:image_tag] || 'latest'}"
      end

      def ssm_parameter_prefix
        base[:ssm_parameter_prefix]
      end

      # {ssm_parameter_prefix} placeholders resolved, values as full parameter paths.
      def resolved_secrets
        (settings[:secrets] || {}).map{|name, path|
          [name.to_s, path.to_s.gsub('{ssm_parameter_prefix}', ssm_parameter_prefix.to_s)]
        }.to_h
      end

      def secret_parameter_arns
        resolved_secrets.values.map{|path|
          "arn:aws:ssm:#{region}:#{account_id}:parameter#{path}"
        }
      end

      # ===== naming conventions (service_name prefix) =====

      def sg_name
        service_name
      end

      def cluster_name
        Util.blank?(overrides[:cluster_name]) ? service_name : overrides[:cluster_name]
      end

      def log_group
        "/ecs/#{service_name}"
      end

      def build_log_group
        "/aws/codebuild/#{service_name}"
      end

      def build_project_name
        service_name
      end

      def task_definition_family(suffix)
        "#{service_name}-#{suffix}"
      end

      def service_task_definition_family
        task_definition_family(preset.service_task_definition)
      end

      def service_container_name
        entry = preset.task_definitions.detect{|t| t[:suffix] == preset.service_task_definition}
        (entry && entry[:container_name]) || 'app'
      end
    end
  end
end
