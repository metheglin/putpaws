require 'erb'
require 'json'
require 'digest'
require 'putpaws/provision/util'
require 'putpaws/provision/resources/base'

module Putpaws
  module Provision
    module Resources
      class TaskDefinition < Base
        # Variables exposed to taskdef ERB templates.
        class TemplateContext
          attr_reader :service_name, :region, :account_id,
            :cpu, :memory, :container_port, :image, :nginx_image,
            :log_group, :execution_role_arn, :task_role_arn,
            :env_json, :secrets_json

          def initialize(config)
            settings = config.settings
            @service_name = config.service_name
            @region = config.region
            @account_id = config.account_id
            @cpu = settings[:cpu].to_s
            @memory = settings[:memory].to_s
            @container_port = (settings[:container_port] || 3000).to_i
            @image = config.ecr_image_uri
            @nginx_image = settings[:nginx_image] || 'public.ecr.aws/nginx/nginx:stable'
            @log_group = config.log_group
            @execution_role_arn = config.roles[:task_execution_role_arn]
            @task_role_arn = config.roles[:task_role_arn]
            @env_json = JSON.generate(
              (settings[:env] || {}).map{|k, v| {name: k.to_s, value: v.to_s}}
            )
            @secrets_json = JSON.generate(
              config.resolved_secrets.map{|name, path|
                {name: name, valueFrom: "arn:aws:ssm:#{config.region}:#{config.account_id}:parameter#{path}"}
              }
            )
          end

          def get_binding
            binding
          end
        end

        attr_reader :entry
        def initialize(entry:, **args)
          super(**args)
          @entry = entry
        end

        def suffix
          entry[:suffix]
        end

        def name
          config.task_definition_family(suffix)
        end

        def desired_params
          @desired_params ||= begin
            template = File.read(config.preset.template_path(entry[:template]))
            rendered = ERB.new(template, trim_mode: '-').result(TemplateContext.new(config).get_binding)
            params = Util.deep_underscore_keys(JSON.parse(rendered))
            params[:family] = name
            params[:tags] = [MANAGED_TAG]
            params
          end
        end

        def digest
          Digest::SHA256.hexdigest(JSON.generate(desired_params))
        end

        def digest_key
          :"taskdef_#{suffix}_digest"
        end

        def current
          clients.ecs.describe_task_definition(task_definition: name).task_definition
        rescue Aws::ECS::Errors::ClientException, Aws::ECS::Errors::ClientError
          nil
        end

        # AWS-side normalization makes a field-by-field diff noisy, so
        # compare against the digest of the params we registered last time.
        def changed?(_current)
          state.resources[digest_key] != digest
        end

        def create!
          register!
        end

        def update!(_current)
          register!
        end

        def register!
          res = clients.ecs.register_task_definition(**desired_params)
          td = res.task_definition
          {
            :"taskdef_#{suffix}" => name,
            :"taskdef_#{suffix}_arn" => td.task_definition_arn,
            digest_key => digest,
          }
        end

        def outputs(current)
          {
            :"taskdef_#{suffix}" => name,
            :"taskdef_#{suffix}_arn" => current.task_definition_arn,
            digest_key => digest,
          }
        end
      end
    end
  end
end
