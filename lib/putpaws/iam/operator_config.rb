require 'json'
require 'pathname'

module Putpaws
  module Iam
    # Named operator profiles declared in .putpaws/operators.json.
    # A profile gives an organization-level name (Ex: developer, viewer)
    # to a combination of putpaws command groups.
    class OperatorConfig < Struct.new(:name, :groups, :extra_statements, keyword_init: true)
      EXAMPLE = {
        developer: {groups: %w[attach shell deploy logs codebuild]},
        viewer: {groups: %w[logs]},
      }

      def self.path(path_prefix: '.putpaws')
        Pathname.new(path_prefix).join('operators.json')
      end

      def self.exist?(path_prefix: '.putpaws')
        path(path_prefix: path_prefix).exist?
      end

      def self.scaffold!(path_prefix: '.putpaws')
        p = path(path_prefix: path_prefix)
        File.write(p, JSON.pretty_generate(EXAMPLE) + "\n")
        p.to_s
      end

      def self.load(path_prefix: '.putpaws')
        p = path(path_prefix: path_prefix)
        return {} unless p.exist?
        JSON.parse(File.read(p), symbolize_names: true)
      end

      def self.all(path_prefix: '.putpaws')
        load(path_prefix: path_prefix).map{|k, v|
          new(name: k.to_s, groups: v[:groups] || [], extra_statements: v[:extra_statements] || [])
        }
      end

      def self.find(name, path_prefix: '.putpaws')
        all(path_prefix: path_prefix).detect{|x| x.name == name.to_s}
      end
    end
  end
end
