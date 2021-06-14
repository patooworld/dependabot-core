# frozen_string_literal: true
require "excon"
require "json"
require "dependabot/metadata_finders"
require "dependabot/metadata_finders/base"
require "dependabot/shared_helpers"

module Dependabot
  module Swift
    class MetadataFinder < Dependabot::MetadataFinders::Base
      private

      def look_up_source
        case new_source_type
        when "git" then find_source_from_git_url
        when "registry" then find_source_from_registry
        else raise "Unexpected source type: #{new_source_type}"
        end
      end

      def new_source_type
        sources =
          dependency.requirements.map { |r| r.fetch(:source) }.uniq.compact

        return "default" if sources.empty?
        raise "Multiple sources! #{sources.join(', ')}" if sources.count > 1

        sources.first[:type] || sources.first.fetch("type")
      end

      def find_source_from_git_url
        info = dependency.requirements.map { |r| r[:source] }.compact.first

        url = info[:url] || info.fetch("url")
        Source.from_url(url)
      end

      def find_source_from_registry
        raise NotImplementedError
      end
    end
  end
end

Dependabot::MetadataFinders.
  register("swift", Dependabot::Swift::MetadataFinder)