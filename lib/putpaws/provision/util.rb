require 'json'

module Putpaws
  module Provision
    module Util
      module_function

      def underscore(str)
        str.to_s.gsub(/([a-z0-9])([A-Z])/, '\1_\2').downcase
      end

      # Task definition JSON is written in camelCase convention.
      # Convert it into snake_case symbol keys for aws-sdk params.
      def deep_underscore_keys(obj)
        case obj
        when Hash
          obj.map{|k, v| [underscore(k).to_sym, deep_underscore_keys(v)]}.to_h
        when Array
          obj.map{|x| deep_underscore_keys(x)}
        else
          obj
        end
      end

      def arn_account_id(arn)
        arn.to_s.split(':')[4]
      end

      def arn_region(arn)
        arn.to_s.split(':')[3]
      end

      def ecr_repository_name(arn)
        arn.to_s.split(':', 6).last.to_s.sub(/\Arepository\//, '')
      end

      def ecr_repository_uri(arn)
        "#{arn_account_id(arn)}.dkr.ecr.#{arn_region(arn)}.amazonaws.com/#{ecr_repository_name(arn)}"
      end

      def blank?(value)
        value.nil? || value.to_s.strip.empty?
      end

      def write_json(path, data)
        File.write(path, JSON.pretty_generate(data) + "\n")
      end
    end
  end
end
